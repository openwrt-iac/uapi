let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let fx = require('resource_fixtures');
let ph = require('property_harness');

// A write that fails leaves uci exactly as it found it.
//
// This is the first architectural principle stated as a test: "no partial-failure states,
// no config drift". It was asserted in ten documentation files and covered by one unit
// test on the transaction module, never per resource, which is where it can actually go
// wrong: the transaction restores a snapshot, but whether a given resource's write is
// fully inside that snapshot depends on the resource.
//
// The failure is injected at reload, the one point where uci has already been committed
// and the daemon then refuses. That is the case the restore path exists for, and the only
// one where a partial state can survive a request.
//
// What this does not cover: a crash between commit and reload, since nothing in-process
// can restore after that. `docs/architecture.md` says so, and it is the reason
// commit-confirmed apply was ever designed.

// Only the first reload fails. The restore path reloads too, so a stub that fails every
// call produces reload_failed_unrecovered and tests the wrong branch: the case worth
// covering is a daemon that refuses the new config and accepts the restored one.
function failing_tx() {
	let calls = 0;
	return {
		acquire: function() { return {}; }, release: function() {},
		reload: function() {
			calls++;
			return (calls == 1) ? "probe: the daemon refused the new config" : null;
		},
		check_services: function() { return null; },
		wg_apply: function() { return null; }, wg_reconcile: function() { return null; },
	};
}

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

function seeded(c) {
	let uci = fx.world();
	if (uci[c.pkg] == null) uci[c.pkg] = {};
	uci[c.pkg][c.id] = { '.anonymous': false, ...c.section };
	return ubus.stub({ uci: uci });
}

function snapshot(conn) { return sprintf("%J", conn._state.uci); }

t.describe('property: a failed write leaves uci untouched', () => {
	for (let c in fx.CASES) {
		t.it(sprintf("%s/%s", c.file, c.id), () => {
			let mod = loadfile('src/resources/' + c.file)();
			let h = c.singleton ? handler.make_singleton(mod, { tx: failing_tx() })
			                    : handler.make(mod, { tx: failing_tx() });
			let conn = seeded(c);

			let read = c.singleton ? h.get(conn, ctx()) : h.get_one(conn, ctx(), c.id);
			if (read.status != 200) {
				t.assert_equal(sprintf("GET failed, so the seed is wrong: %J", read.body), "GET 200");
				return;
			}
			let body = { ...read.body };
			delete body.runtime;

			let before = snapshot(conn);
			let w = c.singleton ? h.patch(conn, ctx(), body)
			                   : h.replace(conn, ctx(), c.id, body);

			// The write has to actually fail, or this proves nothing: a 200 here means the
			// injected reload error never reached the transaction and the comparison below
			// would pass for the wrong reason.
			if (w.status != 500) {
				t.assert_equal(sprintf("expected the injected reload failure to surface, got %d %J",
				                       w.status, w.body), "500");
				return;
			}
			t.assert_equal(w.body.code, "reload_failed_restored");

			let after = snapshot(conn);
			if (!ph.json_eq(json(before), json(after)))
				t.assert_equal(sprintf("uci changed across a failed write:\n  before %s\n  after  %s",
				                       before, after), "unchanged");
		});
	}
});
