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

// A wireguard peer edit leaves the parent `interface` section untouched, so the
// network reload converges nothing and the peer never reaches the kernel. The
// post-commit apply exists to close that, and it has to fail the same way a
// reload does so a half-applied write rolls back.
t.describe('transaction, post-commit kernel apply', () => {
	function track() {
		let calls = [];
		return { calls: calls,
		         fn: function(conn, ops) { push(calls, [...ops]); return null; } };
	}

	t.it('applies the ops the write collected, after the reload', () => {
		let order = [];
		let conn = ubus.stub();
		let ops = [];
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: ops,
			reload: function(s) { push(order, "reload"); return null; },
			wg_apply: function(c, o) { push(order, "apply:" + length(o)); return null; },
			fn: function(c, pkg) {
				push(ops, { iface: "wg1", action: "set" });
				return { ok: true, body: {} };
			},
		}));
		t.assert_true(r.ok);
		t.assert_deep_equal(order, ["reload", "apply:1"]);
	});

	// The array is handed to the transaction before fn runs and read after the
	// commit. If it were copied at params-build time the op list would always be
	// empty, which is the whole bug this step exists to fix.
	t.it('reads the collected ops after fn ran, not when params were built', () => {
		let conn = ubus.stub();
		let ops = [];
		let tracker = track();
		tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: ops, wg_apply: tracker.fn,
			fn: function(c, pkg) {
				push(ops, { iface: "wg2", action: "remove", public_key: "k" });
				return { ok: true, body: {} };
			},
		}));
		t.assert_equal(length(tracker.calls), 1);
		t.assert_equal(tracker.calls[0][0].iface, "wg2");
	});

	t.it('does not apply when fn failed, since nothing was committed', () => {
		let conn = ubus.stub();
		let tracker = track();
		tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: [{ iface: "wg1", action: "set" }], wg_apply: tracker.fn,
			fn: function(c, pkg) { return { ok: false, kind: "validation", errors: [] }; },
		}));
		t.assert_equal(length(tracker.calls), 0);
	});

	t.it('never applies when the reload failed, on either the apply or the restore', () => {
		let conn = ubus.stub();
		let tracker = track();
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: [{ iface: "wg1", action: "set" }], wg_apply: tracker.fn,
			reload: reload_failing("netifd: bad"),
		}));
		t.assert_equal(r.kind, "reload_failed_unrecovered");
		t.assert_equal(length(tracker.calls), 0);
	});

	t.it('an apply failure restores the snapshot and reports reload_failed_restored', () => {
		let conn = ubus.stub({ uci: { fw: { r1: { '.type': 'rule', target: 'DROP' } } } });
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: [{ iface: "wg1", action: "set" }],
			wg_apply: function(c, o) { return "wg set on wg1 failed: Name does not resolve"; },
			wg_reconcile: function(c, ifaces) { return null; },
		}));
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_true(index(r.reload_error, "Name does not resolve") >= 0);
		t.assert_equal(conn._state.uci.fw.r1.target, "DROP");
	});

	// A batch can apply several peers before failing on a later one, so replaying
	// the request's own operations would reapply the failure instead of undoing
	// what landed. The restore reconciles the touched interfaces instead.
	t.it('the restore reconciles the touched interfaces, it does not replay the ops', () => {
		let conn = ubus.stub();
		let replayed = 0, reconciled = [];
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: [{ iface: "wgA", action: "set" }, { iface: "wgB", action: "set" }],
			wg_apply: function(c, o) { replayed++; return "wg set on wgB failed"; },
			wg_reconcile: function(c, ifaces) { reconciled = ifaces; return null; },
		}));
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(replayed, 1);
		t.assert_deep_equal(reconciled, ["wgA", "wgB"]);
	});

	t.it('a reconcile that also fails is unrecovered', () => {
		let conn = ubus.stub();
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: [{ iface: "wg1", action: "set" }],
			wg_apply: function(c, o) { return "wg set failed"; },
			wg_reconcile: function(c, ifaces) { return "reconcile failed too"; },
		}));
		t.assert_equal(r.kind, "reload_failed_unrecovered");
	});
});

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

// A write that reached the kernel and one that only reached uci both answer 200,
// so the result has to say which happened. Skipping is normal: a down interface
// holds no peer state and ifup reads the peers from uci.
t.describe('transaction kernel_status', () => {
	function applier(names) {
		return function(c, o, applied) {
			for (let n in names) push(applied, n);
			return null;
		};
	}

	function run(ops_to_add, apply_fn) {
		let conn = ubus.stub({ uci: { fw: {} } });
		let ops = [];
		return tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: ops, wg_apply: apply_fn,
			fn: function(c, pkg) {
				for (let o in ops_to_add) push(ops, o);
				return { ok: true, body: {} };
			},
		}));
	}

	t.it('reports no_kernel when the write collected no kernel operations', () => {
		let r = run([], applier([]));
		t.assert_true(r.ok);
		t.assert_equal(r.kernel_status, "no_kernel");
		t.assert_deep_equal(r.kernel_applied, []);
	});

	t.it('reports ok and names the interface when every target was applied', () => {
		let r = run([{ iface: "wg0", action: "set" }], applier(["wg0"]));
		t.assert_equal(r.kernel_status, "ok");
		t.assert_deep_equal(r.kernel_applied, ["wg0"]);
	});

	t.it('reports skipped when a target existed and none was applied', () => {
		let r = run([{ iface: "wg0", action: "set" }], applier([]));
		t.assert_equal(r.kernel_status, "skipped");
		t.assert_deep_equal(r.kernel_applied, []);
	});

	t.it('reports partial when one of two interfaces was down', () => {
		let r = run([{ iface: "wg0", action: "set" }, { iface: "wg1", action: "set" }],
		            applier(["wg0"]));
		t.assert_equal(r.kernel_status, "partial");
		t.assert_deep_equal(r.kernel_applied, ["wg0"]);
	});

	// Two peers on one tunnel are one target, not two, or a multi-peer write to a
	// single up interface would report partial.
	t.it('counts interfaces rather than operations', () => {
		let r = run([{ iface: "wg0", action: "set" }, { iface: "wg0", action: "remove", public_key: "k" }],
		            applier(["wg0"]));
		t.assert_equal(r.kernel_status, "ok");
	});
});

// The applied list is recorded on the up/down decision, so it can name an
// interface whose later operation failed. That must never surface: a failed apply
// routes into the restore recipe, whose result carries no kernel fields at all.
t.describe('transaction kernel fields on a failed apply', () => {
	t.it('reports no kernel status or applied list when the apply failed', () => {
		let conn = ubus.stub({ uci: { fw: {} } });
		let ops = [];
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			wg_ops: ops,
			wg_apply: function(c, o, applied) {
				push(applied, "wg0");
				return "wg set on wg0 failed: bad endpoint";
			},
			fn: function(c, pkg) {
				push(ops, { iface: "wg0", action: "set" });
				return { ok: true, body: {} };
			},
		}));
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(r.kernel_status, null);
		t.assert_equal(r.kernel_applied, null);
	});
});
