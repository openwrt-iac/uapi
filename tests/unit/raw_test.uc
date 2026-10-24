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

// Each of these answered 200 on a device and stored nothing for the option.
t.describe('raw writes refuse what uci cannot store', () => {
	function fw() {
		return bus.stub({ uci: { firewall: {
			r1: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT' },
		} } });
	}
	for (let c in [
		[ "a name outside the uci charset", { "b-c": "1" }, "b-c", "invalid_format" ],
		[ "a null", { b: null }, "b", "invalid_type" ],
		[ "an object", { b: { x: 1 } }, "b", "invalid_type" ],
		[ "a list holding a null", { b: [ "a", null ] }, "b", "invalid_type" ],
	]) {
		t.it(sprintf("%s, on create, replace and patch", c[0]), () => {
			let conn = fw();
			for (let r in [
				raw.create(conn, ctx(), ["*:rw"], "firewall", { ".type": "rule", ...c[1] }),
				raw.replace(conn, ctx(), ["*:rw"], "firewall", "r1", c[1]),
				raw.patch(conn, ctx(), ["*:rw"], "firewall", "r1", c[1]),
			]) {
				t.assert_equal(r.status, 422);
				t.assert_equal(r.body.errors[0].field, c[2]);
				t.assert_equal(r.body.errors[0].code, c[3]);
			}
			t.assert_deep_equal(conn._state.uci_ops, []);
		});
	}

	t.it('a section type with a space', () => {
		let r = raw.create(fw(), ctx(), ["*:rw"], "firewall", { ".type": "a rule" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, ".type");
	});

	// A successful write needs the real flock, so the missing config file is what proves that
	// the body got past the check: that refusal comes from the transaction.
	t.it('passes numbers, booleans, lists of them, a hyphenated type and an echoed managed', () => {
		let conn = bus.stub({ uci: {}, missing_packages: [ "uapi_nosuchpkg" ] });
		let r = raw.create(conn, ctx(), ["*:rw"], "uapi_nosuchpkg",
			{ ".type": "wifi-iface", managed: true, n: 5, f: 1.5, on: true, l: [ 1, false, "x" ], e: [] });
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
