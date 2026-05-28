let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let rules_mod = loadfile('src/resources/firewall.rules.uc')();
let rules = handler.make(rules_mod, {
	tx: {
		acquire: function() { return {}; },
		release: function() {},
	},
});

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

function with_zones() {
	return ubus.stub({
		uci: {
			firewall: {
				z_lan: { '.type': 'zone', name: 'lan' },
				z_wan: { '.type': 'zone', name: 'wan' },
			}
		},
		ubus: { 'firewall reload': null },
	});
}

t.describe('handler.list', () => {
	t.it('returns 200 with an empty list when no sections exist', () => {
		let c = with_zones();
		let r = rules.list(c, ctx(), {});
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body, []);
	});

	t.it('returns rules in fromUci shape', () => {
		let c = with_zones();
		c._state.uci.firewall.r1 = {
			'.type': 'rule', '.anonymous': false,
			target: 'ACCEPT', src: 'wan',
		};
		let r = rules.list(c, ctx(), {});
		t.assert_equal(length(r.body), 1);
		t.assert_equal(r.body[0].target, 'ACCEPT');
	});

	t.it('filters by managed=true', () => {
		let c = with_zones();
		c._state.uci.firewall.cfg9 = { '.type': 'rule', '.anonymous': true, target: 'DROP', src: 'wan' };
		c._state.uci.firewall.r1   = { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan' };
		let r = rules.list(c, ctx(), { managed: "true" });
		t.assert_equal(length(r.body), 1);
		t.assert_true(r.body[0].managed);
	});

	t.it('filters by managed=false', () => {
		let c = with_zones();
		c._state.uci.firewall.cfg9 = { '.type': 'rule', '.anonymous': true, target: 'DROP', src: 'wan' };
		c._state.uci.firewall.r1   = { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan' };
		let r = rules.list(c, ctx(), { managed: "false" });
		t.assert_equal(length(r.body), 1);
		t.assert_false(r.body[0].managed);
	});
});

t.describe('handler.get_one', () => {
	t.it('returns 404 when id is unknown', () => {
		let c = with_zones();
		let r = rules.get_one(c, ctx(), 'r_missing');
		t.assert_equal(r.status, 404);
		t.assert_equal(r.body.code, 'not_found');
	});

	t.it('returns 404 when section is wrong type', () => {
		let c = with_zones();
		let r = rules.get_one(c, ctx(), 'z_lan');
		t.assert_equal(r.status, 404);
	});

	t.it('returns 200 with the rule body', () => {
		let c = with_zones();
		c._state.uci.firewall.r_x = {
			'.type': 'rule', '.anonymous': false,
			target: 'REJECT', src: 'lan',
		};
		let r = rules.get_one(c, ctx(), 'r_x');
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'r_x');
		t.assert_equal(r.body.target, 'REJECT');
	});
});

t.describe('handler.create', () => {
	t.it('returns 422 with field errors for an invalid body', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), { target: "BOGUS", match: {} });
		t.assert_equal(r.status, 422);
		t.assert_true(length(r.body.errors) >= 2);
	});

	t.it('creates a named rule and returns the created body', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			target: 'ACCEPT',
			match: { src_zone: 'wan', dest_port: ['22'], proto: ['tcp'] },
		});
		t.assert_equal(r.status, 200);
		t.assert_true(r.body.managed);
		t.assert_match(r.body.id, /^r_[0-9a-z]{26}$/);
		t.assert_equal(r.body.target, 'ACCEPT');
		t.assert_deep_equal(r.body.match.dest_port, ['22']);
	});

	t.it('records the new section in uci and reloads firewall', () => {
		let c = with_zones();
		rules.create(c, ctx(), { target: 'ACCEPT', match: { src_zone: 'wan' } });
		let added = keys(c._state.uci.firewall);
		let new_ids = filter(added, function(k) { return substr(k, 0, 2) == "r_"; });
		t.assert_equal(length(new_ids), 1);
		let calls = filter(c._state.ubus_calls, function(call) {
			return call[0] == "firewall" && call[1] == "reload";
		});
		t.assert_equal(length(calls), 1);
	});

	t.it('reports conflict when src_zone does not exist', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			target: 'ACCEPT', match: { src_zone: 'nope' },
		});
		t.assert_equal(r.status, 422);
		let conflict_errs = filter(r.body.errors, function(e) { return e.code == "conflict"; });
		t.assert_equal(length(conflict_errs), 1);
	});
});

t.describe('handler.replace', () => {
	function with_existing() {
		let c = with_zones();
		c._state.uci.firewall.r_existing = {
			'.type': 'rule', '.anonymous': false,
			target: 'ACCEPT', src: 'wan', dest_port: ['22'], proto: ['tcp'],
		};
		c._state.uci.firewall.cfg_anon = {
			'.type': 'rule', '.anonymous': true,
			target: 'DROP', src: 'wan',
		};
		return c;
	}

	t.it('returns 404 for unknown id', () => {
		let c = with_existing();
		let r = rules.replace(c, ctx(), 'r_nope', { target: 'DROP', match: { src_zone: 'wan' } });
		t.assert_equal(r.status, 404);
	});

	t.it('returns 409 unmanaged_resource for anonymous sections', () => {
		let c = with_existing();
		let r = rules.replace(c, ctx(), 'cfg_anon', { target: 'DROP', match: { src_zone: 'wan' } });
		t.assert_equal(r.status, 409);
		t.assert_equal(r.body.code, 'unmanaged_resource');
	});

	t.it('returns 422 on validation failure', () => {
		let c = with_existing();
		let r = rules.replace(c, ctx(), 'r_existing', { target: 'BOGUS', match: { src_zone: 'wan' } });
		t.assert_equal(r.status, 422);
	});

	t.it('replaces options and drops absent ones', () => {
		let c = with_existing();
		let r = rules.replace(c, ctx(), 'r_existing', {
			target: 'DROP', match: { src_zone: 'wan' },
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.target, 'DROP');
		t.assert_deep_equal(r.body.match.dest_port, []);
		t.assert_deep_equal(r.body.match.proto, []);
	});
});

t.describe('handler.patch', () => {
	function with_existing() {
		let c = with_zones();
		c._state.uci.firewall.r_existing = {
			'.type': 'rule', '.anonymous': false,
			target: 'ACCEPT', src: 'wan', dest_port: ['22'], proto: ['tcp'],
		};
		return c;
	}

	t.it('updates only the supplied fields', () => {
		let c = with_existing();
		let r = rules.patch(c, ctx(), 'r_existing', { target: 'REJECT' });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.target, 'REJECT');
		t.assert_equal(r.body.match.src_zone, 'wan');
		t.assert_deep_equal(r.body.match.dest_port, ['22']);
	});

	t.it('merges nested match fields rather than replacing', () => {
		let c = with_existing();
		let r = rules.patch(c, ctx(), 'r_existing', { match: { dest_port: ['80'] } });
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body.match.dest_port, ['80']);
		t.assert_equal(r.body.match.src_zone, 'wan');
	});

	t.it('returns 404 for unknown id', () => {
		let c = with_existing();
		let r = rules.patch(c, ctx(), 'r_nope', { target: 'DROP' });
		t.assert_equal(r.status, 404);
	});
});

t.describe('handler.remove', () => {
	function with_existing() {
		let c = with_zones();
		c._state.uci.firewall.r_existing = {
			'.type': 'rule', '.anonymous': false,
			target: 'ACCEPT', src: 'wan',
		};
		c._state.uci.firewall.cfg_anon = {
			'.type': 'rule', '.anonymous': true,
			target: 'DROP', src: 'wan',
		};
		return c;
	}

	t.it('returns 204 with no body on success', () => {
		let c = with_existing();
		let r = rules.remove(c, ctx(), 'r_existing');
		t.assert_equal(r.status, 204);
		t.assert_equal(r.body, null);
		t.assert_equal(c._state.uci.firewall.r_existing, null);
	});

	t.it('returns 404 for unknown id', () => {
		let c = with_existing();
		let r = rules.remove(c, ctx(), 'r_nope');
		t.assert_equal(r.status, 404);
	});

	t.it('returns 409 unmanaged_resource for anonymous sections', () => {
		let c = with_existing();
		let r = rules.remove(c, ctx(), 'cfg_anon');
		t.assert_equal(r.status, 409);
		t.assert_equal(r.body.code, 'unmanaged_resource');
	});
});

t.describe('handler.translate_tx', () => {
	t.it('passes through ok responses with the body', () => {
		let r = handler.translate_tx(ctx(), { ok: true, body: { hello: "world" } });
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body, { hello: "world" });
	});

	t.it('maps locked to 423 with Retry-After', () => {
		let r = handler.translate_tx(ctx(), { ok: false, kind: "locked" });
		t.assert_equal(r.status, 423);
		t.assert_equal(r.headers["Retry-After"], "1");
	});

	t.it('maps reload_failed_restored to 500 with reload_error', () => {
		let r = handler.translate_tx(ctx(), {
			ok: false, kind: "reload_failed_restored", reload_error: "fw4: bad",
		});
		t.assert_equal(r.status, 500);
		t.assert_equal(r.body.code, "reload_failed_restored");
		t.assert_equal(r.body.reload_error, "fw4: bad");
	});

	t.it('maps reload_failed_unrecovered to 500 with both errors', () => {
		let r = handler.translate_tx(ctx(), {
			ok: false, kind: "reload_failed_unrecovered",
			reload_error: "fw4: bad", restore_error: "uci EIO",
		});
		t.assert_equal(r.status, 500);
		t.assert_equal(r.body.restore_error, "uci EIO");
	});

	t.it('maps unknown kind to internal_error', () => {
		let r = handler.translate_tx(ctx(), { ok: false, kind: "weird" });
		t.assert_equal(r.status, 500);
		t.assert_equal(r.body.code, "internal_error");
	});
});
