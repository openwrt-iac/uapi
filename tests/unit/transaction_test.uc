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

t.describe('transaction, cursor after the lock', () => {
	t.it('unloads the package after the lock and before fn, so fn reads what is on disk', () => {
		let order = [];
		let conn = ubus.stub({ uci: { fw: { r1: { '.type': 'rule' } } } });
		conn.uci_unload = function(pkg) { push(order, "unload " + pkg); return true; };
		tx.transaction(conn, build_params({
			acquire: function() { push(order, "lock"); return {}; },
			release: function() { push(order, "release"); },
			fn: function(c, p) { push(order, "fn"); return { ok: true, body: {} }; },
		}));
		t.assert_deep_equal(order, [ "lock", "unload fw", "fn", "release" ]);
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

t.describe('transaction, the restore writes back only what the request committed', () => {
	let imports = (conn) => map(filter(conn._state.uci_ops, (o) => o[0] == "import"), (o) => o[1]);

	// A reload of a package that the write left as it was reads the same config again, and it
	// can still fail, which put the restore of a write that changed nothing in motion.
	t.it('a write that changed nothing reloads nothing and restores nothing', () => {
		let conn = ubus.stub({ uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } } });
		conn.uci_commit = (pkg) => false;
		let tracker = track_reload();
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			reload: tracker.fn,
		}));
		t.assert_true(r.ok);
		t.assert_deep_equal([ r.reload_status, r.reload_services, r.kernel_status ], [ "no_reload", [], "no_kernel" ]);
		t.assert_deep_equal(tracker.calls, []);
		t.assert_deep_equal(imports(conn), []);
	});

	// LuCI deletes and commits a section that the batch wrote into while the batch runs, so the
	// replay of the batch's writes to that package fails. The snapshot of that package predates
	// LuCI's delete, and writing it back brought the section back. The cursor still held the writes
	// of the packages that the batch did not commit, and the restore read them. The reload comes
	// after every commit, so a failed commit leaves no daemon to reload.
	let batch = function(conn, reload) {
		let r = tx.multi_transaction(conn, {
			packages: [ "aa", "bb", "cc", "dd" ],
			lock_path: "/tmp/uapi-test-restore-global.lock", pkg_lock_prefix: "/tmp/uapi-test-restore-pkg.",
			fn: (c) => ({ ok: true, body: {} }),
			reload: reload ?? noop_reload, check_services: noop_check,
		});
		for (let f in [ "global.lock", "pkg.aa.lock", "pkg.bb.lock", "pkg.cc.lock", "pkg.dd.lock" ])
			require('fs').unlink("/tmp/uapi-test-restore-" + f);
		return r;
	};
	let restored = (conn) => filter(conn._state.uci_ops, (o) => o[0] == "import" || o[0] == "revert");
	const CONFLICT = "another writer changed the package cc during the request, and the writes of the request no longer apply to it: uci set cc: Entry not found";

	t.it('a batch whose replay no longer applies answers conflict, after it restores what it committed and drops the rest', () => {
		let conn = ubus.stub({ uci: { aa: {}, bb: {}, cc: {}, dd: {} } });
		conn.uci_commit = (pkg) => (pkg == "cc") ? { conflict: CONFLICT } : (pkg == "aa");
		let tracker = track_reload();
		let r = batch(conn, tracker.fn);
		t.assert_deep_equal(r, { ok: false, kind: "conflict",
		                         message: CONFLICT + ". Nothing was written. A retry reads the new state." });
		t.assert_deep_equal(restored(conn), [ [ "revert", "bb" ], [ "revert", "cc" ], [ "revert", "dd" ], [ "import", "aa" ] ]);
		t.assert_deep_equal(tracker.calls, []);
	});

	t.it('a batch whose commit the cursor refuses is restored the same way, and reports the refusal', () => {
		let conn = ubus.stub({ uci: { aa: {}, bb: {}, cc: {}, dd: {} } });
		conn.uci_commit = function(pkg) {
			if (pkg == "cc") die("uci commit cc: No space left on device");
			return pkg == "aa";
		};
		let tracker = track_reload();
		let r = batch(conn, tracker.fn);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(r.reload_error, "uci_commit(cc) failed: uci commit cc: No space left on device");
		t.assert_deep_equal(restored(conn), [ [ "revert", "bb" ], [ "revert", "cc" ], [ "revert", "dd" ], [ "import", "aa" ] ]);
		t.assert_deep_equal(tracker.calls, []);
	});

	// A 500 must not tell the client that nothing was written.
	t.it('a conflict that the restore cannot undo is unrecovered, and says only what happened', () => {
		let conn = ubus.stub({ uci: { aa: {}, bb: {}, cc: {}, dd: {} } });
		conn.uci_commit = (pkg) => (pkg == "cc") ? { conflict: CONFLICT } : (pkg == "aa");
		conn.uci_import = function() { die("restore of aa: cannot open it"); };
		let r = batch(conn);
		t.assert_deep_equal([ r.kind, r.reload_error, r.restore_error ],
		                    [ "reload_failed_unrecovered", CONFLICT, "restore of aa: cannot open it" ]);
	});
});

t.describe('multi_transaction, the reload of a batch', () => {
	function batch(conn, reload) {
		let r = tx.multi_transaction(conn, {
			packages: [ "fw", "net" ], reload_services: { fw: [ "firewall" ], net: [ "network" ] },
			lock_path: "/tmp/uapi-test-reload-global.lock", pkg_lock_prefix: "/tmp/uapi-test-reload-pkg.",
			fn: (c) => ({ ok: true, body: {} }), reload, check_services: noop_check,
		});
		for (let f in [ "global.lock", "pkg.fw.lock", "pkg.net.lock" ])
			require('fs').unlink("/tmp/uapi-test-reload-" + f);
		return r;
	}

	t.it('runs the services of the packages that the batch committed', () => {
		let conn = ubus.stub({ uci: { fw: {}, net: {} } });
		conn.uci_commit = (pkg) => pkg == "fw";
		let tracker = track_reload();
		let r = batch(conn, tracker.fn);
		t.assert_true(r.ok);
		t.assert_deep_equal(tracker.calls, [ [ "firewall" ] ]);
		t.assert_deep_equal([ r.reload_status, r.reload_services ], [ "ok", [ "firewall" ] ]);
	});

	t.it('runs none when the batch committed nothing', () => {
		let conn = ubus.stub({ uci: { fw: {}, net: {} } });
		conn.uci_commit = (pkg) => false;
		let tracker = track_reload();
		let r = batch(conn, tracker.fn);
		t.assert_true(r.ok);
		t.assert_deep_equal(tracker.calls, []);
		t.assert_deep_equal([ r.reload_status, r.reload_services, r.kernel_status ], [ "no_reload", [], "no_kernel" ]);
	});

	t.it('checks the init scripts of every package before it takes a lock', () => {
		let seen = null;
		let r = tx.multi_transaction(ubus.stub({ uci: { fw: {}, net: {} } }), {
			packages: [ "fw", "net" ], reload_services: { fw: [ "firewall" ], net: [ "network" ] },
			check_services: function(s) { seen = s; return "init script /etc/init.d/network not found"; },
		});
		t.assert_equal(r.kind, "init_script_missing");
		t.assert_deep_equal(seen, [ "firewall", "network" ]);
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

t.describe('transaction, config pre-flight', () => {
	t.it('refuses a package whose config file is missing, before any uci op', () => {
		let conn = ubus.stub({ uci: {}, missing_packages: [ "wireless" ] });
		let r = tx.transaction(conn, build_params({
			package: "wireless", reload_services: [],
			acquire: function() { return {}; }, release: function() {},
		}));
		t.assert_equal(r.kind, "config_missing");
		t.assert_true(match(r.message, /\/etc\/config\/wireless not found/) != null);
		t.assert_deep_equal(conn._state.uci_ops, []);
	});

	t.it('reports a missing init script first', () => {
		let conn = ubus.stub({ uci: {}, missing_packages: [ "wireless" ] });
		let r = tx.transaction(conn, build_params({
			package: "wireless",
			check_services: function() { return "init script /etc/init.d/x not found"; },
		}));
		t.assert_equal(r.kind, "init_script_missing");
	});

	t.it('refuses a batch that names a missing package, before any lock or uci op', () => {
		let conn = ubus.stub({ uci: { fw: {} }, missing_packages: [ "wireless" ] });
		let r = tx.multi_transaction(conn, {
			packages: [ "fw", "wireless" ],
			fn: function(c) {
				c.uci_set("fw", "r1", "target", "ACCEPT");
				return { ok: true, body: {} };
			},
			reload: noop_reload, check_services: noop_check,
		});
		t.assert_equal(r.kind, "config_missing");
		t.assert_deep_equal(conn._state.uci_ops, []);
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

// unbound refuses a line that it cannot parse only after its init script answered 0, so the reload
// alone reports success for a write that leaves it down.
t.describe('transaction, daemons that must keep running after the reload', () => {
	function unbound(states) {
		let n = 0;
		let conn = ubus.stub({ uci: { unbound_srv: { main: { '.type': 'unbound_srv', enabled: '0' } } } });
		conn.set_ubus_response("service", "list", function(args) {
			let s = states[min(n++, length(states) - 1)];
			return (s == null) ? {} : { [args.name]: { instances: { unbound: s } } };
		});
		return conn;
	}
	const UP = { running: true, pid: 10 }, UP2 = { running: true, pid: 11 }, DOWN = { running: false, exit_code: 1 };

	t.it('watches unbound after a reload of unbound or unbound-uci-ext only', () => {
		for (let svc in [ "unbound", "unbound-uci-ext" ])
			t.assert_true(tx.default_watch(unbound([ UP ]), [ svc ], { unbound: 0 }, 0) != null, svc);
		let conn = unbound([ UP ]);
		t.assert_equal(tx.default_watch(conn, [ "firewall", "network" ], { unbound: 0 }, 0), null);
		t.assert_equal(length(conn._state.ubus_calls), 0);
	});

	t.it('blames the write only when unbound ran before it', () => {
		t.assert_equal(tx.default_watch(unbound([ DOWN ]), [ "unbound" ], { unbound: 0 }, 0), null);
		t.assert_equal(tx.default_watch(unbound([ null ]), [ "unbound" ], { unbound: 0 }, 0), null);
	});

	t.it('passes while unbound runs, a new pid included, and fails when it stops', () => {
		t.assert_equal(tx.default_watch(unbound([ UP, UP2 ]), [ "unbound" ], { unbound: 0 }, 0)(), null);
		t.assert_equal(tx.default_watch(unbound([ UP, DOWN ]), [ "unbound" ], { unbound: 0 }, 0)(),
		               "unbound stopped after the reload, with exit code 1");
		t.assert_equal(tx.default_watch(unbound([ UP, { running: false } ]), [ "unbound" ], { unbound: 0 }, 0)(),
		               "unbound stopped after the reload");
	});

	// `restart` is a stop and then a start, and procd lists no instance in between.
	t.it('an instance that service list does not show is being restarted, not stopped', () => {
		t.assert_equal(tx.default_watch(unbound([ UP, null ]), [ "unbound" ], { unbound: 0 }, 0)(), null);
		t.assert_equal(tx.default_watch(unbound([ UP, null, UP2 ]), [ "unbound" ], { unbound: 2 }, 1)(), null);
		t.assert_equal(tx.default_watch(unbound([ UP, null, DOWN ]), [ "unbound" ], { unbound: 2 }, 1)(),
		               "unbound stopped after the reload, with exit code 1");
	});

	t.it('polls until the end of the window, so a later stop counts', () => {
		let conn = unbound([ UP, UP2, UP2, DOWN ]);
		t.assert_equal(tx.default_watch(conn, [ "unbound-uci-ext" ], { unbound: 2 }, 1)(),
		               "unbound stopped after the reload, with exit code 1");
		t.assert_equal(tx.default_watch(unbound([ UP, UP2, UP2, UP2, DOWN ]), [ "unbound" ], { unbound: 2 }, 1)(), null);
	});

	function write(conn, states_of_check) {
		let n = 0, reloads = 0;
		return tx.transaction(conn, build_params({
			package: "unbound_srv", reload_services: [ "unbound-uci-ext" ],
			acquire: function() { return {}; }, release: function() {},
			reload: function(s) { reloads++; return null; },
			watch: function(c, s) { return () => states_of_check[n++]; },
			fn: function(c, pkg) {
				c.uci_set(pkg, "main", "enabled", "1");
				return { ok: true, body: {} };
			},
		}));
	}

	t.it('a daemon that stops restores the previous config and reports reload_failed_restored', () => {
		let conn = unbound([ UP ]);
		let r = write(conn, [ "unbound stopped after the reload, with exit code 1", null ]);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(r.reload_error, "unbound stopped after the reload, with exit code 1");
		t.assert_equal(conn._state.uci.unbound_srv.main.enabled, "0");
	});

	t.it('the restore runs the same check, so a daemon that stays down is unrecovered', () => {
		let r = write(unbound([ UP ]), [ "unbound stopped after the reload", "unbound stopped after the reload" ]);
		t.assert_equal(r.kind, "reload_failed_unrecovered");
		t.assert_true(index(r.restore_error, "unbound stopped") >= 0);
	});

	t.it('a daemon that keeps running lets the write succeed', () => {
		let r = write(unbound([ UP ]), [ null ]);
		t.assert_true(r.ok);
	});

	// The state before the write is read before its reload, and the restore checks against it.
	function daemon(conn, after_write, after_restore) {
		let state = UP, reloads = 0;
		conn.set_ubus_response("service", "list", (args) => ({ unbound: { instances: { unbound: state } } }));
		return function(s) { state = (reloads++ == 0) ? after_write : after_restore; return null; };
	}

	t.it('reads the daemon before the reload, and the restore checks that it runs again', () => {
		for (let c in [ [ UP2, "reload_failed_restored" ], [ DOWN, "reload_failed_unrecovered" ] ]) {
			let conn = ubus.stub({ uci: { unbound_srv: { main: { '.type': 'unbound_srv', enabled: '0' } } } });
			let r = tx.transaction(conn, build_params({
				package: "unbound_srv", reload_services: [ "unbound-uci-ext" ],
				acquire: function() { return {}; }, release: function() {},
				reload: daemon(conn, DOWN, c[0]),
				watch: (cn, s) => tx.default_watch(cn, s, { unbound: 0 }, 0),
			}));
			t.assert_equal(r.kind, c[1]);
		}
	});

	t.it('a write to unbound_srv or unbound_ext also takes the lock of the unbound package', () => {
		for (let c in [ [ "unbound_srv", [ "unbound-uci-ext" ], [ "unbound" ] ], [ "unbound", [ "unbound" ], [] ],
		                [ "firewall", [ "firewall" ], [] ] ]) {
			let also = null;
			tx.transaction(ubus.stub(), build_params({
				package: c[0], reload_services: c[1],
				acquire: function(p, a) { also = a; return {}; }, release: function() {},
			}));
			t.assert_deep_equal(also, c[2], c[0]);
		}
		let r = tx.transaction(ubus.stub(), build_params({
			package: "unbound_ext", reload_services: [ "unbound-uci-ext" ],
			acquire: function() { return { contention: "package", package: "unbound" }; }, release: function() {},
		}));
		t.assert_equal(r.kind, "locked");
		t.assert_equal(r.package, "unbound");
	});

	t.it('a batch takes the lock of the unbound package and watches unbound too', () => {
		let prefix = "/tmp/uapi-test-stayup-pkg.", global = "/tmp/uapi-test-stayup-global.lock";
		let batch = function(conn, reload) {
			return tx.multi_transaction(conn, {
				packages: [ "unbound_srv" ], reload_services: { unbound_srv: [ "unbound-uci-ext" ] },
				lock_path: global, pkg_lock_prefix: prefix, check_services: noop_check, reload,
				watch: (cn, s) => tx.default_watch(cn, s, { unbound: 0 }, 0),
				fn: function(c) { c.uci_set("unbound_srv", "main", "enabled", "1"); return { ok: true }; },
			});
		};
		let held = fs.open(prefix + "unbound.lock", "w+");
		held.lock("xn");
		let conn = ubus.stub({ uci: { unbound_srv: { main: { '.type': 'unbound_srv', enabled: '0' } } } });
		let r = batch(conn, noop_reload);
		t.assert_equal(r.kind, "locked");
		t.assert_equal(r.package, "unbound");
		held.lock("u"); held.close();

		r = batch(conn, daemon(conn, DOWN, UP2));
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(conn._state.uci.unbound_srv.main.enabled, "0");
		for (let f in [ global, prefix + "unbound.lock", prefix + "unbound_srv.lock" ]) fs.unlink(f);
	});
});

// dnsmasq.init starts one procd instance per dnsmasq section, and dnsmasq refuses a line such as
// `dhcp-option=lan,3,not-an-address` only after the init script answered 0.
t.describe('transaction, dnsmasq after the reload', () => {
	const UP = { running: true, pid: 20 }, UP2 = { running: true, pid: 21 }, DOWN = { running: false, exit_code: 1 };
	const STOPPED = "dnsmasq stopped after the reload, with exit code 1";

	// The nth call of service list for a daemon answers its instances in states[n].
	function fake(states) {
		let calls = {};
		let conn = ubus.stub();
		conn.set_ubus_response("service", "list", function(args) {
			let n = calls[args.name] = (calls[args.name] ?? -1) + 1;
			return { [args.name]: { instances: states[min(n, length(states) - 1)][args.name] ?? {} } };
		});
		return conn;
	}
	let watch = (states, services, window_ms, step_ms) => tx.default_watch(fake(states), services, window_ms, step_ms);

	t.it('watches dnsmasq after a reload of dnsmasq, when one of its instances ran before', () => {
		t.assert_true(watch([ { dnsmasq: { main: UP } } ], [ "dnsmasq" ], { dnsmasq: 0 }, 0) != null);
		t.assert_equal(watch([ { dnsmasq: { main: DOWN } } ], [ "dnsmasq" ], { dnsmasq: 0 }, 0), null);
		t.assert_equal(watch([ {} ], [ "dnsmasq" ], { dnsmasq: 0 }, 0), null);
	});

	t.it('counts an instance that ran before and that procd reports as not running', () => {
		let check = (after) => watch([ { dnsmasq: { main: UP, guest: DOWN } }, after ], [ "dnsmasq" ], { dnsmasq: 0 }, 0)();
		t.assert_equal(check({ dnsmasq: { main: UP2, guest: DOWN } }), null);
		t.assert_equal(check({ dnsmasq: { guest: DOWN } }), null);
		t.assert_equal(check({ dnsmasq: { main: DOWN, guest: UP } }), STOPPED);
	});

	t.it('polls for the window of dnsmasq, and for the longer window of unbound in the same write', () => {
		const BOTH = { dnsmasq: { main: UP }, unbound: { unbound: UP } };
		let late = [ BOTH, BOTH, BOTH, BOTH, { ...BOTH, dnsmasq: { main: DOWN } } ];
		let windows = { dnsmasq: 2, unbound: 4 };
		t.assert_equal(watch(late, [ "dnsmasq" ], windows, 1)(), null);
		t.assert_equal(watch(late, [ "dnsmasq", "unbound-uci-ext" ], windows, 1)(), STOPPED);
		let unbound_down = map(late, (s) => ({ ...s, unbound: { unbound: DOWN } }));
		t.assert_equal(watch(unbound_down, [ "dnsmasq", "unbound-uci-ext" ], windows, 1)(), null);
	});

	function write(after_write, after_restore) {
		let state = UP, reloads = 0;
		let conn = ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', leasetime: '12h' } } } });
		conn.set_ubus_response("service", "list", (args) => ({ dnsmasq: { instances: { main: state } } }));
		let r = tx.transaction(conn, build_params({
			package: "dhcp", reload_services: [ "dnsmasq" ],
			acquire: function() { return {}; }, release: function() {},
			reload: function(s) { state = (reloads++ == 0) ? after_write : after_restore; return null; },
			watch: (cn, s) => tx.default_watch(cn, s, { dnsmasq: 0 }, 0),
			fn: function(c, pkg) { c.uci_set(pkg, "lan", "leasetime", "1h"); return { ok: true, body: {} }; },
		}));
		return { r, leasetime: conn._state.uci.dhcp.lan.leasetime };
	}

	t.it('a dhcp write after which dnsmasq stops restores the previous config', () => {
		let w = write(DOWN, UP2);
		t.assert_equal(w.r.kind, "reload_failed_restored");
		t.assert_equal(w.r.reload_error, STOPPED);
		t.assert_equal(w.leasetime, "12h");
		t.assert_equal(write(DOWN, DOWN).r.kind, "reload_failed_unrecovered");
		w = write(UP2, UP2);
		t.assert_true(w.r.ok);
		t.assert_equal(w.leasetime, "1h");
	});

	t.it('a dhcp write takes no lock beside its own, since dnsmasq reads its config from dhcp', () => {
		let also = null;
		tx.transaction(ubus.stub(), build_params({
			package: "dhcp", reload_services: [ "dnsmasq" ],
			acquire: function(p, a) { also = a; return {}; }, release: function() {},
		}));
		t.assert_deep_equal(also, []);
	});
});

function lock_is_free(path) {
	let fd = fs.open(path, "r");
	let ok = fd.lock("xn") === true;
	fd.close();
	return ok;
}

// uhttpd SIGKILLs a request when its client goes away or its script timeout runs out, so no
// release runs. A child that the request started under the locks had a copy of their fds, and
// the locks stayed taken until that child exited. This kills a process inside fn, as uhttpd
// does, and looks at the locks while the child it started still runs.
t.describe('transaction, a request killed under its locks', () => {
	t.it('leaves no lock to the child it started', () => {
		let global = "/tmp/uapi-test-kill-g.lock", prefix = "/tmp/uapi-test-kill-pkg.";
		let script = "/tmp/uapi-test-kill.uc", pidfile = "/tmp/uapi-test-kill.pid";
		fs.unlink(pidfile);
		fs.writefile(script, join("\n", [
			"let tx = require('transaction'), bus = require('bus');",
			sprintf("let paths = %J;", { global, prefix, pidfile }),
			"tx.multi_transaction(bus.stub({ uci: { firewall: { d: { '.type': 'defaults' } } } }), {",
			"	packages: [ 'firewall' ], lock_path: paths.global, pkg_lock_prefix: paths.prefix,",
			"	check_services: () => null, reload: () => null,",
			"	fn: () => system('sleep 30 >/dev/null 2>&1 & echo $! > ' + paths.pidfile + '; kill -9 $PPID'),",
			"});",
		]) + "\n");
		system("ucode -L src/lib " + script + " >/dev/null 2>&1");
		let pid = trim(fs.readfile(pidfile) ?? "");
		let free = { global: lock_is_free(global), firewall: lock_is_free(prefix + "firewall.lock") };
		if (pid != "") system("kill " + pid);
		for (let f in [ script, pidfile, global, prefix + "firewall.lock" ]) fs.unlink(f);
		t.assert_true(pid != "", "the killed process started no child");
		t.assert_deep_equal(free, { global: true, firewall: true }, "the child still holds a lock");
	});
});

t.describe('transaction.acquire_pkg_waiting', () => {
	let global = "/tmp/uapi-test-wait-g.lock", prefix = "/tmp/uapi-test-wait-pkg.";

	t.it('waits for a lock that its holder lets go', () => {
		let script = "/tmp/uapi-test-wait-holder.uc";
		fs.writefile(script, "let fs = require('fs'), f = fs.open(ARGV[0], 'w+');\n"
			+ "f.lock('x'); print('held\\n'); fs.stdout.flush(); sleep(300);\n");
		let holder = fs.popen("ucode " + script + " " + prefix + "uapi.lock", "r");
		let held = holder.read("line");
		let start = clock(true);
		let lock = tx.acquire_pkg_waiting("uapi", 3000, global, prefix);
		let end = clock(true);
		holder.close();
		fs.unlink(script);
		let waited_ms = (end[0] - start[0]) * 1000 + (end[1] - start[1]) / 1000000;
		tx.default_release_pkg(lock);
		for (let f in [ global, prefix + "uapi.lock" ]) fs.unlink(f);
		t.assert_equal(held, "held\n");
		t.assert_true(lock._g != null, sprintf("the wait answered %J", lock));
		t.assert_true(waited_ms >= 100, sprintf("the lock was free after %d ms", waited_ms));
	});

	t.it('answers the contention once the wait has passed', () => {
		let held = fs.open(prefix + "uapi.lock", "w+");
		held.lock("xn");
		let start = clock(true);
		let lock = tx.acquire_pkg_waiting("uapi", 300, global, prefix);
		let end = clock(true);
		held.close();
		tx.default_release_pkg(lock);
		for (let f in [ global, prefix + "uapi.lock" ]) fs.unlink(f);
		let waited_ms = (end[0] - start[0]) * 1000 + (end[1] - start[1]) / 1000000;
		t.assert_deep_equal(lock, { contention: "package", package: "uapi" });
		t.assert_true(waited_ms >= 300, sprintf("gave up after %d ms", waited_ms));
	});
});
