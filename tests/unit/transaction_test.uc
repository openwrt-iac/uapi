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

function build_params(overrides) {
	let p = {
		package: "fw",
		reload_services: ["firewall"],
		fn: function(conn, pkg) {
			conn.uci_set(pkg, "r1", "target", "ACCEPT");
			return { ok: true, body: { id: "r1", target: "ACCEPT" } };
		},
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
		t.assert_equal(locks.acquired, 0);
		t.assert_equal(locks.released, 0);
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
			ubus: { 'firewall reload': null },
		});
		let r = tx.transaction(conn, build_params({
			acquire: locks.acquire, release: locks.release,
		}));
		t.assert_true(r.ok);
		t.assert_deep_equal(r.body, { id: "r1", target: "ACCEPT" });
		t.assert_equal(conn._state.uci.fw.r1.target, "ACCEPT");
		t.assert_deep_equal(conn._state.ubus_calls, [["firewall", "reload", {}]]);
		t.assert_equal(locks.acquired, 1);
		t.assert_equal(locks.released, 1);
	});

	t.it('records commit in the uci op log', () => {
		let conn = ubus.stub({ ubus: { 'firewall reload': null } });
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

function flaky_reload(initial_calls_failing) {
	let n = 0;
	return function() {
		n++;
		if (n <= initial_calls_failing) die("netifd: bad");
		return null;
	};
}

t.describe('transaction, reload failure with successful restore', () => {
	t.it('returns reload_failed_restored when the re-reload succeeds', () => {
		let locks = harness_locks(true);
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
			ubus: { 'firewall reload': flaky_reload(1) },
		});
		let r = tx.transaction(conn, build_params({
			acquire: locks.acquire, release: locks.release,
		}));
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "reload_failed_restored");
		t.assert_equal(r.reload_error, "netifd: bad");
		t.assert_equal(locks.released, 1);
	});

	t.it('restores the snapshot before returning', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
			ubus: { 'firewall reload': flaky_reload(1) },
		});
		tx.transaction(conn, build_params({
			acquire: function() { return {}; },
			release: function() {},
		}));
		t.assert_equal(conn._state.uci.fw.r1.target, "ACCEPT");
	});
});

t.describe('transaction, reload failure with restore failure', () => {
	t.it('returns reload_failed_unrecovered when the re-reload also fails', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
			ubus: { 'firewall reload': { _error: "netifd: bad" } },
		});
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; },
			release: function() {},
		}));
		t.assert_equal(r.kind, "reload_failed_unrecovered");
		t.assert_equal(r.reload_error, "netifd: bad");
		t.assert_true(match(r.restore_error, /netifd: bad/) != null);
	});

	t.it('returns reload_failed_unrecovered when uci_import throws', () => {
		let conn = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } },
			ubus: { 'firewall reload': { _error: "netifd: bad" } },
		});
		conn.uci_import = function(pkg, snap) { die("restore EIO"); };
		let r = tx.transaction(conn, build_params({
			acquire: function() { return {}; },
			release: function() {},
		}));
		t.assert_equal(r.kind, "reload_failed_unrecovered");
		t.assert_equal(r.reload_error, "netifd: bad");
		t.assert_equal(r.restore_error, "restore EIO");
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
