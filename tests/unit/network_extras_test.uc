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

// netifd drops a boolean it cannot parse and falls back to its own default, so a
// read has to report what netifd will do rather than what the operator wrote.
// `option auto 'no'` used to read back as false while the interface autostarted.
t.describe('network.interfaces netifd boolean fidelity', () => {
	let ifaces = loadfile('src/resources/network.interfaces.uc')();
	function auto_of(val) {
		let s = { '.name': 'lan', '.anonymous': false, proto: 'static' };
		if (val != null) s.auto = val;
		return ifaces.fromUci(s, null).auto;
	}

	t.it('honours the spellings netifd accepts', () => {
		t.assert_equal(auto_of('0'), false);
		t.assert_equal(auto_of('false'), false);
		t.assert_equal(auto_of('1'), true);
		t.assert_equal(auto_of('true'), true);
	});

	t.it('reports the netifd default for a value netifd drops', () => {
		t.assert_equal(auto_of('no'), true);
		t.assert_equal(auto_of('off'), true);
		t.assert_equal(auto_of('disabled'), true);
	});

	t.it('still defaults to true when the option is absent', () => {
		t.assert_equal(auto_of(null), true);
	});
});

// A wireguard tunnel's own address list is routinely v6 or dual-stack and netifd parses
// either, but this field was validated with the v4-only CIDR check, so no v6-only or
// dual-stack tunnel could be configured through the API. Same class as the allowed_ips
// fix in 2.4.1, which missed the interface's own addresses.
t.describe('network.interfaces wireguard addresses accept both families', () => {
	let ifaces = loadfile('src/resources/network.interfaces.uc')();
	const WG = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
	function addr_errs(addresses) {
		let errs = ifaces.validate({ proto: 'wireguard', private_key: WG,
		                             addresses: addresses }, null) ?? [];
		return filter(errs, function(e) { return substr(e.field, 0, 9) == "addresses"; });
	}

	t.it('accepts an IPv6 CIDR', () => {
		t.assert_deep_equal(addr_errs(['fd00::1/64']), []);
	});

	t.it('accepts a dual-stack list', () => {
		t.assert_deep_equal(addr_errs(['10.9.0.1/24', 'fd00::1/64']), []);
	});

	t.it('still accepts IPv4 and still rejects nonsense', () => {
		t.assert_deep_equal(addr_errs(['10.9.0.1/24']), []);
		t.assert_equal(length(addr_errs(['not-an-address'])), 1);
	});

	// The static-proto v4 fields must not have been widened along with it.
	t.it('leaves ipaddrs IPv4-only', () => {
		let errs = ifaces.validate({ proto: 'static', ipaddrs: ['fd00::1/64'] }, null) ?? [];
		let found = false;
		for (let e in errs) if (e.field == "ipaddrs[0]" && e.code == "invalid_format") found = true;
		t.assert_true(found);
	});

	// validate() indexed the string, which faults, so the write answered 500 instead of the
	// invalid_type that the schema check had found.
	t.it('takes an address list sent as a string without faulting', () => {
		t.assert_true(length(ifaces.validate({ proto: 'static', ipaddrs: '10.0.0.1/24' }, null)) > 0);
		t.assert_true(length(ifaces.validate({ proto: 'static', ip6addrs: 'fd00::1/64' }, null)) > 0);
	});
});

// The resource-level dns guard was deleted because its condition
// (!is_valid_ipv4(x) && type(x) != "string") could only ever fire for a non-string,
// which the central items:{type:"string"} check already rejects with a better message.
// This is the assertion that makes that deletion safe to have made.
t.describe('network.interfaces dns items stay type-checked centrally', () => {
	let handler = require('handler');
	let ifaces = loadfile('src/resources/network.interfaces.uc')();

	t.it('rejects a non-string dns entry', () => {
		let errs = handler.check_schema_types(ifaces.schema_properties,
		                                     { proto: 'static', dns: [42] });
		let found = false;
		for (let e in errs)
			if (e.field == "dns[0]" && e.code == "invalid_type") found = true;
		t.assert_true(found);
	});

	t.it('accepts a string dns entry', () => {
		let errs = handler.check_schema_types(ifaces.schema_properties,
		                                     { proto: 'static', dns: ['1.1.1.1'] });
		t.assert_equal(length(errs), 0);
	});
});

// netifd does not parse `disabled` the same way on all three section types. The interface
// flag is compared literally against "1"; route and rule go through the boolean blob
// converter, which also accepts "true". Measured on 25.12.5 against a reset baseline:
// `disabled 'true'` removes a route and leaves an interface registered and running.
//
// So the two helpers here are not an inconsistency to tidy up. Unifying them puts the lie
// back, in whichever direction it is unified: the wide helper reports an interface disabled
// while it is up, the narrow one reports a route active while it is gone.
t.describe('disabled follows each section type parser, which differ', () => {
	let ifaces = loadfile('src/resources/network.interfaces.uc')();
	let conn = ubus.stub({ uci: {} });

	t.it('an interface honours only "1", because netifd compares it literally', () => {
		t.assert_true(ifaces.fromUci({ '.name': 'w', proto: 'static', disabled: '1' }, conn).disabled);
		for (let v in ['true', 'on', 'yes', '0', 'false'])
			t.assert_false(ifaces.fromUci({ '.name': 'w', proto: 'static', disabled: v }, conn).disabled);
		t.assert_false(ifaces.fromUci({ '.name': 'w', proto: 'static' }, conn).disabled);
	});

	t.it('a route and a rule also honour "true", via the blob converter', () => {
		for (let r in [routes, rules]) {
			t.assert_true(r.fromUci({ '.name': 'x', disabled: '1' }).disabled);
			t.assert_true(r.fromUci({ '.name': 'x', disabled: 'true' }).disabled);
			for (let v in ['on', 'yes', '0', 'false'])
				t.assert_false(r.fromUci({ '.name': 'x', disabled: v }).disabled);
			t.assert_false(r.fromUci({ '.name': 'x' }).disabled);
		}
	});
});

// netifd reads these through uci's blob.c (strtol base 0, scalar lists split into words) and
// resolves table names itself. Only aliases and numbers here: rt_tables differs per box.
t.describe('network routes, rules and bridge_vlans read as netifd does', () => {
	t.it('routes read hex integers and table aliases, and 0 for a table netifd cannot resolve', () => {
		let r = routes.fromUci({ '.name': 'r', '.type': 'route', target: '10.0.0.0/24', metric: '0x10',
			mtu: '0x5dc', table: 'local' }, null);
		t.assert_equal(r.metric, 16);
		t.assert_equal(r.mtu, 1500);
		t.assert_equal(r.table, 255);
		t.assert_equal(routes.fromUci({ '.name': 'r', '.type': 'route', table: '0x2a' }, null).table, 42);
		t.assert_equal(routes.fromUci({ '.name': 'r', '.type': 'route', table: 'uapi-no-such-table' }, null).table, 0);
		t.assert_equal(routes.fromUci({ '.name': 'r', '.type': 'route' }, null).table, null);
	});
	t.it('routes refuse table 0 as out of range', () => {
		let errs = filter(full_validate(routes, { target: '10.0.0.0/24', type: 'blackhole', table: 0 }, null),
		                  (e) => e.field == 'table');
		t.assert_deep_equal(map(errs, (e) => e.code), [ 'out_of_range' ]);
	});
	t.it('rules read hex integers and lookup aliases, and refuse lookup 0 without calling it required', () => {
		let r = rules.fromUci({ '.name': 'x', '.type': 'rule', src: '10.0.0.0/24', priority: '0x7531',
			lookup: 'main', 'goto': '010' }, null);
		t.assert_equal(r.priority, 30001);
		t.assert_equal(r.lookup, 254);
		t.assert_equal(r['goto'], 8);
		let errs = filter(rules.validate({ src: '10.0.0.0/24', lookup: 0 }, null), (e) => e.field == 'lookup');
		t.assert_deep_equal(map(errs, (e) => e.code), [ 'out_of_range' ]);
	});
	t.it('bridge_vlans read a hex vlan and a scalar ports list as words', () => {
		let v = bv.fromUci({ '.name': 'v', '.type': 'bridge-vlan', device: 'br-x', vlan: '0x0a',
			ports: 'lan1:t lan2:u*' }, null);
		t.assert_equal(v.vlan, 10);
		t.assert_deep_equal(v.ports, [ 'lan1:t', 'lan2:u*' ]);
	});
});

t.describe('network routes and rules through the handler', () => {
	let tx = { tx: {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	} };
	let rh = handler.make(routes, tx);
	let ruh = handler.make(rules, tx);
	let ctx = () => ({ request_id: "01hx000000000000000000rtid" });
	function seeded(route_table, rule_lookup) {
		return ubus.stub({ uci: { network: {
			r1: { '.type': 'route', '.anonymous': false, target: '10.9.0.0/24', type: 'blackhole',
			      metric: '7', table: route_table },
			n1: { '.type': 'rule', '.anonymous': false, src: '10.9.0.0/24', lookup: rule_lookup },
		} } });
	}
	t.it('a PATCH keeps a stored table name, and a PUT of the read writes its id', () => {
		let c = seeded('local', 'main');
		t.assert_equal(rh.patch(c, ctx(), 'r1', { metric: 5 }).status, 200);
		t.assert_equal(c._state.uci.network.r1.table, 'local');
		let read = rh.get_one(c, ctx(), 'r1').body;
		delete read.runtime;
		t.assert_equal(rh.replace(c, ctx(), 'r1', read).status, 200);
		t.assert_equal(c._state.uci.network.r1.table, '255');
	});
	t.it('a rule with lookup main accepts a PATCH', () => {
		let c = seeded('local', 'main');
		t.assert_equal(ruh.patch(c, ctx(), 'n1', { priority: 100 }).status, 200);
		t.assert_equal(c._state.uci.network.n1.lookup, 'main');
	});
	t.it('a table netifd cannot resolve blocks a PUT of the read and is swept, rather than moving the route', () => {
		let c = seeded('uapi-no-such-table', 'main');
		let read = rh.get_one(c, ctx(), 'r1').body;
		delete read.runtime;
		let r = rh.replace(c, ctx(), 'r1', read);
		t.assert_equal(r.status, 422);
		t.assert_deep_equal(map(filter(r.body.errors, (e) => e.field == 'table'), (e) => e.code), [ 'out_of_range' ]);
		t.assert_equal(c._state.uci.network.r1.table, 'uapi-no-such-table');
		t.assert_equal(length(rh.sweep(c)), 1);
	});
});

// netifd's action parser knows neither lookup nor goto, and drops a rule whose action it cannot
// read: a goto rule is one with a goto and no action. Measured on OpenWrt 25.12.5.
t.describe('network.rules derives the action as netifd does', () => {
	let read = (sec) => rules.fromUci({ '.name': 'x', '.type': 'rule', src: '10.0.0.0/24', ...sec }).action;
	t.it('reads a rule with a goto and no action as goto, and unicast as lookup', () => {
		t.assert_equal(read({ 'goto': '30030' }), 'goto');
		t.assert_equal(read({ action: 'goto', 'goto': '30030' }), 'goto');
		t.assert_equal(read({ action: 'unicast', lookup: '100' }), 'lookup');
		t.assert_equal(read({ 'goto': '30030 ' }), 'lookup');
		t.assert_equal(read({ action: 'unreachable' }), 'unreachable');
		t.assert_equal(read({}), 'lookup');
	});
	t.it('writes no action for lookup and goto, and clears a stored one', () => {
		t.assert_deep_equal(rules.toUci({ src: '10.0.0.0/24', action: 'goto', 'goto': 30030 }).action, []);
		t.assert_deep_equal(rules.toUci({ src: '10.0.0.0/24', action: 'lookup', lookup: 100 }).action, []);
		t.assert_equal(rules.toUci({ src: '10.0.0.0/24', action: 'unreachable' }).action, 'unreachable');
	});
	t.it('accepts LuCI\'s goto body, and refuses a goto beside another action or one that jumps back', () => {
		let codes = (body) => map(filter(full_validate(rules, { src: '10.0.0.0/24', ...body }, null),
		                                 (e) => e.field == 'goto'), (e) => e.code);
		t.assert_deep_equal(codes({ priority: 30020, 'goto': 30030 }), []);
		t.assert_deep_equal(codes({ action: 'lookup', lookup: 100, 'goto': 30030 }), [ 'conflict' ]);
		t.assert_deep_equal(codes({ action: 'unreachable', 'goto': 30030 }), [ 'conflict' ]);
		t.assert_deep_equal(codes({ priority: 30020, 'goto': 30010 }), [ 'out_of_range' ]);
		t.assert_deep_equal(codes({ priority: 30020, 'goto': 30020 }), [ 'out_of_range' ]);
		t.assert_deep_equal(codes({ action: 'goto', 'goto': 0 }), [ 'out_of_range' ]);
	});
});

t.describe('network.rules goto rules through the handler', () => {
	let h = handler.make(rules, { tx: {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	} });
	let ctx = () => ({ request_id: "01hx000000000000000000goto" });
	let stored = () => ubus.stub({ uci: { network: {
		g1: { '.type': 'rule', '.anonymous': false, src: '10.9.0.0/24', priority: '30020',
		      action: 'goto', 'goto': '30030' },
	} } });
	t.it('a PATCH of another field clears the stored action netifd cannot parse', () => {
		let c = stored();
		t.assert_equal(h.patch(c, ctx(), 'g1', { priority: 30021 }).status, 200);
		t.assert_equal(c._state.uci.network.g1.action, null);
		t.assert_equal(c._state.uci.network.g1['goto'], '30030');
	});
	t.it('a PUT of the read clears it too', () => {
		let c = stored();
		let read = h.get_one(c, ctx(), 'g1').body;
		delete read.runtime;
		t.assert_equal(h.replace(c, ctx(), 'g1', read).status, 200);
		t.assert_equal(c._state.uci.network.g1.action, null);
	});
	t.it('a write answers with the action and ETag of the next read', () => {
		let c = stored();
		let w = h.patch(c, ctx(), 'g1', { priority: 30021 });
		let g = h.get_one(c, ctx(), 'g1');
		t.assert_equal(w.body.action, 'goto');
		t.assert_equal(w.headers.ETag, g.headers.ETag);
	});
});
