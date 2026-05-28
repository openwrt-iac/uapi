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
		t.assert_deep_equal(raw.inferred_domain_path("dropbear", "dropbear"),
		                    ["dropbear"]);
		t.assert_deep_equal(raw.inferred_domain_path("openvpn", "openvpn"),
		                    ["openvpn"]);
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
