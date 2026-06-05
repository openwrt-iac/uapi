let t = require('harness');
let tx = require('transaction');
let ubus = require('bus');

function harness_locks(initial_available) {
	let state = {
		available: initial_available,
		acquired: 0,
		released: 0,
	};
	state.acquire = function(path) {
		if (!state.available) return null;
		state.acquired++;
		return { _path: path };
	};
	state.release = function(handle) {
		state.released++;
	};
	return state;
}

function track_reload() {
	let calls = [];
	return {
		calls: calls,
		fn: function(services) { push(calls, services); return null; },
	};
}

function reload_failing(error) {
	return function(services) { return error; };
}

function reload_flaky(initial_calls_failing) {
	let n = 0;
	return function(services) {
		n++;
		if (n <= initial_calls_failing) return "netifd: bad";
		return null;
	};
}

function noop_reload(services) { return null; }
function noop_check(services) { return null; }

function build_params(overrides) {
	let p = {
		package: "fw",
		reload_services: ["firewall"],
		fn: function(conn, pkg) {
			conn.uci_set(pkg, "r1", "target", "ACCEPT");
			return { ok: true, body: { id: "r1", target: "ACCEPT" } };
		},
		reload: noop_reload,
		check_services: noop_check,
	};
	if (overrides) {
		for (let k in overrides) p[k] = overrides[k];
	}
	return p;
}

t.describe('transaction, lock acquisition', () => {
	t.it('returns kind=locked when the lock cannot be acquired', () => {
		let locks = harness_locks(false);
		let conn = ubus.stub();
		let r = tx.transaction(conn, build_params({
			acquire: locks.acquire, release: locks.release,
		}));
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "locked");
		// v2.0.2: identify which lock the contention is on. transaction()
		// always serializes on the per-package EX; report it as such so the
		// client knows another uci writer (not a non-uci writer) is the cause.
		t.assert_equal(r.lock_kind, "package");
		t.assert_equal(r.package, "fw");  // matches build_params default
		t.assert_equal(locks.acquired, 0);
		t.assert_equal(locks.released, 0);
	});

	t.it('returns kind=lock_unavailable when the lock path cannot be opened', () => {
		let conn = ubus.stub();
		let r = tx.transaction(conn, build_params({
			acquire: function(p) { return { unavailable: p }; },
			release: function() {},
		}));
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "lock_unavailable");
		t.assert_true(r.error != null && r.error != "");
	});

	t.it('uses the configured lock_path when acquiring', () => {
		let seen_path = null;
		let conn = ubus.stub();
		tx.transaction(conn, build_params({
			lock_path: "/tmp/custom.lock",
			acquire: function(path) { seen_path = path; return { _path: path }; },
			release: function() {},
		}));
		t.assert_equal(seen_path, "/tmp/custom.lock");
	});
});

t.describe('transaction, happy path', () => {
	t.it('snapshot, commit, reload, success body', () => {
		let locks = harness_locks(true);
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'DROP' } } },
		});
		let tracker = track_reload();
		let r = tx.transaction(conn, build_params({
			acquire: locks.acquire, release: locks.release,
			reload: tracker.fn,
		}));
		t.assert_true(r.ok);
		t.assert_deep_equal(r.body, { id: "r1", target: "ACCEPT" });
		t.assert_equal(conn._state.uci.fw.r1.target, "ACCEPT");
		t.assert_deep_equal(tracker.calls, [["firewall"]]);
		t.assert_equal(locks.acquired, 1);
		t.assert_equal(locks.released, 1);
	});

	t.it('records commit in the uci op log', () => {
		let conn = ubus.stub();
		tx.transaction(conn, build_params({
			acquire: function() { return {}; },
			release: function() {},
		}));
		let ops = conn._state.uci_ops;
		let commit_ops = filter(ops, function(o) { return o[0] == "commit"; });
		t.assert_equal(length(commit_ops), 1);
	});
});

t.describe('transaction, soft failure from fn', () => {
	t.it('reverts the package and passes the failure through', () => {
		let locks = harness_locks(true);
		let conn = ubus.stub();
		let validation_result = {
			ok: false, kind: "validation", errors: [{ field: "x" }]
		};
		let r = tx.transaction(conn, build_params({
			acquire: locks.acquire, release: locks.release,
			fn: function(c, pkg) {
				c.uci_set(pkg, "r1", "target", "BOGUS");
				return validation_result;
			},
		}));
		t.assert_deep_equal(r, validation_result);
		let ops = conn._state.uci_ops;
		let last = ops[length(ops) - 1];
		t.assert_equal(last[0], "revert");
		t.assert_equal(locks.released, 1);
	});
});

t.describe('transaction, reload failure with successful restore', () => {
	t.it('returns reload_failed_restored when the re-reload succeeds', () => {
		let locks = harness_locks(true);
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
		});
		let r = tx.transaction(conn, build_params({
			acquire: locks.acquire, release: locks.release,
			reload: reload_flaky(1),
		}));
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(r.reload_error, "netifd: bad");
		t.assert_equal(locks.released, 1);
	});

	t.it('restores the snapshot before returning', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
		});
		tx.transaction(conn, build_params({
			acquire: function() { return {}; },
			release: function() {},
			reload: reload_flaky(1),
		}));
		t.assert_equal(conn._state.uci.fw.r1.target, "ACCEPT");
	});
});

t.describe('transaction, reload failure with restore failure', () => {
	t.it('returns reload_failed_unrecovered when the re-reload also fails', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
		});
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; },
			release: function() {},
			reload: reload_failing("netifd: bad"),
		}));
		t.assert_equal(r.kind, "reload_failed_unrecovered");
		t.assert_equal(r.reload_error, "netifd: bad");
		t.assert_true(match(r.restore_error, /netifd: bad/) != null);
	});

	t.it('returns reload_failed_unrecovered when uci_import throws', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
		});
		conn.uci_import = function(pkg, snap) { die("restore EIO"); };
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; },
			release: function() {},
			reload: reload_failing("netifd: bad"),
		}));
		t.assert_equal(r.kind, "reload_failed_unrecovered");
		t.assert_equal(r.reload_error, "netifd: bad");
		t.assert_equal(r.restore_error, "restore EIO");
	});
});

t.describe('transaction, default_check_services pre-flight', () => {
	t.it('refuses service names with shell metacharacters before any uci write', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
		});
		let r = tx.transaction(conn, build_params({
			reload_services: ["firewall; rm -rf /"],
			acquire: function() { return {}; },
			release: function() {},
			// Use the real default_check_services via params.check_services omission.
			check_services: null,
		}));
		t.assert_equal(r.kind, "init_script_missing");
		t.assert_true(match(r.message, /unsafe name/) != null);
	});

	t.it('returns init_script_missing when /etc/init.d/<svc> is absent', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
		});
		let r = tx.transaction(conn, build_params({
			reload_services: ["this-daemon-definitely-not-installed-anywhere"],
			acquire: function() { return {}; },
			release: function() {},
			check_services: null,  // exercise the real default
		}));
		t.assert_equal(r.kind, "init_script_missing");
		t.assert_true(match(r.message, /init script .* not found/) != null);
	});

	t.it('empty reload services list passes pre-flight', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
		});
		let r = tx.transaction(conn, build_params({
			reload_services: [],
			acquire: function() { return {}; },
			release: function() {},
			check_services: null,
		}));
		t.assert_true(r.ok);
	});
});

t.describe('transaction, lock release', () => {
	t.it('releases the lock when fn throws', () => {
		let locks = harness_locks(true);
		let conn = ubus.stub();
		let threw = false;
		try {
			tx.transaction(conn, build_params({
				acquire: locks.acquire, release: locks.release,
				fn: function() { die("boom"); },
			}));
		} catch (e) {
			threw = true;
		}
		t.assert_true(threw);
		t.assert_equal(locks.released, 1);
	});
});

let fs = require('fs');

t.describe('transaction, per-package + global flock layout', () => {
	function clean_locks() {
		try { fs.unlink("/tmp/uapi-test-global.lock"); } catch (e) {}
		try { fs.unlink("/tmp/uapi-test-pkg-firewall.lock"); } catch (e) {}
		try { fs.unlink("/tmp/uapi-test-pkg-network.lock"); } catch (e) {}
	}

	t.it('per-package lock allows different packages to proceed in parallel', () => {
		clean_locks();
		let g1 = fs.open("/tmp/uapi-test-global.lock", "w+");
		g1.lock("sn");
		let p1 = fs.open("/tmp/uapi-test-pkg-firewall.lock", "w+");
		p1.lock("xn");
		let g2 = fs.open("/tmp/uapi-test-global.lock", "w+");
		t.assert_equal(g2.lock("sn"), true);
		let p2 = fs.open("/tmp/uapi-test-pkg-network.lock", "w+");
		t.assert_equal(p2.lock("xn"), true);
		p2.lock("u"); p2.close();
		g2.lock("u"); g2.close();
		p1.lock("u"); p1.close();
		g1.lock("u"); g1.close();
		clean_locks();
	});

	t.it('per-package lock serializes same-package writes', () => {
		clean_locks();
		let p1 = fs.open("/tmp/uapi-test-pkg-firewall.lock", "w+");
		t.assert_equal(p1.lock("xn"), true);
		let p2 = fs.open("/tmp/uapi-test-pkg-firewall.lock", "w+");
		t.assert_true(p2.lock("xn") !== true);
		p2.close();
		p1.lock("u"); p1.close();
		clean_locks();
	});

	t.it('global EX (non-uci write) blocks against an in-flight uci SH', () => {
		clean_locks();
		let g_sh = fs.open("/tmp/uapi-test-global.lock", "w+");
		g_sh.lock("sn");
		let g_ex = fs.open("/tmp/uapi-test-global.lock", "w+");
		t.assert_true(g_ex.lock("xn") !== true);
		g_ex.close();
		g_sh.lock("u"); g_sh.close();
		clean_locks();
	});

	t.it('uci SH on global waits for an in-flight non-uci EX', () => {
		clean_locks();
		let g_ex = fs.open("/tmp/uapi-test-global.lock", "w+");
		g_ex.lock("xn");
		let g_sh = fs.open("/tmp/uapi-test-global.lock", "w+");
		t.assert_true(g_sh.lock("sn") !== true);
		g_sh.close();
		g_ex.lock("u"); g_ex.close();
		clean_locks();
	});

	t.it('default_acquire_pkg rejects unsafe package names', () => {
		let h = tx.default_acquire_pkg("/tmp/uapi-test-global.lock", "evil; rm -rf /");
		t.assert_true(type(h) == "object" && h.unavailable != null);
	});
});
