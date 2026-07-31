let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let routes = loadfile('src/resources/network.routes.uc')();
let rules = loadfile('src/resources/network.rules.uc')();
let bv = loadfile('src/resources/network.bridge_vlans.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

t.describe('network.routes contract', () => {
	t.it('declares package, type, reload', () => {
		t.assert_equal(routes.package, "network");
		t.assert_equal(routes.type, "route");
		t.assert_deep_equal(routes.reload, ["network"]);
	});
});

t.describe('network.routes.validate', () => {
	t.it('rejects missing target', () => {
		let errs = routes.validate({ interface: 'lan' }, null);
		t.assert_equal(errs[0].field, "target");
		t.assert_equal(errs[0].code, "required");
	});
	t.it('rejects malformed target', () => {
		let errs = routes.validate({ target: '999.0.0.0/24' }, null);
		let te = filter(errs, function(e) { return e.field == "target"; });
		t.assert_equal(te[0].code, "invalid_format");
	});
	t.it('rejects bad gateway', () => {
		let errs = routes.validate({ target: '10.0.0.0/24', gateway: 'foo' }, null);
		let ge = filter(errs, function(e) { return e.field == "gateway"; });
		t.assert_equal(ge[0].code, "invalid_format");
	});
	t.it('accepts a blackhole route without interface', () => {
		let errs = routes.validate({ target: '10.0.0.0/24', type: 'blackhole' }, null);
		t.assert_equal(length(errs), 0);
	});
	t.it('reports conflict when interface does not exist', () => {
		let conn = ubus.stub({ uci: { network: {
			lan: { '.type': 'interface', proto: 'static' },
		} } });
		let errs = routes.validate({ target: '10.0.0.0/24', interface: 'wan' }, conn);
		let ie = filter(errs, function(e) { return e.field == "interface"; });
		t.assert_equal(ie[0].code, "conflict");
	});
});

t.describe('network.routes.toUci stringifies ints', () => {
	t.it('writes metric and mtu as strings', () => {
		let u = routes.toUci({ target: '10.0.0.0/24', interface: 'lan',
		                       metric: 100, mtu: 1500, table: 42 });
		t.assert_equal(u.metric, "100");
		t.assert_equal(u.mtu, "1500");
		t.assert_equal(u.table, "42");
	});
});

t.describe('network.rules contract', () => {
	t.it('declares package, type, reload', () => {
		t.assert_equal(rules.package, "network");
		t.assert_equal(rules.type, "rule");
		t.assert_deep_equal(rules.reload, ["network"]);
	});
});

t.describe('network.rules.validate', () => {
	t.it('rejects body with no selectors', () => {
		let errs = rules.validate({}, null);
		t.assert_equal(errs[0].code, "required");
	});

	// Verified against netifd: a rule carrying only mark/lookup/priority
	// installs as `from all fwmark 0x43 lookup 43`, so requiring a source
	// alongside it rejected working configuration and forced the caller to
	// write `src: "0.0.0.0/0"`, which is what a mark-only rule already means.
	t.it('accepts a mark as the only selector', () => {
		let errs = rules.validate({ mark: '0x43', lookup: 43, priority: 29000 }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('still rejects a body carrying only non-selector fields', () => {
		let errs = rules.validate({ lookup: 43, priority: 29000 }, null);
		t.assert_equal(filter(errs, function(e) { return e.code == "required"; })[0].field, "");
	});

	t.it('treats an empty mark as absent, like the other selectors', () => {
		let errs = rules.validate({ mark: '', lookup: 43 }, null);
		t.assert_equal(filter(errs, function(e) { return e.code == "required"; })[0].code, "required");
	});
	t.it('rejects priority out of range', () => {
		let errs = full_validate(rules, { src: '192.168.1.0/24', priority: 99999, lookup: 42 }, null);
		let pe = filter(errs, function(e) { return e.field == "priority"; });
		t.assert_equal(pe[0].code, "out_of_range");
	});
	t.it('requires lookup when action is lookup (default)', () => {
		let errs = rules.validate({ src: '192.168.1.0/24' }, null);
		let le = filter(errs, function(e) { return e.field == "lookup"; });
		t.assert_equal(le[0].code, "required");
	});
	t.it('rejects bad action enum', () => {
		let errs = full_validate(rules, { src: '192.168.1.0/24', action: 'bogus' }, null);
		let ae = filter(errs, function(e) { return e.field == "action"; });
		t.assert_equal(ae[0].code, "not_in_enum");
	});
	t.it('accepts a valid PBR rule', () => {
		let errs = rules.validate({
			src: '192.168.10.0/24', lookup: '42', priority: 30000,
		}, null);
		t.assert_equal(length(errs), 0);
	});
});

t.describe('network.bridge_vlans contract', () => {
	t.it('declares package, type, reload', () => {
		t.assert_equal(bv.package, "network");
		t.assert_equal(bv.type, "bridge-vlan");
		t.assert_deep_equal(bv.reload, ["network"]);
	});
});

t.describe('network.bridge_vlans.validate', () => {
	t.it('rejects vlan out of range', () => {
		let errs = full_validate(bv, { device: 'br-lan', vlan: 5000 }, null);
		let ve = filter(errs, function(e) { return e.field == "vlan"; });
		t.assert_equal(ve[0].code, "out_of_range");
	});
	t.it('rejects bad port spec', () => {
		let errs = full_validate(bv, { device: 'br-lan', vlan: 10, ports: ['eth0:x'] }, null);
		let pe = filter(errs, function(e) { return match(e.field, /^ports\[/); });
		t.assert_equal(pe[0].code, "invalid_format");
	});
	t.it('reports conflict when bridge does not exist', () => {
		let conn = ubus.stub({ uci: { network: {} } });
		let errs = bv.validate({ device: 'br-lan', vlan: 10 }, conn);
		let de = filter(errs, function(e) { return e.field == "device"; });
		t.assert_equal(de[0].code, "conflict");
	});
	t.it('accepts a valid bridge VLAN', () => {
		let conn = ubus.stub({ uci: { network: {
			lanbr: { '.type': 'device', name: 'br-lan', type: 'bridge' },
		} } });
		let errs = bv.validate({ device: 'br-lan', vlan: 10, ports: ['eth0:t'] }, conn);
		t.assert_equal(length(errs), 0);
	});
});
