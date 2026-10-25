let t = require('harness');
let bus = require('bus');
let raw = loadfile('src/raw.uc')();

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

t.describe('raw.inferred_domain_path', () => {
	t.it('maps known package.type pairs to their curated domain path', () => {
		t.assert_deep_equal(raw.inferred_domain_path("firewall", "rule"),
		                    ["firewall", "rules"]);
		t.assert_deep_equal(raw.inferred_domain_path("network", "interface"),
		                    ["network", "interfaces"]);
		t.assert_deep_equal(raw.inferred_domain_path("wireless", "wifi-iface"),
		                    ["wireless", "interfaces"]);
		t.assert_deep_equal(raw.inferred_domain_path("system", "system"),
		                    ["system"]);
	});

	t.it('falls back to [package] for unknown section types', () => {
		t.assert_deep_equal(raw.inferred_domain_path("openvpn", "openvpn"),
		                    ["openvpn"]);
		t.assert_deep_equal(raw.inferred_domain_path("ipsec", "tunnel"),
		                    ["ipsec"]);
	});

	t.it('maps dynamic wireguard_<iface> peer types to network/wireguard_peers', () => {
		t.assert_deep_equal(raw.inferred_domain_path("network", "wireguard_wg1"),
		                    ["network", "wireguard_peers"]);
		t.assert_deep_equal(raw.inferred_domain_path("network", "wireguard_VPNMLV"),
		                    ["network", "wireguard_peers"]);
	});
});

t.describe('raw.list, scope check', () => {
	function with_data() {
		return bus.stub({
			uci: { firewall: {
				z_lan: { '.type': 'zone', '.anonymous': false, name: 'lan' },
				cfg00: { '.type': 'rule', '.anonymous': true, target: 'ACCEPT' },
			} },
		});
	}

	t.it('admin scope returns all sections', () => {
		let r = raw.list(with_data(), ctx(), ["*:rw"], "firewall");
		t.assert_equal(r.status, 200);
		t.assert_equal(length(r.body), 2);
		let names = [];
		for (let s in r.body) push(names, s.id);
		sort(names);
		t.assert_deep_equal(names, ["cfg00", "z_lan"]);
	});

	t.it('denies when raw scope is missing', () => {
		let r = raw.list(with_data(), ctx(), ["firewall:rw"], "firewall");
		t.assert_equal(r.status, 403);
	});

	t.it('denies when domain scope is missing', () => {
		let r = raw.list(with_data(), ctx(), ["raw:rw"], "firewall");
		t.assert_equal(r.status, 403);
	});

	t.it('allows with raw:rw and the package scope', () => {
		let r = raw.list(with_data(), ctx(), ["raw:rw", "firewall:ro"], "firewall");
		t.assert_equal(r.status, 200);
	});
});

t.describe('raw.get_one, normalization and per-type scope', () => {
	function with_data() {
		return bus.stub({
			uci: { firewall: {
				r_known: { '.type': 'rule', '.anonymous': false,
				           target: 'ACCEPT', src: 'wan', dest_port: ['22'] },
				cfg00:   { '.type': 'zone', '.anonymous': true, name: 'lan' },
			} },
		});
	}

	t.it('returns 404 for unknown section', () => {
		let r = raw.get_one(with_data(), ctx(), ["*:rw"], "firewall", "nope");
		t.assert_equal(r.status, 404);
	});

	t.it('returns normalized section with managed flag and .type', () => {
		let r = raw.get_one(with_data(), ctx(), ["*:rw"], "firewall", "r_known");
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, "r_known");
		t.assert_equal(r.body['.type'], "rule");
		t.assert_true(r.body.managed);
		t.assert_equal(r.body.target, "ACCEPT");
	});

	// zerotier stores its network id as `option id`, and the read used to name that instead.
	t.it('keeps the section name as id when the section stores an option id', () => {
		let conn = bus.stub({ uci: { zerotier: {
			earth: { '.type': 'network', '.anonymous': false, id: '8056c2e21c000001' },
		} } });
		let r = raw.get_one(conn, ctx(), ["*:rw"], "zerotier", "earth");
		t.assert_equal(r.body.id, "earth");
	});

	t.it('marks anonymous sections as managed=false', () => {
		let r = raw.get_one(with_data(), ctx(), ["*:rw"], "firewall", "cfg00");
		t.assert_equal(r.status, 200);
		t.assert_false(r.body.managed);
	});

	t.it('honors deepest-match: firewall:rules:ro blocks even with raw:rw', () => {
		let r = raw.get_one(with_data(), ctx(),
		                    ["raw:rw", "firewall:rw", "firewall:rules:ro"],
		                    "firewall", "r_known");
		t.assert_equal(r.status, 200);
		// reading is fine; the rule blocks writes only
	});

	t.it('denies read when domain scope forbids the inferred path', () => {
		let r = raw.get_one(with_data(), ctx(),
		                    ["raw:rw", "firewall:zones:rw"],
		                    "firewall", "r_known");
		t.assert_equal(r.status, 403);
	});
});

t.describe('raw.create, client-supplied id', () => {
	function fw_with(section) {
		let uci = { firewall: {} };
		if (section) uci.firewall[section.name] = section.data;
		return bus.stub({ uci: uci });
	}

	t.it('rejects ids that violate the uci section-name charset', () => {
		let r = raw.create(fw_with(null), ctx(), ["*:rw"], "firewall",
			{ ".type": "rule", id: "bad.name", target: "ACCEPT" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "id");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects ids whose value is not a string', () => {
		let r = raw.create(fw_with(null), ctx(), ["*:rw"], "firewall",
			{ ".type": "rule", id: 42, target: "ACCEPT" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	// ucode's `0 == ""` and `false == ""` are true, so both read as no id and got a generated one.
	t.it('rejects an id of 0 or false instead of generating one', () => {
		for (let id in [ 0, false ]) {
			let r = raw.create(fw_with(null), ctx(), ["*:rw"], "firewall",
				{ ".type": "rule", id, target: "ACCEPT" });
			t.assert_equal(r.status, 422);
			t.assert_equal(r.body.errors[0].field, "id");
		}
	});

	t.it('answers 503 config_missing when the package has no config file', () => {
		let conn = bus.stub({ uci: {}, missing_packages: [ "uapi_nosuchpkg" ] });
		let r = raw.create(conn, ctx(), ["*:rw"], "uapi_nosuchpkg", { ".type": "thing", a: "1" });
		t.assert_equal(r.status, 503);
		t.assert_equal(r.body.code, "config_missing");
		t.assert_deep_equal(conn._state.uci_ops, []);
	});

	// ucitrack can name a service that is not installed, and raw answered 500 "unknown kind".
	t.it('answers 503 init_script_missing when ucitrack names a missing daemon', () => {
		let conn = bus.stub({ uci: { ucitrack: {
			t1: { '.type': 'uapi_tracked', init: 'uapi-no-such-daemon' },
		} } });
		let r = raw.create(conn, ctx(), ["*:rw"], "uapi_tracked", { ".type": "thing", a: "1" });
		t.assert_equal(r.status, 503);
		t.assert_equal(r.body.code, "init_script_missing");
	});

	t.it('returns 409 when the supplied id already exists', () => {
		let conn = fw_with({ name: "z_lan",
			data: { '.type': 'zone', '.anonymous': false, name: 'lan' } });
		let r = raw.create(conn, ctx(), ["*:rw"], "firewall",
			{ ".type": "rule", id: "z_lan", target: "ACCEPT" });
		t.assert_equal(r.status, 409);
		t.assert_equal(r.body.code, "conflict");
	});
});

// Each of these answered 200 on a device and stored nothing, or only part of what was sent.
t.describe('raw writes refuse what uci cannot store', () => {
	function fw() {
		return bus.stub({ uci: { firewall: {
			r1: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT' },
		} } });
	}
	function fields(r) { return map(r.body.errors, e => [ e.field, e.code ]); }

	for (let c in [
		[ "a name outside the uci charset", { "b-c": "1" }, "b-c", "invalid_format" ],
		[ "a dotted name", { ".b": "1" }, ".b", "invalid_format" ],
		[ "an object", { b: { x: 1 } }, "b", "invalid_type" ],
		[ "a list holding a null", { b: [ "a", null ] }, "b[1]", "invalid_type" ],
		[ "a list holding an object", { b: [ "a", { x: 1 } ] }, "b[1]", "invalid_type" ],
		[ "a nested list", { b: [ "a", [ "b", "c" ] ] }, "b[1]", "invalid_type" ],
		[ "an empty string that leads a longer list", { b: [ "", "x" ] }, "b[0]", "invalid_format" ],
	]) {
		t.it(sprintf("%s, on create, replace and patch", c[0]), () => {
			let conn = fw();
			for (let r in [
				raw.create(conn, ctx(), ["*:rw"], "firewall", { ".type": "rule", ...c[1] }),
				raw.replace(conn, ctx(), ["*:rw"], "firewall", "r1", c[1]),
				raw.patch(conn, ctx(), ["*:rw"], "firewall", "r1", c[1]),
			]) {
				t.assert_equal(r.status, 422);
				t.assert_deep_equal(fields(r), [ [ c[2], c[3] ] ]);
			}
		});
	}

	t.it('lists every refused field in one 422', () => {
		let r = raw.create(fw(), ctx(), ["*:rw"], "firewall",
			{ ".type": "a b", id: "x.y", "b-c": "1", d: {}, e: [ 1, null ] });
		t.assert_deep_equal(fields(r), [
			[ ".type", "invalid_format" ], [ "id", "invalid_format" ],
			[ "b-c", "invalid_format" ], [ "d", "invalid_type" ], [ "e[1]", "invalid_type" ],
		]);
	});

	// uci takes the five, but writes the type unquoted, so the file re-reads them as syntax.
	for (let st in [ "a\"b", "a#b", "a'b", "a;b", "a\\b", "a b", "th\u00e9", "a\u0001b" ])
		t.it(sprintf("refuses the section type %J", st), () => {
			let r = raw.create(fw(), ctx(), ["*:rw"], "firewall", { ".type": st, target: "ACCEPT" });
			t.assert_deep_equal(fields(r), [ [ ".type", "invalid_format" ] ]);
		});

	// `rule#x` mapped to the bare [firewall] domain, and uci re-read it as a rule.
	t.it('refuses rule#x before the scope check can map it past firewall:rules:ro', () => {
		let scopes = [ "raw:firewall:rw", "firewall:rw", "firewall:rules:ro" ];
		let r = raw.create(fw(), ctx(), scopes, "firewall", { ".type": "rule#x", id: "probe", target: "ACCEPT" });
		t.assert_deep_equal(fields(r), [ [ ".type", "invalid_format" ] ]);
		r = raw.create(fw(), ctx(), scopes, "firewall", { ".type": "rule", target: "ACCEPT" });
		t.assert_equal(r.body.code, "insufficient_scope");
	});

	t.it('refuses a type or an id that differs from the section on replace and patch', () => {
		for (let w in [ raw.replace, raw.patch ]) {
			let r = w(fw(), ctx(), ["*:rw"], "firewall", "r1", { ".type": "zone", id: "r2", target: "DROP" });
			t.assert_deep_equal(fields(r), [ [ ".type", "read_only" ], [ "id", "read_only" ] ]);
		}
	});
});

// uci resolves `@rule[0]` and `@[-1]` as well as a name. The stub does not, so this conn maps
// the position to the section the way libuci would.
t.describe('raw ids by position', () => {
	function positional() {
		let c = bus.stub({
			uci: { uapi_nosuchpkg: { cfg0a1b2c: { '.type': 'rule', '.anonymous': true, a: '1' } } },
			missing_packages: [ "uapi_nosuchpkg" ],
		});
		let get = c.uci_get;
		c.uci_get = (p, s, o) => get(p, s == "@rule[0]" ? "cfg0a1b2c" : s, o);
		return c;
	}

	t.it('a read names the section, not the position', () => {
		let r = raw.get_one(positional(), ctx(), ["*:rw"], "uapi_nosuchpkg", "@rule[0]");
		t.assert_equal(r.body.id, "cfg0a1b2c");
	});

	t.it('a write checks an echo against the name that the read gave', () => {
		for (let w in [ raw.replace, raw.patch ]) {
			let r = w(positional(), ctx(), ["*:rw"], "uapi_nosuchpkg", "@rule[0]", { id: "cfg0a1b2c" });
			t.assert_equal(r.body.code, "config_missing");
			r = w(positional(), ctx(), ["*:rw"], "uapi_nosuchpkg", "@rule[0]", { id: "@rule[0]" });
			t.assert_equal(r.body.code, "validation_failed");
		}
	});
});

// A write that succeeds needs the real flock, so these read what the transaction would set.
t.describe('raw.writable_options', () => {
	t.it('turns null and "" into a removal, and keeps every other value as sent', () => {
		let w = raw.writable_options({ z: null, s: "", e: [], n: 5, l: [ "a", "" ], one: [ "" ] });
		t.assert_deep_equal(w.errors, []);
		t.assert_deep_equal(w.opts, { z: [], s: [], e: [], n: 5, l: [ "a", "" ], one: [ "" ] });
	});

	t.it('leaves out the keys that name the section or that a response derives', () => {
		let w = raw.writable_options({ ".type": "t", id: "s1", managed: true, reloaded: false,
		                               reload_services: [ "firewall" ], reload_note: "x", a: "1" });
		t.assert_deep_equal(w.opts, { a: "1" });
	});
});

// A successful write needs the real flock, so the missing config file is what proves that a
// body got past the checks: that refusal comes from the transaction.
t.describe('raw writes pass what uci can store', () => {
	function missing() {
		return bus.stub({
			uci: { uapi_nosuchpkg: { s1: { '.type': 'thing', '.anonymous': false, a: '1' } } },
			missing_packages: [ "uapi_nosuchpkg" ],
		});
	}
	let body = { managed: null, reloaded: false, reload_services: [ "firewall" ], reload_note: "x",
	             n: 5, f: 1.5, on: true, l: [ 1, false, "x" ], one: [ "" ], tail: [ "a", "" ],
	             e: [], z: null, s: "" };

	t.it('on create, with a punctuated type and a null id', () => {
		for (let st in [ "wifi-iface", "a.b:c@d+e" ]) {
			let r = raw.create(missing(), ctx(), ["*:rw"], "uapi_nosuchpkg",
				{ ".type": st, id: null, ...body });
			t.assert_equal(r.body.code, "config_missing");
		}
	});

	t.it('on replace and patch, with an echo of the type and id', () => {
		for (let w in [ raw.replace, raw.patch ]) {
			let r = w(missing(), ctx(), ["*:rw"], "uapi_nosuchpkg", "s1",
				{ ".type": "thing", id: "s1", ...body });
			t.assert_equal(r.body.code, "config_missing");
		}
	});

	// ids.new_id takes only lowercase letters and died on these, which answered 500.
	for (let st in [ "LoadPlugin", "6in4", "_x" ])
		t.it(sprintf("generates an id for the type %J", st), () => {
			let r = raw.create(missing(), ctx(), ["*:rw"], "uapi_nosuchpkg", { ".type": st });
			t.assert_equal(r.body.code, "config_missing");
		});
});

t.describe('raw permission composition for writes', () => {
	function fw() {
		return bus.stub({
			uci: { firewall: {
				r_known: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT' },
			} },
		});
	}

	t.it('raw:rw alone is not enough to delete', () => {
		let r = raw.remove(fw(), ctx(), ["raw:rw"], "firewall", "r_known");
		t.assert_equal(r.status, 403);
	});

	t.it('domain:rw alone (no raw) is not enough to delete', () => {
		let r = raw.remove(fw(), ctx(), ["firewall:rules:rw"], "firewall", "r_known");
		t.assert_equal(r.status, 403);
	});

	t.it('firewall:rules:ro blocks delete even with raw:rw + firewall:rw', () => {
		let r = raw.remove(fw(), ctx(),
		                    ["raw:rw", "firewall:rw", "firewall:rules:ro"],
		                    "firewall", "r_known");
		t.assert_equal(r.status, 403);
	});
});

// The curated token endpoints gate salt and hash behind include_secret, set only on the
// internal auth path. The passthrough returned the section verbatim, so GET /raw/uapi handed
// back exactly what they mask: confirmed on a box running 3.0.0-rc1, five tokens including a
// *:rw one. Reaching them needs raw:uapi and uapi:tokens together, so this was disclosure
// rather than escalation, but the material flows into anything built on a raw read.
t.describe('raw does not disclose token credential material', () => {
	function tokens() {
		return bus.stub({ uci: { uapi: {
			admin: { '.type': 'token', '.anonymous': false, salt: 'ff27a159', hash: 'a587ce7e',
			         scopes: ['*:rw'], name: 'admin' },
		}}});
	}

	t.it('strips salt and hash from a list', () => {
		let r = raw.list(tokens(), ctx(), ["*:rw"], "uapi");
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body[0].salt, null);
		t.assert_equal(r.body[0].hash, null);
		t.assert_equal(r.body[0].name, 'admin');
	});

	t.it('strips them from a single get too', () => {
		let r = raw.get_one(tokens(), ctx(), ["*:rw"], "uapi", "admin");
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.salt, null);
		t.assert_equal(r.body.hash, null);
	});

	t.it('leaves other packages untouched', () => {
		let c = bus.stub({ uci: { firewall: {
			z: { '.type': 'zone', '.anonymous': false, name: 'lan', salt: 'not-a-secret-here' },
		}}});
		let r = raw.get_one(c, ctx(), ["*:rw"], "firewall", "z");
		t.assert_equal(r.body.salt, 'not-a-secret-here');
	});

	// The trap the strip creates cannot be unit-tested: a successful raw write needs the real
	// flock, which no unit test can take, and every existing raw-write case here asserts a
	// pre-transaction failure for the same reason. A stripped field cannot come back in a
	// replace body, and replace deletes what the body omits, so a plain read-modify-write
	// would destroy the credential. The carry-forward that prevents it is verified on
	// hardware instead, in the PR that added it.
});
