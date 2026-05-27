let t = require('harness');
let ubus = require('ubus');
let rules = loadfile('src/resources/firewall.rules.uc')();

t.describe('firewall.rules contract', () => {
	t.it('declares package, type, and reload services', () => {
		t.assert_equal(rules.package, "firewall");
		t.assert_equal(rules.type, "rule");
		t.assert_deep_equal(rules.reload, ["firewall"]);
	});
});

t.describe('firewall.rules.fromUci', () => {
	t.it('renders an anonymous section as managed=false', () => {
		let r = rules.fromUci({
			'.name': 'cfg0123',
			'.anonymous': true,
			'.type': 'rule',
			target: 'ACCEPT',
			src: 'wan',
		});
		t.assert_equal(r.id, 'cfg0123');
		t.assert_false(r.managed);
		t.assert_equal(r.match.src_zone, 'wan');
		t.assert_equal(r.target, 'ACCEPT');
	});

	t.it('renders a named section as managed=true', () => {
		let r = rules.fromUci({
			'.name': 'r_01hx',
			'.anonymous': false,
			'.type': 'rule',
			target: 'DROP',
			src: 'wan',
		});
		t.assert_equal(r.id, 'r_01hx');
		t.assert_true(r.managed);
	});

	t.it('normalizes uci boolean strings to JSON booleans', () => {
		let on = rules.fromUci({
			'.name': 'r1', '.anonymous': false, '.type': 'rule',
			enabled: '1',
		});
		let off = rules.fromUci({
			'.name': 'r2', '.anonymous': false, '.type': 'rule',
			enabled: 'off',
		});
		let default_on = rules.fromUci({
			'.name': 'r3', '.anonymous': false, '.type': 'rule',
		});
		t.assert_true(on.enabled);
		t.assert_false(off.enabled);
		t.assert_true(default_on.enabled);
	});

	t.it('lifts single-value list options to arrays', () => {
		let r = rules.fromUci({
			'.name': 'r1', '.anonymous': false, '.type': 'rule',
			proto: 'tcp',
			dest_port: '22',
		});
		t.assert_deep_equal(r.match.proto, ['tcp']);
		t.assert_deep_equal(r.match.dest_port, ['22']);
	});

	t.it('passes through multi-value list options', () => {
		let r = rules.fromUci({
			'.name': 'r1', '.anonymous': false, '.type': 'rule',
			proto: ['tcp', 'udp'],
			src_ip: ['10.0.0.0/8', '192.168.0.0/16'],
		});
		t.assert_deep_equal(r.match.proto, ['tcp', 'udp']);
		t.assert_deep_equal(r.match.src_ip, ['10.0.0.0/8', '192.168.0.0/16']);
	});

	t.it('defaults family to any', () => {
		let r = rules.fromUci({
			'.name': 'r1', '.anonymous': false, '.type': 'rule',
		});
		t.assert_equal(r.match.family, 'any');
	});

	t.it('emits an empty runtime block', () => {
		let r = rules.fromUci({ '.name': 'r1', '.anonymous': false, '.type': 'rule' });
		t.assert_deep_equal(r.runtime, {});
	});
});

t.describe('firewall.rules.toUci', () => {
	t.it('converts curated JSON to uci option dict', () => {
		let u = rules.toUci({
			name: 'Allow-SSH',
			target: 'ACCEPT',
			enabled: true,
			match: {
				src_zone: 'wan',
				dest_port: ['22'],
				proto: ['tcp'],
				family: 'any',
			},
		});
		t.assert_equal(u.name, 'Allow-SSH');
		t.assert_equal(u.target, 'ACCEPT');
		t.assert_equal(u.enabled, '1');
		t.assert_equal(u.src, 'wan');
		t.assert_deep_equal(u.dest_port, ['22']);
		t.assert_deep_equal(u.proto, ['tcp']);
	});

	t.it('omits family when set to any', () => {
		let u = rules.toUci({ target: 'ACCEPT', match: { src_zone: 'lan', family: 'any' } });
		t.assert_equal(u.family, null);
	});

	t.it('preserves family when set to ipv6', () => {
		let u = rules.toUci({ target: 'ACCEPT', match: { src_zone: 'lan', family: 'ipv6' } });
		t.assert_equal(u.family, 'ipv6');
	});

	t.it('emits 0 for false enabled', () => {
		let u = rules.toUci({ target: 'DROP', enabled: false, match: { src_zone: 'wan' } });
		t.assert_equal(u.enabled, '0');
	});

	t.it('omits empty list options', () => {
		let u = rules.toUci({ target: 'DROP', match: { src_zone: 'wan', proto: [], src_ip: [] } });
		t.assert_equal(u.proto, null);
		t.assert_equal(u.src_ip, null);
	});
});

t.describe('firewall.rules round-trip', () => {
	t.it('fromUci then toUci recovers the canonical uci shape', () => {
		let section = {
			'.name': 'r_01hx', '.anonymous': false, '.type': 'rule',
			name: 'Allow-SSH', target: 'ACCEPT', enabled: '1',
			src: 'wan', dest_port: '22', proto: ['tcp'],
		};
		let json = rules.fromUci(section);
		let u = rules.toUci(json);
		t.assert_equal(u.src, 'wan');
		t.assert_equal(u.target, 'ACCEPT');
		t.assert_deep_equal(u.dest_port, ['22']);
		t.assert_deep_equal(u.proto, ['tcp']);
	});
});

t.describe('firewall.rules.validate, required fields', () => {
	t.it('rejects body that is not an object', () => {
		let errs = rules.validate(null, null);
		t.assert_equal(length(errs), 1);
		t.assert_equal(errs[0].code, "invalid_type");
	});

	t.it('rejects missing target', () => {
		let errs = rules.validate({ match: { src_zone: 'wan' } }, null);
		let target_errs = filter(errs, function(e) { return e.field == "target"; });
		t.assert_equal(length(target_errs), 1);
		t.assert_equal(target_errs[0].code, "required");
	});

	t.it('rejects missing src_zone', () => {
		let errs = rules.validate({ target: 'ACCEPT', match: {} }, null);
		let zone_errs = filter(errs, function(e) { return e.field == "match.src_zone"; });
		t.assert_equal(length(zone_errs), 1);
		t.assert_equal(zone_errs[0].code, "required");
	});

	t.it('reports all field errors together (not fail-fast)', () => {
		let errs = rules.validate({}, null);
		t.assert_true(length(errs) >= 2);
	});
});

t.describe('firewall.rules.validate, enums', () => {
	t.it('rejects unknown target', () => {
		let errs = rules.validate({ target: 'WHATEVER', match: { src_zone: 'wan' } }, null);
		let te = filter(errs, function(e) { return e.field == "target"; });
		t.assert_equal(te[0].code, "not_in_enum");
	});

	t.it('rejects unknown family', () => {
		let errs = rules.validate(
			{ target: 'ACCEPT', match: { src_zone: 'wan', family: 'ipxx' } }, null);
		let fe = filter(errs, function(e) { return e.field == "match.family"; });
		t.assert_equal(fe[0].code, "not_in_enum");
	});

	t.it('rejects unknown protocol with the position in the field path', () => {
		let errs = rules.validate(
			{ target: 'ACCEPT', match: { src_zone: 'wan', proto: ['tcp', 'bogus'] } },
			null);
		let pe = filter(errs, function(e) { return match(e.field, /match\.proto\[/); });
		t.assert_equal(length(pe), 1);
		t.assert_equal(pe[0].field, "match.proto[1]");
		t.assert_equal(pe[0].code, "not_in_enum");
	});
});

t.describe('firewall.rules.validate, cross-references', () => {
	t.it('reports conflict when src_zone does not exist', () => {
		let conn = ubus.stub({
			uci: { firewall: { z_lan: { '.type': 'zone', name: 'lan' } } }
		});
		let errs = rules.validate({ target: 'ACCEPT', match: { src_zone: 'wan' } }, conn);
		let se = filter(errs, function(e) { return e.field == "match.src_zone" && e.code == "conflict"; });
		t.assert_equal(length(se), 1);
	});

	t.it('accepts existing src_zone', () => {
		let conn = ubus.stub({
			uci: { firewall: { z_lan: { '.type': 'zone', name: 'lan' } } }
		});
		let errs = rules.validate({ target: 'ACCEPT', match: { src_zone: 'lan' } }, conn);
		t.assert_equal(length(errs), 0);
	});

	t.it('reports conflict for unknown dest_zone too', () => {
		let conn = ubus.stub({
			uci: { firewall: { z_lan: { '.type': 'zone', name: 'lan' } } }
		});
		let errs = rules.validate(
			{ target: 'ACCEPT', match: { src_zone: 'lan', dest_zone: 'dmz' } }, conn);
		let de = filter(errs, function(e) { return e.field == "match.dest_zone" && e.code == "conflict"; });
		t.assert_equal(length(de), 1);
	});
});
