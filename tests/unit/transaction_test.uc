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

// How procd keeps a `procd_add_reload_trigger "dhcp"` of an init script.
const DHCP_TRIGGER = [ "config.change", [ "if", [ "eq", "package", "dhcp" ], [ "run_script", "/etc/init.d/x", "reload" ] ], 1000 ];

function running_now(conn, names) {
	conn.set_ubus_response("service", "list", (a) => (index(names, a.name) >= 0)
		? { [a.name]: { instances: { [a.name]: { running: true, pid: 10 } }, triggers: [ DHCP_TRIGGER ] } } : {});
	return conn;
}

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
		t.assert_equal(r.unchanged, null);
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
		t.assert_true(r.unchanged, "a raw write tells this from a write whose daemons do not run by it");
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

// The commit replays the writes of the request over what LuCI or a shell committed while the
// request ran, and the restore wrote back the snapshot taken at the lock, which undid that commit.
// Here the package is a string, another writer appends to it during fn and the commit appends the
// request's write, so the restore has to leave what the other writer appended.
t.describe('transaction, the restore keeps what another writer committed during the request', () => {
	function on(file) {
		let conn = ubus.stub();
		conn.uci_export = (pkg) => file[pkg];
		conn.uci_commit = function(pkg) { file[pkg] += "+request"; return true; };
		conn.uci_import = function(pkg, snapshot, committed) {
			if (file[pkg] != committed) return false;
			file[pkg] = snapshot;
			return true;
		};
		return conn;
	}

	t.it('a write', () => {
		let file = { fw: "seed" };
		let r = tx.transaction(on(file), build_params({
			acquire: function() { return {}; }, release: function() {},
			reload: reload_flaky(1),
			fn: function(c, pkg) { file.fw += "+luci"; return { ok: true, body: {} }; },
		}));
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(file.fw, "seed+luci");
	});

	t.it('a batch, in each package that it committed', () => {
		let file = { aa: "seed", bb: "seed" };
		let r = tx.multi_transaction(on(file), {
			packages: [ "aa", "bb" ],
			lock_path: "/tmp/uapi-test-kept-global.lock", pkg_lock_prefix: "/tmp/uapi-test-kept-pkg.",
			fn: function(c) { file.aa += "+luci"; file.bb += "+shell"; return { ok: true, body: {} }; },
			reload: reload_flaky(1), check_services: noop_check,
		});
		for (let f in [ "global.lock", "pkg.aa.lock", "pkg.bb.lock" ])
			require('fs').unlink("/tmp/uapi-test-kept-" + f);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_deep_equal(file, { aa: "seed+luci", bb: "seed+shell" });
	});

	// A commit by LuCI or a shell after the commit of the request, while the daemons reload, goes into
	// the file that the request committed. The snapshot predates it, and writing it back undid it too.
	const LEFT = "another writer committed to the package %s after the commit of the request, so the restore left it as that writer left it";
	// The first reload fails after the other writer appends to the packages in `commits`.
	function reload_during(file, commits) {
		let calls = [];
		return { calls, fn: function(services) {
			push(calls, services);
			if (length(calls) > 1) return null;
			for (let pkg, w in commits) file[pkg] += w;
			return "fw4: bad";
		} };
	}
	function write(file, commits) {
		let reload = reload_during(file, commits);
		let r = tx.transaction(on(file), build_params({
			acquire: function() { return {}; }, release: function() {},
			reload: reload.fn, fn: () => ({ ok: true, body: {} }),
		}));
		return { r, reloads: length(reload.calls) };
	}
	function batch(file, commits) {
		let reload = reload_during(file, commits);
		let r = tx.multi_transaction(on(file), {
			packages: keys(file), reload_services: { aa: [ "a" ], bb: [ "b" ] },
			lock_path: "/tmp/uapi-test-left-global.lock", pkg_lock_prefix: "/tmp/uapi-test-left-pkg.",
			fn: () => ({ ok: true, body: {} }), reload: reload.fn, check_services: noop_check,
		});
		for (let f in [ "global.lock", "pkg.aa.lock", "pkg.bb.lock" ])
			require('fs').unlink("/tmp/uapi-test-left-" + f);
		return { r, reloads: reload.calls };
	}

	t.it('a write leaves the package that another writer committed to during the reload, and reloads nothing again', () => {
		let file = { fw: "seed" };
		let w = write(file, { fw: "+luci" });
		t.assert_deep_equal([ w.r.kind, w.r.reload_error, w.r.restore_error, w.reloads ],
		                    [ "reload_failed_unrecovered", "fw4: bad", sprintf(LEFT, "fw"), 1 ]);
		t.assert_equal(file.fw, "seed+request+luci");
		file = { fw: "seed" };
		w = write(file, {});
		t.assert_deep_equal([ w.r.kind, w.reloads, file.fw ], [ "reload_failed_restored", 2, "seed" ]);
	});

	t.it('a write leaves a package whose file it could not read after its commit, and says why', () => {
		let file = { fw: "seed" };
		let conn = on(file), exports = 0;
		conn.uci_export = (pkg) => (exports++ == 0) ? file[pkg] : null;
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; }, release: function() {},
			reload: reload_failing("fw4: bad"), fn: () => ({ ok: true, body: {} }),
		}));
		t.assert_deep_equal([ r.kind, r.restore_error, file.fw ],
		                    [ "reload_failed_unrecovered", "the file of the package fw could not be read after the commit "
		                      + "of the request, so the restore left it as it is", "seed+request" ]);
	});

	t.it('a batch leaves that package, and restores and reloads the others as before', () => {
		let file = { aa: "seed", bb: "seed" };
		let b = batch(file, { aa: "+shell" });
		t.assert_deep_equal([ b.r.kind, b.r.reload_error, b.r.restore_error ],
		                    [ "reload_failed_unrecovered", "fw4: bad", sprintf(LEFT, "aa") ]);
		t.assert_deep_equal(file, { aa: "seed+request+shell", bb: "seed" });
		t.assert_deep_equal(b.reloads, [ [ "a", "b" ], [ "b" ] ]);
		file = { aa: "seed", bb: "seed" };
		b = batch(file, { aa: "+shell", bb: "+luci" });
		t.assert_equal(b.r.restore_error, sprintf(LEFT, "aa") + "; " + sprintf(LEFT, "bb"));
		t.assert_deep_equal(file, { aa: "seed+request+shell", bb: "seed+request+luci" });
		t.assert_deep_equal(b.reloads, [ [ "a", "b" ] ]);
		file = { aa: "seed", bb: "seed" };
		b = batch(file, {});
		t.assert_deep_equal([ b.r.kind, length(b.reloads), file ], [ "reload_failed_restored", 2, { aa: "seed", bb: "seed" } ]);
	});

	// The daemon of a package that the restore left holds the config that just failed.
	t.it('a batch checks after the restore only the daemons of the packages that it wrote back', () => {
		let file = { aa: "seed", bb: "seed" }, checked = [];
		let reload = reload_during(file, { aa: "+shell" });
		tx.multi_transaction(on(file), {
			packages: [ "aa", "bb" ], reload_services: { aa: [ "a" ], bb: [ "b" ] },
			lock_path: "/tmp/uapi-test-left-global.lock", pkg_lock_prefix: "/tmp/uapi-test-left-pkg.",
			fn: () => ({ ok: true, body: {} }), reload: reload.fn, check_services: noop_check,
			watch: () => function(only) { push(checked, only); return null; },
		});
		for (let f in [ "global.lock", "pkg.aa.lock", "pkg.bb.lock" ])
			require('fs').unlink("/tmp/uapi-test-left-" + f);
		t.assert_deep_equal(checked, [ [ "b" ] ]);
	});

	t.it('a batch reconciles the kernel after the restore only when it wrote the network package back', () => {
		for (let left in [ true, false ]) {
			let file = { network: "seed", bb: "seed" }, reconciled = null;
			let reload = reload_during(file, left ? { network: "+luci" } : {});
			tx.multi_transaction(on(file), {
				packages: [ "network", "bb" ], reload_services: { network: [ "n" ], bb: [ "b" ] },
				lock_path: "/tmp/uapi-test-left-global.lock", pkg_lock_prefix: "/tmp/uapi-test-left-pkg.",
				fn: () => ({ ok: true, body: {} }), reload: reload.fn, check_services: noop_check,
				wg_ops: [ { iface: "wg0", action: "set", public_key: "k" } ], wg_apply: () => null,
				wg_reconcile: (c, ifaces) => { reconciled = ifaces; return null; },
			});
			for (let f in [ "global.lock", "pkg.network.lock", "pkg.bb.lock" ])
				require('fs').unlink("/tmp/uapi-test-left-" + f);
			t.assert_deep_equal(reconciled, left ? [] : [ "wg0" ]);
		}
	});
});

// A reload that did not end, or whose descendants kept its pipe open, held the request and its
// locks until uhttpd killed it at its 60 s script timeout: the client got a 502, and uci kept the
// new config with no restore. Killing the reload at a bound made the restore wait on the procd lock
// that its child still held.
t.describe('transaction, the time that uapi waits for the reloads of a request', () => {
	let fs = require('fs');
	const DIR = "/tmp/uapi-test-reload-budget";
	const STILL = (svc, s) => sprintf("%s reload was still running when the %s s that uapi waits for the reloads of a request "
	                                   + "ran out, so its result is unknown", svc, s);
	// Each reload takes the next line of `plan`: `hang` runs 2 s, `slow` 0.3 s, `fail` exits 3,
	// `slowfail` does both, and `detach` leaves a process that holds its output. Each script appends
	// its name to `ran` when it ends. `w` waits for its own child first. Each call gets a directory
	// of its own, so that a reload that an earlier test left running writes nowhere that a later one reads.
	let dir = null, calls = 0;
	function scripts(plan) {
		dir = sprintf("%s/%d", DIR, ++calls);
		system(sprintf("rm -rf %s; mkdir -p %s", dir, dir));
		fs.writefile(dir + "/plan", join("\n", plan) + "\n");
		for (let svc in [ "firewall", "a", "b", "c" ]) {
			fs.writefile(dir + "/" + svc, "#!/bin/sh\n[ \"$1\" = reload ] || exit 2\n"
				+ sprintf("p=$(head -n 1 %s/plan); sed -i 1d %s/plan; trap 'echo %s >>%s/ran' EXIT\n", dir, dir, svc, dir)
				+ sprintf("case $p in\nhang) echo '%s: applying'; sleep 2 ;;\nslow|slowfail) sleep 0.3 ;;\n", svc)
				+ "detach) sleep 2 & ;;\nesac\n"
				+ sprintf("case $p in\n*fail) echo '%s: bad rule'; exit 3 ;;\nesac\nexit 0\n", svc));
			fs.chmod(dir + "/" + svc, 0755);
		}
		fs.writefile(dir + "/w", "#!/bin/sh\nsleep 0.1 & wait $!\nexit 0\n");
		fs.writefile(dir + "/fds", "#!/bin/sh\nls -l /proc/$$/fd | grep -c uapi-reload\nexit 1\n");
		for (let svc in [ "w", "fds" ]) fs.chmod(dir + "/" + svc, 0755);
	}
	function ran() { return trim(fs.readfile(dir + "/ran") ?? ""); }
	function write(batch, services, budget_ms) {
		let conn = ubus.stub({ uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } } });
		let budget = { ms: budget_ms ?? 300 };
		let p = { check_services: noop_check, reload: (s) => tx.default_reload(s, budget, dir) };
		let start = clock(true);
		let r = batch
			? tx.multi_transaction(conn, { ...p, packages: [ "fw" ], reload_services: { fw: services ?? [ "firewall" ] },
			                               lock_path: "/tmp/uapi-test-bound-global.lock", pkg_lock_prefix: "/tmp/uapi-test-bound-pkg.",
			                               fn: (c) => { c.uci_set("fw", "r1", "target", "DROP"); return { ok: true, body: {} }; } })
			: tx.transaction(conn, build_params({ ...p, reload_services: services ?? [ "firewall" ],
			                                      acquire: function() { return {}; }, release: function() {},
			                                      fn: function(c, pkg) { c.uci_set(pkg, "r1", "target", "DROP"); return { ok: true, body: {} }; } }));
		let end = clock(true);
		for (let f in [ "/tmp/uapi-test-bound-global.lock", "/tmp/uapi-test-bound-pkg.fw.lock" ]) fs.unlink(f);
		return { r, took: (end[0] - start[0]) * 1000 + (end[1] - start[1]) / 1000000, target: conn._state.uci.fw.r1.target };
	}

	t.it('answers unverified for a reload still running when the time is up, and keeps the commit', () => {
		scripts([ "hang", "hang" ]);
		for (let batch in [ false, true ]) {
			let w = write(batch);
			t.assert_deep_equal([ w.r.ok, w.r.reload_status, w.r.unverified, w.target ],
			                    [ true, "unverified", STILL("firewall", "0.3"), "DROP" ]);
			t.assert_true(w.took < 1500, sprintf("the write waited for %d ms", w.took));
		}
		t.assert_equal(ran(), "", "a reload ended before the time ran out");
		sleep(2200);
		t.assert_equal(ran(), "firewall\nfirewall", "uapi killed a reload");
	});

	// A system write reloads up to five services. Three reloads of 0.3 s each fit in 0.8 s apart.
	t.it('waits for the reloads of all services for that time in all', () => {
		scripts([ "slow", "slow", "slow" ]);
		let w = write(false, [ "a", "b", "c" ], 800);
		t.assert_equal(w.r.reload_status, "unverified");
		t.assert_match(w.r.unverified, /^[bc] reload was still running when the 0.8 s /);
	});

	t.it('reloads the services after the one still running once it ends, unless it fails', () => {
		scripts([ "hang", "ok", "ok" ]);
		let w = write(false, [ "a", "b", "c" ]);
		t.assert_equal(w.r.unverified, STILL("a", "0.3") + ", and the reloads of b, c follow it unless it fails");
		sleep(2200);
		t.assert_equal(ran(), "a\nb\nc");
		scripts([ "slowfail", "ok" ]);
		w = write(false, [ "a", "b" ], 100);
		sleep(500);
		t.assert_deep_equal([ w.r.reload_status, ran() ], [ "unverified", "a" ]);
	});

	t.it('restores after a reload that fails within the time, and the reload of the restore shares it', () => {
		scripts([ "fail", "ok" ]);
		let w = write(false);
		t.assert_deep_equal([ w.r.kind, w.r.reload_error, w.target ], [ "reload_failed_restored", "firewall exited with code 3: firewall: bad rule", "ACCEPT" ]);
		// The failed reload takes 0.3 s of the 0.5 s, and the reload of the restore 0.3 s more.
		for (let batch in [ false, true ]) {
			scripts([ "slowfail", "slow" ]);
			w = write(batch, null, 500);
			t.assert_deep_equal([ w.r.kind, w.r.reload_error, w.r.restore_error, w.target ],
			                    [ "reload_failed_unrecovered", "firewall exited with code 3: firewall: bad rule",
			                      "reload during restore did not finish: " + STILL("firewall", "0.5"), "ACCEPT" ]);
		}
	});

	t.it('returns when the script exits, while a process that it started keeps its output open', () => {
		scripts([ "detach" ]);
		let w = write(false, null, 5000);
		t.assert_deep_equal([ w.r.reload_status, w.target ], [ "ok", "DROP" ]);
		t.assert_true(w.took < 1500, sprintf("the write waited for %d ms", w.took));
	});

	// system() with a timeout blocks SIGCHLD in its child, and ash then never sees a child end that
	// it waits for before it has waited for any command in the foreground.
	t.it('runs a script that waits for its own child', () => {
		scripts([]);
		t.assert_equal(write(false, [ "w" ], 1000).r.reload_status, "ok");
	});

	// A daemon that a script starts held the files of every other reload of the request.
	t.it('gives each script its own output file and no other', () => {
		scripts([ "ok" ]);
		t.assert_equal(tx.default_reload([ "a", "fds" ], { ms: 2000 }, dir), "fds exited with code 1: 2");
	});

	// A shell that cannot fork the reloads exits 2, and uapi waited out the time for them.
	t.it('fails a reload that the shell could not start, and one whose exit codes have no room', () => {
		scripts([ "ok" ]);
		let saved = { system: global.system, mkstemp: fs.mkstemp };
		global.system = () => 2;
		let shell = tx.default_reload([ "firewall" ], { ms: 300 }, dir);
		global.system = saved.system;
		fs.mkstemp = function(t) {
			let f = saved.mkstemp(t);
			return { write: () => 0, flush: () => true, seek: (o) => f.seek(o), fileno: () => f.fileno(), close: () => f.close() };
		};
		let full = tx.default_reload([ "firewall" ], { ms: 300 }, dir);
		fs.mkstemp = saved.mkstemp;
		t.assert_deep_equal([ shell, full ], [ "could not start the reload of firewall: the shell exited with code 2",
		                                       "could not start the reload of firewall: cannot reserve a file for its exit codes" ]);
	});

	t.it('keeps the output and the exit code of a reload that fails', () => {
		scripts([ "fail" ]);
		t.assert_equal(tx.default_reload([ "firewall" ], { ms: 300 }, dir), "firewall exited with code 3: firewall: bad rule");
	});

	t.it('waits 20 s by default', () => {
		scripts([ "ok" ]);
		let budget = {}, start = clock(true);
		t.assert_equal(tx.default_reload([ "firewall" ], budget, dir), null);
		let from = budget.until - (start[0] * 1000 + start[1] / 1000000);
		t.assert_true(from >= 20000 && from < 20500, sprintf("the time ran out %d ms after the start", from));
		system("rm -rf " + DIR);
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
			t.assert_true(tx.default_watch(unbound([ UP ]), [ svc ], 0, 0) != null, svc);
		let conn = unbound([ UP ]);
		t.assert_equal(tx.default_watch(conn, [ "firewall", "network" ], 0, 0), null);
		t.assert_equal(length(conn._state.ubus_calls), 0);
	});

	t.it('blames the write only when unbound ran before it', () => {
		t.assert_equal(tx.default_watch(unbound([ DOWN ]), [ "unbound" ], 0, 0), null);
		t.assert_equal(tx.default_watch(unbound([ null ]), [ "unbound" ], 0, 0), null);
	});

	// A batch restores only some of its packages and reloads only their services.
	t.it('after a restore, watches only the daemons of the services that it reloaded', () => {
		t.assert_equal(tx.default_watch(unbound([ UP, DOWN ]), [ "unbound" ], 0, 0)([ "firewall" ]), null);
		t.assert_equal(tx.default_watch(unbound([ UP, DOWN ]), [ "unbound" ], 0, 0)([ "unbound" ]),
		               "unbound stopped after the reload, with exit code 1");
	});

	t.it('passes while unbound runs, a new pid included, and fails when it stops', () => {
		t.assert_equal(tx.default_watch(unbound([ UP, UP2 ]), [ "unbound" ], 0, 0)(), null);
		t.assert_equal(tx.default_watch(unbound([ UP, DOWN ]), [ "unbound" ], 0, 0)(),
		               "unbound stopped after the reload, with exit code 1");
		t.assert_equal(tx.default_watch(unbound([ UP, { running: false } ]), [ "unbound" ], 0, 0)(),
		               "unbound stopped after the reload");
	});

	// `restart` is a stop and then a start, and procd lists no instance in between.
	t.it('an instance that service list does not show is being restarted, not stopped', () => {
		t.assert_equal(tx.default_watch(unbound([ UP, null ]), [ "unbound" ], 0, 0)(), null);
		t.assert_equal(tx.default_watch(unbound([ UP, null, UP2 ]), [ "unbound" ], 2, 1)(), null);
		t.assert_equal(tx.default_watch(unbound([ UP, null, DOWN ]), [ "unbound" ], 2, 1)(),
		               "unbound stopped after the reload, with exit code 1");
	});

	t.it('polls until the end of the window, so a later stop counts', () => {
		let conn = unbound([ UP, UP2, UP2, DOWN ]);
		t.assert_equal(tx.default_watch(conn, [ "unbound-uci-ext" ], 2, 1)(),
		               "unbound stopped after the reload, with exit code 1");
		t.assert_equal(tx.default_watch(unbound([ UP, UP2, UP2, UP2, DOWN ]), [ "unbound" ], 2, 1)(), null);
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
		conn.set_ubus_response("service", "list", (args) => ({ unbound: { instances: { unbound: state }, triggers: [ DHCP_TRIGGER ] } }));
		return function(s) { state = (reloads++ == 0) ? after_write : after_restore; return null; };
	}

	t.it('reads the daemon before the reload, and the restore checks that it runs again', () => {
		for (let c in [ [ UP2, "reload_failed_restored" ], [ DOWN, "reload_failed_unrecovered" ] ]) {
			let conn = ubus.stub({ uci: { unbound_srv: { main: { '.type': 'unbound_srv', enabled: '0' } } } });
			let r = tx.transaction(conn, build_params({
				package: "unbound_srv", reload_services: [ "unbound-uci-ext" ],
				acquire: function() { return {}; }, release: function() {},
				reload: daemon(conn, DOWN, c[0]),
				watch: (cn, s) => tx.default_watch(cn, s, 0, 0),
			}));
			t.assert_equal(r.kind, c[1]);
		}
	});

	t.it('a write to unbound_srv or unbound_ext also takes the lock of the unbound package', () => {
		for (let c in [ [ "unbound_srv", [ "unbound-uci-ext" ], [ "unbound" ] ], [ "unbound", [ "unbound" ], [] ],
		                [ "firewall", [ "firewall" ], [] ], [ "dhcp", [ "dnsmasq", "odhcpd", "unbound" ], [ "unbound" ] ],
		                [ "system", [ "system", "dnsmasq", "unbound" ], [ "unbound" ] ] ]) {
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
				watch: (cn, s) => tx.default_watch(cn, s, 0, 0),
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

	// The lock of unbound was taken only when procd, asked before the locks, held a trigger for it.
	// So a write that skipped a stopped unbound, at boot or after a stop, ran beside a write to
	// unbound, whose restart then read the config from before the commit of the first.
	let not_installed = (svc) => (s) => (index(s, svc) >= 0) ? sprintf("init script /etc/init.d/%s not found", svc) : null;

	t.it('a dhcp or system write takes the lock of unbound whenever unbound is installed', () => {
		let write = (pkg, names, check) => {
			let also = null;
			let r = tx.transaction(running_now(ubus.stub(), names), build_params({
				package: pkg, reload_services: [], reload_if_running: [ "dnsmasq", "odhcpd", "unbound" ],
				check_services: check ?? noop_check,
				acquire: function(p, a) { also = a; return {}; }, release: function() {}, watch: () => null,
			}));
			return [ also, r.reload_services ];
		};
		for (let pkg in [ "dhcp", "system" ]) {
			t.assert_deep_equal(write(pkg, [ "dnsmasq", "odhcpd", "unbound" ]), [ [ "unbound" ], [ "dnsmasq", "odhcpd", "unbound" ] ], pkg);
			t.assert_deep_equal(write(pkg, [ "dnsmasq", "odhcpd" ]), [ [ "unbound" ], [ "dnsmasq", "odhcpd" ] ], pkg);
			t.assert_deep_equal(write(pkg, [ "dnsmasq", "odhcpd", "unbound" ], not_installed("unbound")),
			                    [ [], [ "dnsmasq", "odhcpd" ] ], pkg);
		}
	});

	t.it('a batch takes it too', () => {
		let prefix = "/tmp/uapi-test-shared-pkg.", global = "/tmp/uapi-test-shared-global.lock";
		let held = fs.open(prefix + "unbound.lock", "w+");
		held.lock("xn");
		let conn = ubus.stub({ uci: { system: { cfg01: { '.type': 'system', hostname: 'OpenWrt' } } } });
		let batch = (names, check) => {
			running_now(conn, names);
			return tx.multi_transaction(conn, {
				packages: [ "system" ], reload_services: { system: [ "system" ] },
				reload_if_running: { system: [ "dnsmasq", "odhcpd", "unbound" ] },
				lock_path: global, pkg_lock_prefix: prefix, check_services: check ?? noop_check, reload: noop_reload,
				watch: () => null,
				fn: function(c) { c.uci_set("system", "cfg01", "hostname", "gw"); return { ok: true }; },
			});
		};
		let running = batch([ "unbound" ]), stopped = batch([ "dnsmasq", "odhcpd" ]);
		let absent = batch([ "dnsmasq", "odhcpd" ], not_installed("unbound"));
		held.lock("u"); held.close();
		for (let f in [ global, ...fs.glob(prefix + "*") ]) fs.unlink(f);
		t.assert_deep_equal([ running.kind, running.package ], [ "locked", "unbound" ]);
		t.assert_deep_equal([ stopped.kind, stopped.package ], [ "locked", "unbound" ]);
		t.assert_deep_equal([ absent.ok, absent.reload_services ], [ true, [ "dnsmasq", "odhcpd", "system" ] ]);
	});

	t.it('asks procd only once it holds its locks, the lock of unbound included', () => {
		let prefix = "/tmp/uapi-test-order-pkg.", global = "/tmp/uapi-test-order-global.lock";
		let free = (name) => {
			let fd = fs.open(prefix + name + ".lock", "w+");
			let ok = fd.lock("xn") === true;
			fd.close();
			return ok;
		};
		let asked = [];
		let conn = ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', ignore: '0' } } } });
		conn.set_ubus_response("service", "list", (a) => { push(asked, [ a.name, free("dhcp"), free("unbound") ]); return {}; });
		let p = { check_services: noop_check, reload: noop_reload, watch: () => null };
		let fn = (c) => { c.uci_set("dhcp", "lan", "ignore", "1"); return { ok: true, body: {} }; };
		let single = tx.transaction(conn, build_params({ ...p, package: "dhcp", reload_services: [],
			reload_if_running: [ "dnsmasq", "unbound" ], fn, release: tx.default_release_pkg,
			acquire: (g, also) => tx.default_acquire_pkg(global, "dhcp", also, prefix) }));
		let batch = tx.multi_transaction(conn, { ...p, packages: [ "dhcp" ], reload_services: { dhcp: [] },
			reload_if_running: { dhcp: [ "dnsmasq", "unbound" ] }, lock_path: global, pkg_lock_prefix: prefix, fn });
		for (let f in [ global, ...fs.glob(prefix + "*") ]) fs.unlink(f);
		t.assert_deep_equal([ single.ok, batch.ok ], [ true, true ]);
		t.assert_deep_equal(asked, [ [ "dnsmasq", false, false ], [ "unbound", false, false ],
		                             [ "dnsmasq", false, false ], [ "unbound", false, false ] ]);
	});

	t.it('a dhcp write that reloads unbound restores the previous config when unbound stops', () => {
		let conn = ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', ignore: '0' } } } });
		let r = tx.transaction(conn, build_params({
			package: "dhcp", reload_services: [], reload_if_running: [ "unbound" ],
			acquire: function() { return {}; }, release: function() {},
			reload: daemon(conn, DOWN, UP2),
			watch: (cn, s) => tx.default_watch(cn, s, 0, 0),
			fn: function(c, pkg) { c.uci_set(pkg, "lan", "ignore", "1"); return { ok: true, body: {} }; },
		}));
		t.assert_deep_equal([ r.kind, r.reload_error ], [ "reload_failed_restored", "unbound stopped after the reload, with exit code 1" ]);
		t.assert_equal(conn._state.uci.dhcp.lan.ignore, "0");
	});
});

// dnsmasq.init writes one config per dnsmasq section and answers 0, and dnsmasq refuses a line such
// as `dhcp-option=lan,3,not-an-address` only when it reads that config.
t.describe('transaction, dnsmasq --test after the reload', () => {
	const conf = (name) => "/var/etc/dnsmasq.conf." + name;
	const REFUSED = "dnsmasq refuses its config main: bad IP address at line 33 of /var/etc/dnsmasq.conf.main";

	// The nth call of service list answers lists[n], each instance name mapped to whether it runs.
	function fake(lists) {
		let n = 0;
		let conn = ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', leasetime: '12h' } } } });
		conn.set_ubus_response("service", "list", function(args) {
			let out = {};
			for (let name, running in lists[min(n++, length(lists) - 1)])
				out[name] = { running, command: [ "/usr/sbin/dnsmasq", "-C", conf(name), "-k", "-x", "/var/run/" + name + ".pid" ] };
			return { [args.name]: { instances: out } };
		});
		return conn;
	}
	// --test refuses the config of each instance named in bad, a list per run when bad is a function.
	function tester(bad) {
		let ran = [];
		return { ran, run: function(argv) {
			push(ran, argv);
			let refused = filter((type(bad) == "function") ? bad() : bad, (name) => argv[3] == conf(name));
			return (length(refused) > 0)
				? { code: 1, output: sprintf("\ndnsmasq: bad IP address at line 33 of %s\n", conf(refused[0])) }
				: { code: 0, output: "dnsmasq: syntax check OK.\n" };
		} };
	}

	t.it('runs the command of each instance with --test, after a reload of dnsmasq only', () => {
		let tests = tester([]);
		t.assert_equal(tx.dnsmasq_check(fake([ { main: true } ]), [ "dnsmasq" ], tests.run)(), null);
		t.assert_deep_equal(tests.ran, [ [ "/usr/sbin/dnsmasq", "--test", "-C", conf("main"), "-k", "-x", "/var/run/main.pid" ] ]);
		let conn = fake([ { main: true } ]);
		t.assert_equal(tx.dnsmasq_check(conn, [ "firewall", "unbound" ], tests.run), null);
		t.assert_equal(length(conn._state.ubus_calls), 0);
	});

	t.it('tests nothing after a restore that did not reload dnsmasq', () => {
		let tests = tester([ "main" ]);
		t.assert_equal(tx.dnsmasq_check(fake([ { main: true } ]), [ "dnsmasq" ], tests.run)([ "firewall" ]), null);
		t.assert_equal(length(tests.ran), 0);
	});

	t.it('fails the reload with the first line of what dnsmasq refuses', () => {
		t.assert_equal(tx.dnsmasq_check(fake([ { main: true } ]), [ "dnsmasq" ], tester([ "main" ]).run)(), REFUSED);
	});

	// The SIGHUP race of a reload can leave an instance stopped for 5 s, and procd then starts it on
	// the config that the next write leaves.
	t.it('tests every instance, a new one and one that was not running before included', () => {
		let lists = [ { main: true, guest: false }, { main: true, guest: false, added: true } ];
		let tests = tester([]);
		t.assert_equal(tx.dnsmasq_check(fake(lists), [ "dnsmasq" ], tests.run)(), null);
		t.assert_deep_equal(map(tests.ran, (a) => a[3]), [ conf("main"), conf("guest"), conf("added") ]);
		for (let name in [ "guest", "added" ])
			t.assert_equal(tx.dnsmasq_check(fake(lists), [ "dnsmasq" ], tester([ name ]).run)(),
			               sprintf("dnsmasq refuses its config %s: bad IP address at line 33 of %s", name, conf(name)));
	});

	t.it('tests an instance that service list no longer shows with its command from before', () => {
		let tests = tester([ "main" ]);
		t.assert_equal(tx.dnsmasq_check(fake([ { main: true }, {} ]), [ "dnsmasq" ], tests.run)(), REFUSED);
		t.assert_equal(length(tests.ran), 1);
	});

	// A conf-file on a mount that hangs held the locks until uhttpd killed the request at its 60 s
	// script timeout, so neither a restore nor an answer came. A parse that is only slow judges
	// nothing either, so the write keeps its commit and says that the check did not finish.
	t.it('kills a --test that does not finish in time, which refuses nothing', () => {
		let dir = "/tmp/uapi-test-dnsmasq-hang";
		system(sprintf("rm -rf %s; mkdir -p %s", dir, dir));
		fs.writefile(dir + "/dnsmasq", "#!/bin/sh\necho 'dnsmasq: reading'; exec sleep 5\n");
		fs.chmod(dir + "/dnsmasq", 0755);
		let start = clock(true);
		let r = tx.run_test([ dir + "/dnsmasq", "--test" ], 300);
		let end = clock(true);
		system("rm -rf " + dir);
		let ms = (end[0] - start[0]) * 1000 + (end[1] - start[1]) / 1000000;
		t.assert_deep_equal([ r.code, r.output ], [ -9, "dnsmasq: reading\n" ]);
		t.assert_true(ms < 2000, sprintf("the --test ran for %d ms", ms));
		t.assert_deep_equal(tx.dnsmasq_check(fake([ { main: true } ]), [ "dnsmasq" ], (argv) => ({ code: -9, output: "" }))(),
		                    { unverified: "dnsmasq --test did not finish on its config main: it was killed, by the time bound "
		                                  + "or another SIGKILL, so whether dnsmasq takes the config is unknown" });
		let both = fake([ { main: true, guest: true } ]);
		t.assert_equal(tx.dnsmasq_check(both, [ "dnsmasq" ], (argv) => (argv[3] == conf("main")) ? { code: -9, output: "" }
		                                                       : { code: 1, output: "dnsmasq: bad option at line 2 of x" })(),
		               "dnsmasq refuses its config guest: bad option at line 2 of x");
	});

	t.it('a write whose --test does not finish keeps its commit and answers unverified', () => {
		let dir = "/tmp/uapi-test-dnsmasq-slow";
		system(sprintf("rm -rf %s; mkdir -p %s", dir, dir));
		fs.writefile(dir + "/dnsmasq", "#!/bin/sh\nexec sleep 5\n");
		fs.chmod(dir + "/dnsmasq", 0755);
		let write = (batch) => {
			let conn = ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', leasetime: '12h' } } } });
			conn.set_ubus_response("service", "list", (a) => ({ dnsmasq: { instances: { main: { running: true,
				command: [ dir + "/dnsmasq", "-C", conf("main") ] } } } }));
			let p = { check_services: noop_check, reload: noop_reload, watch: (cn, s, pkgs) => tx.check_daemons(cn, s, pkgs, 300) };
			let start = clock(true);
			let r = batch
				? tx.multi_transaction(conn, { ...p, packages: [ "dhcp" ], reload_services: { dhcp: [ "dnsmasq" ] },
				                               lock_path: "/tmp/uapi-test-slow-global.lock", pkg_lock_prefix: "/tmp/uapi-test-slow-pkg.",
				                               fn: (c) => { c.uci_set("dhcp", "lan", "leasetime", "6h"); return { ok: true, body: {} }; } })
				: tx.transaction(conn, build_params({ ...p, package: "dhcp", reload_services: [ "dnsmasq" ],
				                                      acquire: function() { return {}; }, release: function() {},
				                                      fn: function(c, pkg) { c.uci_set(pkg, "lan", "leasetime", "6h"); return { ok: true, body: {} }; } }));
			let end = clock(true);
			for (let f in [ "/tmp/uapi-test-slow-global.lock", ...fs.glob("/tmp/uapi-test-slow-pkg.*") ]) fs.unlink(f);
			return [ r.ok, r.reload_status, match(r.unverified ?? "", /^dnsmasq --test did not finish on its config main/) != null,
			         conn._state.uci.dhcp.lan.leasetime, (end[0] - start[0]) * 1000 + (end[1] - start[1]) / 1000000 < 2500 ];
		};
		let single = write(false), batch = write(true);
		system("rm -rf " + dir);
		t.assert_deep_equal(single, [ true, "unverified", true, "6h", true ]);
		t.assert_deep_equal(batch, [ true, "unverified", true, "6h", true ]);
	});

	// A failed fork raised from system() after the commit, so the request answered 500 internal_error
	// with uci and dnsmasq on the new config and no restore.
	t.it('a --test that cannot run fails the reload and restores, without a throw', () => {
		let real = { system: global.system, mkstemp: fs.mkstemp };
		let write = (batch) => {
			let conn = fake([ { main: true } ]);
			let r = null;
			try {
				r = batch
					? tx.multi_transaction(conn, { packages: [ "dhcp" ], reload_services: { dhcp: [ "dnsmasq" ] },
					                               check_services: noop_check, reload: noop_reload,
					                               lock_path: "/tmp/uapi-test-fork-global.lock", pkg_lock_prefix: "/tmp/uapi-test-fork-pkg.",
					                               fn: (c) => { c.uci_set("dhcp", "lan", "leasetime", "6h"); return { ok: true, body: {} }; } })
					: tx.transaction(conn, build_params({ package: "dhcp", reload_services: [ "dnsmasq" ],
					                                      acquire: function() { return {}; }, release: function() {},
					                                      fn: function(c, pkg) { c.uci_set(pkg, "lan", "leasetime", "6h"); return { ok: true, body: {} }; } }));
			} catch (e) { r = { kind: "threw: " + e.message }; }
			for (let f in [ "/tmp/uapi-test-fork-global.lock", ...fs.glob("/tmp/uapi-test-fork-pkg.*") ]) fs.unlink(f);
			return [ r.kind, r.reload_error, conn._state.uci.dhcp.lan.leasetime ];
		};
		global.system = function() { die("fork(): Resource temporarily unavailable"); };
		let forked = [ write(false), write(true) ];
		global.system = real.system;
		fs.mkstemp = () => null;
		let no_file = write(false);
		fs.mkstemp = real.mkstemp;
		for (let r in forked)
			t.assert_deep_equal(r, [ "reload_failed_unrecovered",
			                         "dnsmasq --test could not run on its config main: fork(): Resource temporarily unavailable", "12h" ]);
		t.assert_deep_equal(no_file, [ "reload_failed_unrecovered",
		                               "dnsmasq --test could not run on its config main: cannot create a file for its output", "12h" ]);
	});

	// A system write reloads dnsmasq for the hostname and NTP, and a config of dnsmasq that was
	// refused before, or that parses slowly, must not fail or undo it.
	t.it('runs for a write that commits dhcp, and not for a system write', () => {
		let checked = (pkg, batch_pkgs) => {
			let conn = fake([ { main: true } ]);
			let p = { check_services: noop_check, reload: noop_reload };
			let ran = [];
			let saved = global.system;
			global.system = function() { push(ran, true); return 1; };
			let r = batch_pkgs
				? tx.multi_transaction(conn, { ...p, packages: batch_pkgs,
				                               reload_services: { dhcp: [ "dnsmasq" ], system: [ "system", "dnsmasq" ] },
				                               lock_path: "/tmp/uapi-test-d1-global.lock", pkg_lock_prefix: "/tmp/uapi-test-d1-pkg.",
				                               fn: () => ({ ok: true, body: {} }) })
				: tx.transaction(conn, build_params({ ...p, package: pkg, reload_services: [ "system", "dnsmasq" ],
				                                      acquire: function() { return {}; }, release: function() {},
				                                      fn: () => ({ ok: true, body: {} }) }));
			global.system = saved;
			for (let f in [ "/tmp/uapi-test-d1-global.lock", ...fs.glob("/tmp/uapi-test-d1-pkg.*") ]) fs.unlink(f);
			return [ r.ok ? true : r.kind, length(ran) > 0 ];
		};
		t.assert_deep_equal(checked("system"), [ true, false ]);
		t.assert_deep_equal(checked("dhcp"), [ "reload_failed_unrecovered", true ]);
		t.assert_deep_equal(checked(null, [ "system" ]), [ true, false ]);
		t.assert_deep_equal(checked(null, [ "dhcp", "system" ]), [ "reload_failed_unrecovered", true ]);
	});

	// procd starts dnsmasq with stdin on /dev/null, so a conf-file of - reads an empty config there.
	t.it('runs --test with stdin on /dev/null', () => {
		let dir = "/tmp/uapi-test-dnsmasq-stdin";
		system(sprintf("rm -rf %s; mkdir -p %s", dir, dir));
		fs.writefile(dir + "/dnsmasq", "#!/bin/sh\ncat >/dev/null\n");
		fs.chmod(dir + "/dnsmasq", 0755);
		fs.writefile(dir + "/run.uc", sprintf("require('fs').writefile(%J, '' + require('transaction').run_test([ %J ], 2000).code);\n",
		                                      dir + "/code", dir + "/dnsmasq"));
		let stdin = fs.popen("ucode -L src/lib " + dir + "/run.uc", "w");
		for (let i = 0; i < 40 && !fs.readfile(dir + "/code"); i++) sleep(100);
		let code = fs.readfile(dir + "/code");
		stdin.close();
		system("rm -rf " + dir);
		t.assert_equal(code, "0");
	});

	t.it('skips an instance without a dnsmasq command, so the check cannot throw after the commit', () => {
		let conn = ubus.stub();
		conn.set_ubus_response("service", "list", () => ({ dnsmasq: { instances: {
			bare: { running: true }, odd: { running: true, command: "/usr/sbin/dnsmasq" },
			other: { running: true, command: [ "/bin/sh", "-c", "exit 1" ] },
		} } }));
		let tests = tester([]);
		t.assert_equal(tx.dnsmasq_check(conn, [ "dnsmasq" ], tests.run)(), null);
		t.assert_equal(length(tests.ran), 0);
	});

	function write(bad_after_restore) {
		let runs = 0;
		let conn = fake([ { main: true } ]);
		let tests = tester(() => (runs++ == 0) ? [ "main" ] : bad_after_restore);
		let r = tx.transaction(conn, build_params({
			package: "dhcp", reload_services: [ "dnsmasq" ],
			acquire: function() { return {}; }, release: function() {},
			watch: (cn, s) => tx.dnsmasq_check(cn, s, tests.run),
			fn: function(c, pkg) { c.uci_set(pkg, "lan", "leasetime", "1h"); return { ok: true, body: {} }; },
		}));
		return { r, leasetime: conn._state.uci.dhcp.lan.leasetime };
	}

	t.it('a refused config restores the previous one, and the restore runs the same check', () => {
		let w = write([]);
		t.assert_equal(w.r.kind, "reload_failed_restored");
		t.assert_equal(w.r.reload_error, REFUSED);
		t.assert_equal(w.leasetime, "12h");
		w = write([ "main" ]);
		t.assert_equal(w.r.kind, "reload_failed_unrecovered");
		t.assert_equal(w.r.restore_error, "reload during restore failed: " + REFUSED);
	});

	// The tests above pass their own watch, so this one runs the default checks and the real popen.
	t.it('a write that reloads dnsmasq runs --test by default, and the restore runs it again', () => {
		let dir = "/tmp/uapi-test-dnsmasq-check";
		system(sprintf("rm -rf %s; mkdir -p %s/refuse %s/accept", dir, dir, dir));
		fs.writefile(dir + "/refuse/dnsmasq", "#!/bin/sh\necho; echo 'dnsmasq: bad IP address at line 1 of x'; exit 1\n");
		fs.writefile(dir + "/accept/dnsmasq", "#!/bin/sh\nexit 0\n");
		for (let d in [ "refuse", "accept" ]) fs.chmod(dir + "/" + d + "/dnsmasq", 0755);
		let n = 0;
		let conn = ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', leasetime: '12h' } } } });
		conn.set_ubus_response("service", "list", (args) => ({ dnsmasq: { instances: { main: { running: true,
			command: [ dir + ((n++ < 2) ? "/refuse" : "/accept") + "/dnsmasq", "-C", conf("main") ] } } } }));
		let r = tx.transaction(conn, build_params({
			package: "dhcp", reload_services: [ "dnsmasq" ],
			acquire: function() { return {}; }, release: function() {},
			fn: function(c, pkg) { c.uci_set(pkg, "lan", "leasetime", "1h"); return { ok: true, body: {} }; },
		}));
		system("rm -rf " + dir);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(r.reload_error, "dnsmasq refuses its config main: bad IP address at line 1 of x");
		t.assert_equal(conn._state.uci.dhcp.lan.leasetime, "12h");
		t.assert_equal(n, 3);
	});
});

// odhcpd reads dhcp too, and an image can lack it or the operator can stop it. A write that
// requires it answered 503 on such a router, one that left it out answered 200 while odhcpd kept
// its old config, and the reload of a stopped dnsmasq starts it.
t.describe('transaction, a service to reload only while procd runs it', () => {
	let missing = (svc) => (s) => (index(s, svc) >= 0) ? sprintf("init script /etc/init.d/%s not found", svc) : null;
	function dhcp_write(check_services, names, reload) {
		let calls = [];
		let conn = running_now(ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', ra: 'disabled' } } } }), names);
		let r = tx.transaction(conn, build_params({
			package: "dhcp", reload_services: [ "dnsmasq" ], reload_if_running: [ "odhcpd" ],
			acquire: function() { return {}; }, release: function() {}, check_services,
			reload: (s) => { push(calls, s); return reload ? reload(s) : null; },
			fn: function(c, pkg) { c.uci_set(pkg, "lan", "ra", "server"); return { ok: true, body: {} }; },
		}));
		return { r, calls };
	}

	t.it('reloads it after the required services while procd runs it', () => {
		let w = dhcp_write(noop_check, [ "dnsmasq", "odhcpd" ]);
		t.assert_true(w.r.ok);
		t.assert_deep_equal(w.calls, [ [ "dnsmasq", "odhcpd" ] ]);
		t.assert_deep_equal(w.r.reload_services, [ "dnsmasq", "odhcpd" ]);
	});

	t.it('skips one that is installed and that procd does not list, and does not name it', () => {
		let w = dhcp_write(noop_check, [ "dnsmasq" ]);
		t.assert_true(w.r.ok);
		t.assert_deep_equal(w.calls, [ [ "dnsmasq" ] ]);
		t.assert_deep_equal(w.r.reload_services, [ "dnsmasq" ]);
	});

	// A LuCI save fires each config.change trigger that procd holds, whatever the instances show, and
	// procd answers the triggers only to a verbose call. At boot unbound.init registers only one on
	// interface events, which starts unbound 3 s after the last of them, and the reload started it
	// early. unbound has no trigger on system, which reaches it through ucitrack's `affects`.
	t.it('reloads one that procd lists with a config trigger, as a LuCI save does', () => {
		let prefix = "/tmp/uapi-test-trigger-pkg.", global = "/tmp/uapi-test-trigger-global.lock";
		let write = (answer, pkg, batch) => {
			let also = null;
			let conn = ubus.stub({ uci: { dhcp: { lan: { '.type': 'dhcp', ra: 'disabled' } },
			                             system: { cfg01: { '.type': 'system', hostname: 'OpenWrt' } } } });
			conn.set_ubus_response("service", "list", answer);
			let fn = (c) => {
				if (pkg == "system") c.uci_set(pkg, "cfg01", "hostname", "gw");
				else c.uci_set(pkg, "lan", "ra", "server");
				return { ok: true, body: {} };
			};
			let p = { check_services: noop_check, reload: noop_reload, watch: () => null };
			let r = batch
				? tx.multi_transaction(conn, { ...p, packages: [ pkg ], reload_services: { [pkg]: [] },
				                               reload_if_running: { [pkg]: [ "unbound" ] },
				                               lock_path: global, pkg_lock_prefix: prefix, fn })
				: tx.transaction(conn, build_params({ ...p, package: pkg, reload_services: [],
				                                      reload_if_running: [ "unbound" ], fn,
				                                      acquire: function(g, a) { also = a; return {}; },
				                                      release: function() {} }));
			for (let f in [ global, ...fs.glob(prefix + "*") ]) fs.unlink(f);
			return batch ? r.reload_services : [ r.reload_services, also ];
		};
		let listed = (instances, triggers) => (a) => {
			let svc = (instances != null) ? { instances } : {};
			if (a.verbose) svc.triggers = triggers;
			return { [a.name]: svc };
		};
		let on = (pkg) => [ "config.change", [ "if", [ "eq", "package", pkg ],
		                                       [ "run_script", "/etc/init.d/unbound", "reload" ] ], 1000 ];
		let ifup = [ "interface.*.up", [ [ "run_script", "/etc/init.d/unbound", "restart" ] ], 3000 ];
		let config = [ on("unbound"), on("dhcp") ];
		const RESPAWN = { threshold: 3600, timeout: 5, retry: 5 };
		let up = { unbound: { running: true, pid: 10, respawn: RESPAWN } };
		let respawning = { unbound: { running: false, exit_code: 1, respawn: RESPAWN } };
		let exhausted = { unbound: { running: false, exit_code: 1 } };
		let reloaded = [ [ "unbound" ], [ "unbound" ] ], skipped = [ [], [ "unbound" ] ];
		let cases = [
			[ "running", listed(up, config), "dhcp", false, reloaded ],
			[ "respawning", listed(respawning, config), "dhcp", false, reloaded ],
			[ "crash loop exhausted", listed(exhausted, config), "dhcp", false, reloaded ],
			[ "no instance, as dnsmasq with every section disabled", listed(null, [ on("dhcp"), on("system") ]), "dhcp", false, reloaded ],
			[ "boot", listed(null, [ ifup ]), "dhcp", false, skipped ],
			[ "stopped", {}, "dhcp", false, skipped ],
			[ "system write", listed(up, config), "system", false, reloaded ],
			[ "only a trigger on a package other than the written one and dhcp", listed(up, [ on("unbound") ]), "dhcp", false, reloaded ],
			[ "batch, crash loop exhausted", listed(exhausted, config), "dhcp", true, [ "unbound" ] ],
			[ "batch, boot", listed(null, [ ifup ]), "dhcp", true, [] ],
		];
		t.assert_deep_equal(map(cases, (c) => [ c[0], write(c[1], c[2], c[3]) ]), map(cases, (c) => [ c[0], c[4] ]));
	});

	// A ubus call that fails or times out tells nothing about the daemon, and skipping it answered
	// 2xx with no_reload while the daemon kept its old config.
	t.it('reloads one whose service list call fails', () => {
		let failing = ubus.stub({ uci: { dhcp: {} } });
		failing.set_ubus_response("service", "list", { _error: "ubus: Request timed out" });
		let r = tx.transaction(failing, build_params({
			package: "dhcp", reload_services: [], reload_if_running: [ "odhcpd" ],
			acquire: function() { return {}; }, release: function() {},
		}));
		t.assert_deep_equal([ r.ok, r.reload_services ], [ true, [ "odhcpd" ] ]);
	});

	t.it('skips one whose init script is missing, and the write goes through', () => {
		let w = dhcp_write(missing("odhcpd"), [ "dnsmasq", "odhcpd" ]);
		t.assert_true(w.r.ok);
		t.assert_deep_equal(w.calls, [ [ "dnsmasq" ] ]);
		t.assert_deep_equal(w.r.reload_services, [ "dnsmasq" ]);
		let real = tx.transaction(running_now(ubus.stub(), [ "this-daemon-definitely-not-installed-anywhere" ]), build_params({
			reload_services: [], reload_if_running: [ "this-daemon-definitely-not-installed-anywhere" ],
			acquire: function() { return {}; }, release: function() {}, check_services: null,
		}));
		t.assert_deep_equal([ real.ok, real.reload_services ], [ true, [] ]);
	});

	t.it('a missing required service still answers init_script_missing', () => {
		let w = dhcp_write(missing("dnsmasq"), [ "dnsmasq", "odhcpd" ]);
		t.assert_equal(w.r.kind, "init_script_missing");
		t.assert_deep_equal(w.calls, []);
	});

	t.it('the restore reloads it too', () => {
		let w = dhcp_write(noop_check, [ "dnsmasq", "odhcpd" ], reload_flaky(1));
		t.assert_equal(w.r.kind, "reload_failed_restored");
		t.assert_deep_equal(w.calls, [ [ "dnsmasq", "odhcpd" ], [ "dnsmasq", "odhcpd" ] ]);
	});

	t.it('a batch reloads the running ones of the packages that it committed, sorted', () => {
		let prefix = "/tmp/uapi-test-optional-pkg.", global = "/tmp/uapi-test-optional-global.lock";
		let batch = (names, committed) => {
			let calls = [];
			let conn = running_now(ubus.stub({ uci: { dhcp: {}, fw: {} } }), names);
			conn.uci_commit = (pkg) => index(committed, pkg) >= 0;
			let r = tx.multi_transaction(conn, {
				packages: [ "dhcp", "fw" ],
				reload_services: { dhcp: [ "dnsmasq" ], fw: [ "firewall" ] },
				reload_if_running: { dhcp: [ "odhcpd" ] },
				lock_path: global, pkg_lock_prefix: prefix, check_services: noop_check,
				reload: (s) => { push(calls, s); return null; },
				fn: (c) => ({ ok: true, body: {} }),
			});
			for (let f in [ global, ...fs.glob(prefix + "*") ]) fs.unlink(f);
			return [ r.ok, calls ];
		};
		t.assert_deep_equal(batch([ "odhcpd" ], [ "dhcp", "fw" ]), [ true, [ [ "dnsmasq", "firewall", "odhcpd" ] ] ]);
		t.assert_deep_equal(batch([], [ "dhcp", "fw" ]), [ true, [ [ "dnsmasq", "firewall" ] ] ]);
		t.assert_deep_equal(batch([ "odhcpd" ], [ "fw" ]), [ true, [ [ "firewall" ] ] ]);
	});

	// A dhcp/odhcpd write reloads dnsmasq only while procd runs it, and the dnsmasq --test check
	// decides from the services that it is handed whether to run.
	t.it('the check after the reload sees the services that ran, as X-Reload-Services does', () => {
		let odhcpd_write = (names, code, batch) => {
			let tested = [];
			let conn = ubus.stub({ uci: { dhcp: { odhcpd: { '.type': 'odhcpd', maindhcp: '0' } } } });
			conn.set_ubus_response("service", "list", (args) => (index(names, args.name) < 0) ? {} : { [args.name]: { instances: {
				main: { running: true, command: [ "/usr/sbin/dnsmasq", "-C", "/var/etc/dnsmasq.conf.main" ] } }, triggers: [ DHCP_TRIGGER ] } });
			let p = {
				acquire: function() { return {}; }, release: function() {}, check_services: noop_check,
				reload: noop_reload,
				watch: (cn, s) => tx.dnsmasq_check(cn, s, (argv) => {
					push(tested, argv[1]);
					return { code, output: "dnsmasq: bad option at line 1 of /var/etc/dnsmasq.conf.main" };
				}),
			};
			let write = function(c, pkg) { c.uci_set(pkg, "odhcpd", "maindhcp", "1"); return { ok: true, body: {} }; };
			let r = batch
				? tx.multi_transaction(conn, { ...p, packages: [ "dhcp" ], reload_services: { dhcp: [ "odhcpd" ] },
				                               reload_if_running: { dhcp: [ "dnsmasq" ] },
				                               lock_path: "/tmp/uapi-test-check-global.lock",
				                               pkg_lock_prefix: "/tmp/uapi-test-check-pkg.", fn: (c) => write(c, "dhcp") })
				: tx.transaction(conn, build_params({ ...p, package: "dhcp", reload_services: [ "odhcpd" ],
				                                      reload_if_running: [ "dnsmasq" ], fn: write }));
			for (let f in [ "/tmp/uapi-test-check-global.lock", ...fs.glob("/tmp/uapi-test-check-pkg.*") ]) fs.unlink(f);
			return [ r.kind ?? r.reload_services, tested ];
		};
		for (let batch in [ false, true ]) {
			t.assert_deep_equal(odhcpd_write([ "odhcpd", "dnsmasq" ], 0, batch),
			                    [ batch ? [ "dnsmasq", "odhcpd" ] : [ "odhcpd", "dnsmasq" ], [ "--test" ] ]);
			t.assert_deep_equal(odhcpd_write([ "odhcpd", "dnsmasq" ], 1, batch), [ "reload_failed_unrecovered", [ "--test", "--test" ] ]);
			t.assert_deep_equal(odhcpd_write([ "odhcpd" ], 1, batch), [ [ "odhcpd" ], [] ]);
		}
	});

	t.it('with the default checks, a dhcp/odhcpd write runs --test on the dnsmasq that it reloaded', () => {
		let dir = "/tmp/uapi-test-odhcpd-check";
		system(sprintf("rm -rf %s; mkdir -p %s", dir, dir));
		fs.writefile(dir + "/dnsmasq", "#!/bin/sh\necho 'dnsmasq: bad option at line 1 of x'; exit 1\n");
		fs.chmod(dir + "/dnsmasq", 0755);
		let odhcpd_write = (names) => {
			let conn = ubus.stub({ uci: { dhcp: { odhcpd: { '.type': 'odhcpd', maindhcp: '0' } } } });
			conn.set_ubus_response("service", "list", (a) => (index(names, a.name) < 0) ? {}
				: { [a.name]: { instances: { main: { running: true, command: [ dir + "/" + a.name, "-C", "x" ] } }, triggers: [ DHCP_TRIGGER ] } });
			return tx.transaction(conn, build_params({
				package: "dhcp", reload_services: [ "odhcpd" ], reload_if_running: [ "dnsmasq" ],
				acquire: function() { return {}; }, release: function() {},
				fn: function(c, pkg) { c.uci_set(pkg, "odhcpd", "maindhcp", "1"); return { ok: true, body: {} }; },
			}));
		};
		let refused = odhcpd_write([ "odhcpd", "dnsmasq" ]), skipped = odhcpd_write([ "odhcpd" ]);
		system("rm -rf " + dir);
		t.assert_deep_equal([ refused.kind, refused.reload_error ],
		                    [ "reload_failed_unrecovered", "dnsmasq refuses its config main: bad option at line 1 of x" ]);
		t.assert_deep_equal([ skipped.ok, skipped.reload_services ], [ true, [ "odhcpd" ] ]);
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
