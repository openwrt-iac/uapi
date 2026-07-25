let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let rules_mod = loadfile('src/resources/firewall.rules.uc')();
let reload_calls = [];
function record_reload(services) { push(reload_calls, services); return null; }
let rules = handler.make(rules_mod, {
	tx: {
		acquire: function() { return {}; },
		release: function() {},
		reload: record_reload,
		check_services: function() { return null; },
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

t.describe('handler.list pagination', () => {
	function seed_many(c, n) {
		for (let i = 0; i < n; i++) {
			c._state.uci.firewall["r_" + sprintf("%02d", i)] = {
				'.type': 'rule', '.anonymous': false,
				target: 'ACCEPT', src: 'wan', name: "rule_" + i,
			};
		}
	}

	t.it('returns the full list when below the default page size', () => {
		let c = with_zones();
		seed_many(c, 5);
		let r = rules.list(c, ctx(), {});
		t.assert_equal(length(r.body), 5);
		t.assert_equal(r.headers["X-Next-Cursor"], null);
	});

	t.it('honors ?limit=N and emits a next cursor when there are more', () => {
		let c = with_zones();
		seed_many(c, 6);
		let r = rules.list(c, ctx(), { limit: "2" });
		t.assert_equal(length(r.body), 2);
		t.assert_true(r.headers["X-Next-Cursor"] != null);
		t.assert_true(index(r.headers.Link, "rel=\"next\"") >= 0);
	});

	t.it('follows the next cursor across pages', () => {
		let c = with_zones();
		seed_many(c, 5);
		let p1 = rules.list(c, ctx(), { limit: "2" });
		let nxt = p1.headers["X-Next-Cursor"];
		let p2 = rules.list(c, ctx(), { limit: "2", cursor: nxt });
		t.assert_equal(length(p2.body), 2);
		t.assert_true(p2.body[0].id != p1.body[length(p1.body) - 1].id);
	});

	t.it('rejects a cursor whose id is not in the current result', () => {
		let c = with_zones();
		seed_many(c, 3);
		let r = rules.list(c, ctx(), { cursor: "c_r_99" });
		t.assert_equal(r.status, 400);
		t.assert_equal(r.body.code, "invalid_cursor");
	});

	t.it('rejects a malformed cursor', () => {
		let c = with_zones();
		seed_many(c, 3);
		let r = rules.list(c, ctx(), { cursor: "not-our-shape" });
		t.assert_equal(r.body.code, "invalid_cursor");
	});

	t.it('rejects limit outside 1..500', () => {
		let c = with_zones();
		seed_many(c, 3);
		t.assert_equal(rules.list(c, ctx(), { limit: "0" }).status, 400);
		t.assert_equal(rules.list(c, ctx(), { limit: "501" }).status, 400);
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
		let r = rules.create(c, ctx(), { target: "BOGUS", match: { family: "ipxx" } });
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
		let before = length(reload_calls);
		rules.create(c, ctx(), { target: 'ACCEPT', match: { src_zone: 'wan' } });
		let added = keys(c._state.uci.firewall);
		let new_ids = filter(added, function(k) { return substr(k, 0, 2) == "r_"; });
		t.assert_equal(length(new_ids), 1);
		t.assert_equal(length(reload_calls), before + 1);
		t.assert_deep_equal(reload_calls[length(reload_calls) - 1], ["firewall"]);
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

	// 2.2.0: every CRUD resource accepts optional `id` at create.
	t.it('accepts caller-supplied id and uses it as the section name', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			id: 'allow_ssh',
			target: 'ACCEPT',
			match: { src_zone: 'wan', dest_port: ['22'], proto: ['tcp'] },
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'allow_ssh');
		t.assert_true(!!c._state.uci.firewall.allow_ssh);
	});

	t.it('rejects caller-supplied id that collides with an existing section in the package', () => {
		// z_lan already exists as a zone in with_zones(); a rule trying to
		// take that name should 422 with a clean "conflict" code, not let
		// uci fail mid-commit.
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			id: 'z_lan',
			target: 'ACCEPT',
			match: { src_zone: 'wan' },
		});
		t.assert_equal(r.status, 422);
		let id_errs = filter(r.body.errors, function(e) { return e.field == "id" && e.code == "conflict"; });
		t.assert_equal(length(id_errs), 1);
	});

	t.it('rejects caller-supplied id that fails uci section-name charset rules', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			id: '0bad',
			target: 'ACCEPT',
			match: { src_zone: 'wan' },
		});
		t.assert_equal(r.status, 422);
		let id_errs = filter(r.body.errors, function(e) { return e.field == "id" && e.code == "invalid_format"; });
		t.assert_equal(length(id_errs), 1);
	});

	t.it('rejects empty-string id', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			id: '',
			target: 'ACCEPT',
			match: { src_zone: 'wan' },
		});
		t.assert_equal(r.status, 422);
		let id_errs = filter(r.body.errors, function(e) { return e.field == "id" && e.code == "invalid_format"; });
		t.assert_equal(length(id_errs), 1);
	});

	t.it('rejects id longer than the 32-char framework cap', () => {
		let c = with_zones();
		let too_long = '';
		for (let i = 0; i < 33; i++) too_long += 'a';
		let r = rules.create(c, ctx(), {
			id: too_long,
			target: 'ACCEPT',
			match: { src_zone: 'wan' },
		});
		t.assert_equal(r.status, 422);
		let id_errs = filter(r.body.errors, function(e) { return e.field == "id" && e.code == "invalid_format"; });
		t.assert_equal(length(id_errs), 1);
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

	t.it('normalizes away unmodeled uci options (PUT = full replace, uapi owns the section)', () => {
		// Counterpart to the PATCH-preserve test: PUT is a whole-resource
		// replace, so an option uapi does not model is intentionally dropped.
		let c = with_existing();
		c._state.uci.firewall.r_existing.icmp_type = ['echo-request'];
		let r = rules.replace(c, ctx(), 'r_existing', {
			target: 'DROP', match: { src_zone: 'wan' },
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.firewall.r_existing.icmp_type, null);
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

	t.it('accepts body.id that echoes the URL path id (idempotent GET-modify-PATCH cycle)', () => {
		// A client that does GET, mutates, PATCH back to the same URL will
		// often forward the `id` field verbatim. Framework treats it as a
		// harmless extra (firewall.rules has no `id` in schema_properties,
		// so check_schema_types ignores it).
		let c = with_existing();
		let r = rules.patch(c, ctx(), 'r_existing', { id: 'r_existing', target: 'REJECT' });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'r_existing');
		t.assert_equal(r.body.target, 'REJECT');
	});

	t.it('preserves uci options the resource does not model (PATCH is partial)', () => {
		// icmp_type and limit are real stock firewall-rule options uapi does
		// not model. A partial PATCH must not delete them (RFC-7396 merge).
		let c = with_existing();
		c._state.uci.firewall.r_existing.icmp_type = ['echo-request'];
		c._state.uci.firewall.r_existing.limit = '1000/sec';
		let r = rules.patch(c, ctx(), 'r_existing', { target: 'REJECT' });
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(c._state.uci.firewall.r_existing.icmp_type, ['echo-request']);
		t.assert_equal(c._state.uci.firewall.r_existing.limit, '1000/sec');
	});

	t.it('still deletes a modeled field the patch clears (footprint delete)', () => {
		let c = with_existing();
		let r = rules.patch(c, ctx(), 'r_existing', { match: { dest_port: [] } });
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body.match.dest_port, []);
		t.assert_equal(c._state.uci.firewall.r_existing.dest_port, null);
	});
});

t.describe('handler.patch JSON Patch write-only secret carry-forward', () => {
	let wiface_mod = loadfile('src/resources/wireless.interfaces.uc')();
	let wiface = handler.make(wiface_mod, {
		tx: {
			acquire: function() { return {}; }, release: function() {},
			reload: function() { return null; }, check_services: function() { return null; },
		},
	});
	function jctx() { return { request_id: "01hx0000000000000000000000", json_patch: true }; }
	function seeded() {
		return ubus.stub({ uci: { wireless: {
			w1: { '.type': 'wifi-iface', '.anonymous': false,
			      device: 'radio0', ssid: 'home', encryption: 'psk2', key: 'secretpw' },
		} } });
	}

	t.it('a JSON Patch that does not touch the masked key preserves it (no spurious key-required 422)', () => {
		let c = seeded();
		let r = wiface.patch(c, jctx(), 'w1', [ { op: 'replace', path: '/ssid', value: 'home2' } ]);
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.wireless.w1.ssid, 'home2');
		t.assert_equal(c._state.uci.wireless.w1.key, 'secretpw');
	});

	t.it('a JSON Patch that sets a new key is not clobbered by carry-forward', () => {
		let c = seeded();
		let r = wiface.patch(c, jctx(), 'w1', [ { op: 'add', path: '/key', value: 'newsecret' } ]);
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.wireless.w1.key, 'newsecret');
	});
});

t.describe('handler.adopt', () => {
	function with_anon() {
		let c = with_zones();
		c._state.uci.firewall.cfg_anon = {
			'.type': 'rule', '.anonymous': true,
			target: 'DROP', src: 'wan', dest_port: ['22'],
		};
		c._state.uci.firewall.r_named = {
			'.type': 'rule', '.anonymous': false,
			target: 'ACCEPT', src: 'lan',
		};
		return c;
	}

	t.it('returns 404 for unknown id', () => {
		let c = with_anon();
		let r = rules.adopt(c, ctx(), 'cfg_nope');
		t.assert_equal(r.status, 404);
	});

	t.it('is idempotent on already-named sections (keeps the name, 200)', () => {
		// 2.2.0 behavior change: adopt no longer 409s on a named section.
		// The previous rename-to-ULID would have broken uci cross-refs
		// where other sections reference this one by name (e.g. a default
		// `lan` zone referenced as firewall.rules.src_zone = "lan").
		let c = with_anon();
		let r = rules.adopt(c, ctx(), 'r_named');
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'r_named');
		t.assert_true(r.body.managed);
		t.assert_equal(r.body.target, 'ACCEPT');
	});

	t.it('named-section adopt does NOT trigger a reload', () => {
		// Regression guard for the S1 review finding: the previous
		// transactional path called reload() unconditionally on success,
		// so N adopts during a Terraform import fired N firewall reloads
		// with brief visible glitches each. Named adopt now short-circuits
		// before the transaction.
		let c = with_anon();
		let before = length(reload_calls);
		rules.adopt(c, ctx(), 'r_named');
		t.assert_equal(length(reload_calls), before);
	});

	t.it('renames the anonymous section to a ULID id and flips managed=true', () => {
		let c = with_anon();
		let r = rules.adopt(c, ctx(), 'cfg_anon');
		t.assert_equal(r.status, 200);
		t.assert_match(r.body.id, /^r_[0-9a-z]{26}$/);
		t.assert_true(r.body.managed);
		t.assert_equal(r.body.target, 'DROP');
		t.assert_equal(c._state.uci.firewall.cfg_anon, null);
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

t.describe('handler ETags / If-Match', () => {
	function with_rules() {
		return ubus.stub({
			uci: {
				firewall: {
					z_lan: { '.type': 'zone', name: 'lan' },
					z_wan: { '.type': 'zone', name: 'wan' },
					r_existing: { '.type': 'rule', '.anonymous': false,
					              target: 'ACCEPT', src: 'wan', proto: ['tcp'] },
				},
			},
		});
	}

	t.it('GET attaches an ETag header on the resource response', () => {
		let c = with_rules();
		let r = rules.get_one(c, ctx(), 'r_existing');
		t.assert_equal(r.status, 200);
		t.assert_true(r.headers.ETag != null);
		t.assert_true(length(r.headers.ETag) > 0);
	});

	t.it('two reads of the same state produce the same ETag', () => {
		let c = with_rules();
		let a = rules.get_one(c, ctx(), 'r_existing');
		let b = rules.get_one(c, ctx(), 'r_existing');
		t.assert_equal(a.headers.ETag, b.headers.ETag);
	});

	t.it('PUT without If-Match works (opt-in concurrency)', () => {
		let c = with_rules();
		let r = rules.replace(c, ctx(), 'r_existing', {
			target: 'DROP',
			match: { src_zone: 'wan', proto: ['tcp'] },
		});
		t.assert_equal(r.status, 200);
	});

	t.it('PUT with current If-Match succeeds and returns the new ETag', () => {
		let c = with_rules();
		let getr = rules.get_one(c, ctx(), 'r_existing');
		let etag = getr.headers.ETag;
		let ctx_with = { request_id: "01hx000000000000000000ifma", if_match: etag };
		let r = rules.replace(c, ctx_with, 'r_existing', {
			target: 'DROP',
			match: { src_zone: 'wan', proto: ['tcp'] },
		});
		t.assert_equal(r.status, 200);
		t.assert_true(r.headers.ETag != null);
		t.assert_true(r.headers.ETag != etag);
	});

	t.it('PUT with stale If-Match returns 412 precondition_failed', () => {
		let c = with_rules();
		let ctx_stale = { request_id: "01hx000000000000000000ifst", if_match: "\"deadbeef0000\"" };
		let r = rules.replace(c, ctx_stale, 'r_existing', {
			target: 'DROP',
			match: { src_zone: 'wan', proto: ['tcp'] },
		});
		t.assert_equal(r.status, 412);
		t.assert_equal(r.body.code, "precondition_failed");
	});

	t.it('PATCH with stale If-Match returns 412', () => {
		let c = with_rules();
		let ctx_stale = { request_id: "01hx000000000000000000ifsp", if_match: "\"00000000abcd\"" };
		let r = rules.patch(c, ctx_stale, 'r_existing', { target: 'REJECT' });
		t.assert_equal(r.status, 412);
		t.assert_equal(r.body.code, "precondition_failed");
	});

	t.it('PATCH with current If-Match (W/ weak prefix tolerated) succeeds', () => {
		let c = with_rules();
		let getr = rules.get_one(c, ctx(), 'r_existing');
		let weak = "W/" + getr.headers.ETag;
		let ctx_weak = { request_id: "01hx000000000000000000ifwk", if_match: weak };
		let r = rules.patch(c, ctx_weak, 'r_existing', { target: 'REJECT' });
		t.assert_equal(r.status, 200);
	});

	t.it('If-Match: * succeeds against any existing resource', () => {
		let c = with_rules();
		let ctx_star = { request_id: "01hx000000000000000000ifst", if_match: "*" };
		let r = rules.patch(c, ctx_star, 'r_existing', { target: 'REJECT' });
		t.assert_equal(r.status, 200);
	});
});

t.describe('handler ETag regressions', () => {
	function res_with_runtime() {
		// Minimal resource that has a runtime block.
		return {
			package: "firewall",
			type: "rule",
			reload: ["firewall"],
			fromUci: function(s, conn) {
				return {
					id: s['.name'],
					managed: !s['.anonymous'],
					target: s.target ?? null,
					src: s.src ?? null,
					runtime: { now: 1 },
				};
			},
			toUci: function(j) {
				let o = {};
				if (j.target != null) o.target = j.target;
				if (j.src != null) o.src = j.src;
				return o;
			},
			validate: function() { return []; },
		};
	}

	t.it('compute_etag ignores the runtime block', () => {
		let h = handler.make(res_with_runtime(), {
			tx: { acquire: function() { return {}; },
			      release: function() {},
			      reload: function() { return null; },
			      check_services: function() { return null; } } });
		let c = ubus.stub({ uci: { firewall: {
			r1: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan' },
		}}});
		let a = h.get_one(c, ctx(), 'r1');
		// Hack the cursor so the runtime field DIFFERS while uci stays the same.
		c._state.uci.firewall.r1._unrelated_drift = "ignored";
		let b = h.get_one(c, ctx(), 'r1');
		t.assert_equal(a.headers.ETag, b.headers.ETag);
	});

	// Regression for the v2.0.0 ETag-pollution bug. ETags must be a function
	// of THIS resource's body only; mutating a sibling in the same uci package
	// must not shift the ETag. The fixture declares depends_on so the test is
	// load-bearing: under the v2.0.0 _deps_hash code path it would have walked
	// every section of the depended-on type and re-hashed the package, so the
	// assertion below would have failed. With depends_on stripped from the
	// resource contract, the field is silently ignored and ETags stay stable.
	t.it('ETag is stable across unrelated sibling section churn', () => {
		let res = res_with_runtime();
		res.depends_on = ["firewall:rule", "firewall:zone"];
		let h = handler.make(res, {
			tx: { acquire: function() { return {}; },
			      release: function() {},
			      reload: function() { return null; },
			      check_services: function() { return null; } } });
		let c = ubus.stub({ uci: { firewall: {
			r1: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan' },
		}}});
		let initial = h.get_one(c, ctx(), 'r1').headers.ETag;

		// Add an unrelated sibling of the same type.
		c._state.uci.firewall.r2 = { '.type': 'rule', '.anonymous': false,
		                              target: 'REJECT', src: 'lan' };
		let after_add = h.get_one(c, ctx(), 'r1').headers.ETag;
		t.assert_equal(initial, after_add);

		// Add an unrelated section of a different (depended-on) type.
		c._state.uci.firewall.z1 = { '.type': 'zone', '.anonymous': false, name: 'lan' };
		let after_other_type = h.get_one(c, ctx(), 'r1').headers.ETag;
		t.assert_equal(initial, after_other_type);

		// Delete both. ETag must still be the original (pure function of r1's body).
		delete c._state.uci.firewall.r2;
		delete c._state.uci.firewall.z1;
		let after_delete = h.get_one(c, ctx(), 'r1').headers.ETag;
		t.assert_equal(initial, after_delete);
	});

	t.it('DELETE with stale If-Match returns 412 and does NOT delete', () => {
		let c = ubus.stub({ uci: { firewall: {
			z_lan: { '.type': 'zone', name: 'lan' },
			z_wan: { '.type': 'zone', name: 'wan' },
			r_existing: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan', proto: ['tcp'] },
		}}});
		let ctx_stale = { request_id: "01hxdelmismatch", if_match: "\"deadbeef0000\"" };
		let r = rules.remove(c, ctx_stale, 'r_existing');
		t.assert_equal(r.status, 412);
		// Verify the section is still there.
		let get_after = rules.get_one(c, ctx(), 'r_existing');
		t.assert_equal(get_after.status, 200);
	});

	t.it('DELETE with current If-Match succeeds', () => {
		let c = ubus.stub({ uci: { firewall: {
			z_lan: { '.type': 'zone', name: 'lan' },
			z_wan: { '.type': 'zone', name: 'wan' },
			r_existing: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan', proto: ['tcp'] },
		}}});
		let getr = rules.get_one(c, ctx(), 'r_existing');
		let ctx_ok = { request_id: "01hxdelok", if_match: getr.headers.ETag };
		let r = rules.remove(c, ctx_ok, 'r_existing');
		t.assert_equal(r.status, 204);
	});

	t.it('parse_if_match handles multi-value list (any-of-N matches)', () => {
		let c = ubus.stub({ uci: { firewall: {
			z_lan: { '.type': 'zone', name: 'lan' },
			z_wan: { '.type': 'zone', name: 'wan' },
			r_existing: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan', proto: ['tcp'] },
		}}});
		let getr = rules.get_one(c, ctx(), 'r_existing');
		let real = getr.headers.ETag;
		let mixed = "\"deadbeef0000\", " + real + ", \"0000abcdef00\"";
		let ctx_multi = { request_id: "01hxifmulti", if_match: mixed };
		let r = rules.patch(c, ctx_multi, 'r_existing', { target: 'REJECT' });
		t.assert_equal(r.status, 200);
	});

	t.it('parse_if_match: empty-quoted "" does not match anything', () => {
		let c = ubus.stub({ uci: { firewall: {
			z_lan: { '.type': 'zone', name: 'lan' },
			z_wan: { '.type': 'zone', name: 'wan' },
			r_existing: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan', proto: ['tcp'] },
		}}});
		let ctx_empty = { request_id: "01hxifempty", if_match: "\"\"" };
		let r = rules.patch(c, ctx_empty, 'r_existing', { target: 'REJECT' });
		// Empty-after-strip becomes "no If-Match" per the parser; that means
		// the patch proceeds normally (not a 412). Important: it does NOT
		// match anything, so don't silently allow with the wrong ETag.
		t.assert_equal(r.status, 200);
	});
});

t.describe('handler schema-type check (silent-drop guard)', () => {
	t.it('POST with array field passed as string -> 422 invalid_type', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			target: "ACCEPT",
			match: { src_zone: "wan", proto: ["tcp"], dest_port: "55555" },
		});
		t.assert_equal(r.status, 422);
		let errs = r.body.errors;
		let hit = null;
		for (let e in errs)
			if (e.field == "match.dest_port") hit = e;
		t.assert_true(hit != null);
		t.assert_equal(hit.code, "invalid_type");
		t.assert_true(match(hit.message, /must be array/) != null);
	});

	t.it('POST with array field correctly typed succeeds', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			target: "ACCEPT",
			match: { src_zone: "wan", proto: ["tcp"], dest_port: ["55555"] },
		});
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body.match.dest_port, ["55555"]);
	});

	t.it('POST with nested-object passed as string -> 422 invalid_type for the parent', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			target: "ACCEPT",
			match: "wan",  // should be an object
		});
		t.assert_equal(r.status, 422);
		let errs = r.body.errors;
		let hit = null;
		for (let e in errs)
			if (e.field == "match" && e.code == "invalid_type") hit = e;
		t.assert_true(hit != null);
	});

	t.it('PATCH carrying a wrong-typed array gets caught too', () => {
		let c = ubus.stub({ uci: { firewall: {
			z_lan: { '.type': 'zone', name: 'lan' },
			z_wan: { '.type': 'zone', name: 'wan' },
			r_existing: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT', src: 'wan', proto: ['tcp'] },
		}}});
		let r = rules.patch(c, ctx(), 'r_existing', { match: { dest_port: "9999" } });
		t.assert_equal(r.status, 422);
		let errs = r.body.errors;
		let hit = null;
		for (let e in errs)
			if (e.field == "match.dest_port" && e.code == "invalid_type") hit = e;
		t.assert_true(hit != null);
	});

	t.it('schema check tolerates a null value for a typed field (treated as unset)', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			target: "ACCEPT",
			match: { src_zone: "wan", proto: null },
		});
		// Contract: null on a typed field means "unset", never invalid_type.
		// Holds regardless of whether resource.validate happens to 422 for
		// other reasons.
		if (r.body != null && r.body.errors != null) {
			for (let e in r.body.errors)
				if (e.field == "match.proto")
					t.assert_true(e.code != "invalid_type");
		}
	});

	t.it('match-as-string emits a SINGLE (field, code) error (no duplicate from resource.validate)', () => {
		let c = with_zones();
		let r = rules.create(c, ctx(), {
			target: "ACCEPT",
			match: "wan",
		});
		t.assert_equal(r.status, 422);
		let hits = 0;
		for (let e in r.body.errors)
			if (e.field == "match" && e.code == "invalid_type") hits++;
		t.assert_equal(hits, 1);
	});

	t.it('error message uses JSON Schema vocabulary (got integer, not got int)', () => {
		let c = with_zones();
		// target wants string; pass a JSON integer.
		let r = rules.create(c, ctx(), { target: 42, match: { src_zone: "wan" } });
		t.assert_equal(r.status, 422);
		let hit = null;
		for (let e in r.body.errors)
			if (e.field == "target" && e.code == "invalid_type") hit = e;
		t.assert_true(hit != null);
		t.assert_true(match(hit.message, /got integer/) != null);
	});
});

// dropbear.instances declares port as integer while fromUci returns the uci
// string view of the underlying uci-native Port key. Regression sentinel:
// PATCH must not 422 on port when body didn't touch it.
let dropbear_mod = loadfile('src/resources/dropbear.instances.uc')();
let dropbear = handler.make(dropbear_mod, {
	tx: {
		acquire: function() { return {}; },
		release: function() {},
		reload: record_reload,
		check_services: function() { return null; },
	},
});

t.describe('handler schema-type check: PATCH does not re-validate uci-string fields', () => {
	t.it('PATCH on an unrelated field of dropbear.instances does not 422 on port', () => {
		let c = ubus.stub({ uci: { dropbear: {
			d_main: { '.type': 'dropbear', '.anonymous': false, Port: '22', RootLogin: '1' },
		}}});
		let r = dropbear.patch(c, ctx(), 'd_main', { root_login: false });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.root_login, false);
		// port is the as_int-coerced view of uci's "22".
		t.assert_equal(r.body.port, 22);
	});

	t.it('PATCH still rejects a wrong-typed delta even when the merge would pass', () => {
		let c = ubus.stub({ uci: { dropbear: {
			d_main: { '.type': 'dropbear', '.anonymous': false, Port: '22' },
		}}});
		// port as a string in the delta: schema_properties declares integer.
		let r = dropbear.patch(c, ctx(), 'd_main', { port: 'not-a-number' });
		t.assert_equal(r.status, 422);
		let hit = null;
		for (let e in r.body.errors)
			if (e.field == 'port' && e.code == 'invalid_type') hit = e;
		t.assert_true(hit != null);
	});

	t.it('POST that supplies an integer for an integer-typed field still works', () => {
		let c = ubus.stub({ uci: { dropbear: {} } });
		let r = dropbear.create(c, ctx(), { port: 2222 });
		t.assert_equal(r.status, 200);
	});
});

// No shipped resource has a 3+ level schema today. This synthetic fixture
// pins the recursion contract so a future regression would surface here.
let deep_mod = {
	package: "deeptest",
	type: "deep",
	reload: [],
	fromUci: function(s) { return { id: s['.name'], managed: true }; },
	toUci: function() { return {}; },
	validate: function() { return []; },
	schema_properties: {
		a: { type: "object", properties: {
			b: { type: "object", properties: {
				c: { type: "object", properties: {
					leaf: { type: "string" },
				}},
			}},
		}},
	},
};
let deep = handler.make(deep_mod, {
	tx: {
		acquire: function() { return {}; },
		release: function() {},
		reload: record_reload,
		check_services: function() { return null; },
	},
});

let constraints_mod = {
	package: "constraintest",
	type: "row",
	reload: [],
	fromUci: function(s) { return { id: s['.name'], managed: true }; },
	toUci: function() { return {}; },
	validate: function() { return []; },
	schema_properties: {
		color:   { type: "string", enum: ["red", "green", "blue"] },
		port:    { type: "integer", minimum: 1, maximum: 65535 },
		ratio:   { type: "number", minimum: 0, maximum: 1 },
		slug:    { type: "string", pattern: "^[a-z0-9_]+$" },
		tags:    { type: "array", items: { type: "string", enum: ["a", "b", "c"] } },
		bounded_ints: { type: "array", items: { type: "integer", minimum: 0, maximum: 9 } },
	},
};
let constraints = handler.make(constraints_mod, {
	tx: {
		acquire: function() { return {}; },
		release: function() {},
		reload: record_reload,
		check_services: function() { return null; },
	},
});

t.describe('handler schema check: enum / min-max / pattern / items', () => {
	function err_for(r, field, code) {
		for (let e in r.body.errors)
			if (e.field == field && e.code == code) return e;
		return null;
	}

	t.it('enum violation -> not_in_enum', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { color: "purple" });
		t.assert_equal(r.status, 422);
		t.assert_true(err_for(r, "color", "not_in_enum") != null);
	});

	t.it('integer below minimum -> out_of_range', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { port: 0 });
		t.assert_equal(r.status, 422);
		t.assert_true(err_for(r, "port", "out_of_range") != null);
	});

	t.it('integer above maximum -> out_of_range', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { port: 70000 });
		t.assert_equal(r.status, 422);
		t.assert_true(err_for(r, "port", "out_of_range") != null);
	});

	t.it('number type accepts doubles within bounds', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { ratio: 0.5 });
		t.assert_equal(r.status, 200);
	});

	t.it('pattern violation -> invalid_format', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { slug: "Has Spaces!" });
		t.assert_equal(r.status, 422);
		t.assert_true(err_for(r, "slug", "invalid_format") != null);
	});

	t.it('items: wrong type per element with indexed path', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { tags: ["a", 2, "b"] });
		t.assert_equal(r.status, 422);
		t.assert_true(err_for(r, "tags[1]", "invalid_type") != null);
	});

	t.it('items: enum check propagates to elements', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { tags: ["a", "x"] });
		t.assert_equal(r.status, 422);
		t.assert_true(err_for(r, "tags[1]", "not_in_enum") != null);
	});

	t.it('items: min/max check propagates to elements', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), { bounded_ints: [3, 99, 1] });
		t.assert_equal(r.status, 422);
		t.assert_true(err_for(r, "bounded_ints[1]", "out_of_range") != null);
	});

	t.it('valid body across all constraints -> 200', () => {
		let c = ubus.stub({ uci: { constraintest: {} } });
		let r = constraints.create(c, ctx(), {
			color: "red", port: 80, ratio: 0.25, slug: "hello_world",
			tags: ["a", "b"], bounded_ints: [0, 5, 9],
		});
		t.assert_equal(r.status, 200);
	});
});

t.describe('handler schema-type check recurses past two levels', () => {
	t.it('leaf type error 3 levels deep surfaces with full dotted path', () => {
		let c = ubus.stub({ uci: { deeptest: {} } });
		let r = deep.create(c, ctx(), { a: { b: { c: { leaf: 42 } } } });
		t.assert_equal(r.status, 422);
		let hit = null;
		for (let e in r.body.errors)
			if (e.field == "a.b.c.leaf" && e.code == "invalid_type") hit = e;
		t.assert_true(hit != null);
	});

	t.it('mid-tree wrong-type stops recursion at that node', () => {
		let c = ubus.stub({ uci: { deeptest: {} } });
		let r = deep.create(c, ctx(), { a: { b: "should-be-object" } });
		t.assert_equal(r.status, 422);
		let hit = null;
		for (let e in r.body.errors)
			if (e.field == "a.b" && e.code == "invalid_type") hit = e;
		t.assert_true(hit != null);
		// And no spurious error for a.b.c.leaf since recursion bailed.
		for (let e in r.body.errors)
			t.assert_true(e.field != "a.b.c.leaf");
	});
});

let zones_mod = loadfile('src/resources/firewall.zones.uc')();
let zones = handler.make(zones_mod, {
	tx: {
		acquire: function() { return {}; },
		release: function() {},
		reload: record_reload,
		check_services: function() { return null; },
	},
});

t.describe('handler.create unique_field uniqueness', () => {
	t.it('rejects create whose unique_field value matches another same-type section', () => {
		let c = with_zones();
		let r = zones.create(c, ctx(), {
			id: 'z_lan_dup',
			name: 'lan',
			input: 'ACCEPT', output_policy: 'ACCEPT', forward: 'ACCEPT',
		});
		t.assert_equal(r.status, 422);
		let errs = filter(r.body.errors, function(e) { return e.field == "name" && e.code == "conflict"; });
		t.assert_equal(length(errs), 1);
		t.assert_true(index(errs[0].message, "z_lan") >= 0);
	});

	t.it('accepts create whose unique_field value does not collide', () => {
		let c = with_zones();
		let r = zones.create(c, ctx(), {
			id: 'z_dmz',
			name: 'dmz',
			input: 'ACCEPT', output_policy: 'ACCEPT', forward: 'ACCEPT',
		});
		t.assert_equal(r.status, 200);
	});

	t.it('skips the unique_field check when the field is absent (schema-required path handles it)', () => {
		let c = with_zones();
		let r = zones.create(c, ctx(), {
			id: 'z_noname',
			input: 'ACCEPT', output_policy: 'ACCEPT', forward: 'ACCEPT',
		});
		t.assert_equal(r.status, 422);
		let conflict_errs = filter(r.body.errors, function(e) { return e.field == "name" && e.code == "conflict"; });
		t.assert_equal(length(conflict_errs), 0);
	});

	t.it('PATCH that keeps the same unique_field value passes (ignore_section_id excludes self)', () => {
		let c = with_zones();
		let r = zones.patch(c, ctx(), 'z_lan', { input: 'REJECT' });
		t.assert_equal(r.status, 200);
	});

	t.it('PATCH that changes unique_field to a value held by another section is rejected', () => {
		let c = with_zones();
		let r = zones.patch(c, ctx(), 'z_lan', { name: 'wan' });
		t.assert_equal(r.status, 422);
		let errs = filter(r.body.errors, function(e) { return e.field == "name" && e.code == "conflict"; });
		t.assert_equal(length(errs), 1);
		t.assert_true(index(errs[0].message, "z_wan") >= 0);
	});

	t.it('PUT (replace) that keeps the same unique_field value passes', () => {
		let c = with_zones();
		let r = zones.replace(c, ctx(), 'z_lan', {
			name: 'lan',
			input: 'REJECT', output_policy: 'ACCEPT', forward: 'ACCEPT',
		});
		t.assert_equal(r.status, 200);
	});

	t.it('PUT (replace) that changes unique_field to a value held by another section is rejected', () => {
		let c = with_zones();
		let r = zones.replace(c, ctx(), 'z_lan', {
			name: 'wan',
			input: 'ACCEPT', output_policy: 'ACCEPT', forward: 'ACCEPT',
		});
		t.assert_equal(r.status, 422);
		let errs = filter(r.body.errors, function(e) { return e.field == "name" && e.code == "conflict"; });
		t.assert_equal(length(errs), 1);
	});
});
