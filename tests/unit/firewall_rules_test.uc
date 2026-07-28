let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let rules = loadfile('src/resources/firewall.rules.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

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

	// fw4 demands a named source zone only for NOTRACK, whose chain name is
	// derived from it; every other target is valid without one.
	t.it('rejects missing src_zone for NOTRACK', () => {
		let errs = rules.validate({ target: 'NOTRACK', match: {} }, null);
		let zone_errs = filter(errs, function(e) { return e.field == "match.src_zone"; });
		t.assert_equal(length(zone_errs), 1);
		t.assert_equal(zone_errs[0].code, "required");
	});

	t.it('rejects a wildcard src_zone for NOTRACK', () => {
		let errs = rules.validate({ target: 'NOTRACK', match: { src_zone: '*' } }, null);
		let zone_errs = filter(errs, function(e) { return e.field == "match.src_zone"; });
		t.assert_equal(length(zone_errs), 1);
	});

	t.it('accepts a missing or wildcard src_zone for other targets', () => {
		t.assert_equal(length(rules.validate({ target: 'ACCEPT', match: {} }, null)), 0);
		t.assert_equal(length(rules.validate({ target: 'ACCEPT', match: { src_zone: '*' } }, null)), 0);
	});

	t.it('reports all field errors together (not fail-fast)', () => {
		let errs = rules.validate({ target: 'MARK', set_dscp: 'EF', match: {} }, null);
		t.assert_true(length(errs) >= 2);
	});
});

t.describe('firewall.rules.validate, enums', () => {
	t.it('rejects unknown target', () => {
		let errs = full_validate(rules, { target: 'WHATEVER', match: { src_zone: 'wan' } }, null);
		let te = filter(errs, function(e) { return e.field == "target"; });
		t.assert_equal(te[0].code, "not_in_enum");
	});

	t.it('rejects unknown family', () => {
		let errs = full_validate(rules,
			{ target: 'ACCEPT', match: { src_zone: 'wan', family: 'ipxx' } }, null);
		let fe = filter(errs, function(e) { return e.field == "match.family"; });
		t.assert_equal(fe[0].code, "not_in_enum");
	});

	// An unresolvable name still parses in fw4 and then reaches nft as a
	// literal, which fails the whole ruleset, so it has to be caught here.
	t.it('rejects unknown protocol with the position in the field path', () => {
		let errs = full_validate(rules,
			{ target: 'ACCEPT', match: { src_zone: 'wan', proto: ['tcp', 'bogus'] } },
			null);
		let pe = filter(errs, function(e) { return match(e.field, /match\.proto\[/); });
		t.assert_equal(length(pe), 1);
		t.assert_equal(pe[0].field, "match.proto[1]");
		t.assert_equal(pe[0].code, "invalid_format");
	});

	t.it('accepts the protocols fw4 resolves that a closed enum would miss', () => {
		for (let v in ['gre', 'sctp', '47', 'tcpudp', 'ipv6-icmp', 'ipencap']) {
			let errs = full_validate(rules,
				{ target: 'ACCEPT', match: { src_zone: 'wan', proto: [v] } }, null);
			t.assert_equal(length(errs), 0);
		}
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

t.describe('firewall.rules mark / DSCP', () => {
	t.it('round-trips the set_* and match fields', () => {
		let section = {
			'.name': 'r1', '.anonymous': false, '.type': 'rule',
			target: 'MARK', src: 'lan', dest: '*', set_mark: '0x43',
			mark: '!0x1/0xff', dscp: 'EF',
		};
		let json = rules.fromUci(section);
		t.assert_equal(json.set_mark, '0x43');
		t.assert_equal(json.match.mark, '!0x1/0xff');
		t.assert_equal(json.match.dscp, 'EF');

		let u = rules.toUci(json);
		t.assert_equal(u.set_mark, '0x43');
		t.assert_equal(u.mark, '!0x1/0xff');
		t.assert_equal(u.dscp, 'EF');
	});

	t.it('reads absent fields as null and omits them on write', () => {
		let json = rules.fromUci({ '.name': 'r1', '.anonymous': false, '.type': 'rule' });
		for (let f in ['set_mark', 'set_xmark', 'set_dscp'])
			t.assert_equal(json[f], null);
		for (let f in ['mark', 'dscp'])
			t.assert_equal(json.match[f], null);

		let u = rules.toUci({ target: 'ACCEPT', match: {} });
		for (let f in ['set_mark', 'set_xmark', 'set_dscp', 'mark', 'dscp'])
			t.assert_equal(u[f], null);
	});

	t.it('accepts the DSCP target', () => {
		for (let c in [{ target: 'DSCP', set_dscp: 'CS0' }]) {
			c.match = { src_zone: 'lan' };
			let te = filter(full_validate(rules, c, null),
			                function(e) { return e.field == "target"; });
			t.assert_equal(length(te), 0);
		}
	});

	// Each of these validates clean today and is then silently discarded by
	// fw4, which is the defect the coupling rules exist to surface.
	t.it('requires a mark value when target is MARK', () => {
		let errs = rules.validate({ target: 'MARK', match: { src_zone: 'lan' } }, null);
		let e = filter(errs, function(x) { return x.field == "set_mark"; });
		t.assert_equal(e[0].code, "required");
	});

	t.it('rejects set_mark and set_xmark together', () => {
		let errs = rules.validate(
			{ target: 'MARK', set_mark: '0x1', set_xmark: '0x2', match: { src_zone: 'lan' } }, null);
		let e = filter(errs, function(x) { return x.field == "set_xmark"; });
		t.assert_equal(e[0].code, "conflict");
	});

	t.it('requires set_dscp when target is DSCP', () => {
		let d = rules.validate({ target: 'DSCP', match: { src_zone: 'lan' } }, null);
		t.assert_equal(filter(d, function(x) { return x.field == "set_dscp"; })[0].code, "required");
	});

	t.it('rejects a set_* value on a target that ignores it', () => {
		for (let c in [{ f: 'set_mark', v: '0x1' }, { f: 'set_dscp', v: 'EF' }]) {
			let body = { target: 'ACCEPT', match: { src_zone: 'lan' } };
			body[c.f] = c.v;
			let e = filter(rules.validate(body, null), function(x) { return x.field == c.f; });
			t.assert_equal(e[0].code, "conflict");
		}
	});

	t.it('rejects malformed and negated set values via the schema pattern', () => {
		for (let v in ['2a', '!0x1']) {
			let errs = full_validate(rules,
				{ target: 'MARK', set_mark: v, match: { src_zone: 'lan' } }, null);
			let e = filter(errs, function(x) { return x.field == "set_mark" && x.code == "invalid_format"; });
			t.assert_equal(length(e), 1);
		}
	});

	t.it('accepts negation on the match variants', () => {
		let errs = full_validate(rules,
			{ target: 'ACCEPT', match: { src_zone: 'lan', mark: '!0x1', dscp: '!EF' } }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects values past the 32-bit mark and 63 DSCP ceilings', () => {
		let m = rules.validate({ target: 'MARK', set_mark: '4294967296', match: { src_zone: 'lan' } }, null);
		t.assert_equal(filter(m, function(x) { return x.field == "set_mark"; })[0].code, "out_of_range");
		let d = rules.validate({ target: 'DSCP', set_dscp: '64', match: { src_zone: 'lan' } }, null);
		t.assert_equal(filter(d, function(x) { return x.field == "set_dscp"; })[0].code, "out_of_range");
	});

	// fw4 accepts these; LuCI's stricter form does not. We follow fw4 so a
	// value the box applies is never rejected at the API.
	t.it('accepts fw4 spellings LuCI rejects', () => {
		for (let v in ['LE', 'ef']) {
			let errs = full_validate(rules,
				{ target: 'DSCP', set_dscp: v, match: { src_zone: 'lan' } }, null);
			t.assert_equal(length(errs), 0);
		}
	});
});

t.describe('firewall.rules fw4 fidelity', () => {
	// fw4's parse_zone_ref knows exactly one wildcard, '*'. Treating 'any' as a
	// synonym both skipped the existence check and let fw4 discard the section.
	t.it('treats only * as a wildcard zone', () => {
		let conn = ubus.stub({ uci: { firewall: { z: { '.type': 'zone', name: 'lan' } } } });
		t.assert_equal(length(rules.validate({ target: 'ACCEPT', match: { src_zone: '*' } }, conn)), 0);
		let e = filter(rules.validate({ target: 'ACCEPT', match: { src_zone: 'any' } }, conn),
		               function(x) { return x.field == "match.src_zone"; });
		t.assert_equal(e[0].code, "conflict");
	});

	t.it('rejects ports and addresses fw4 would discard', () => {
		for (let c in [{ f: 'dest_port', v: '70000' }, { f: 'dest_port', v: '90-80' },
		               { f: 'src_ip', v: '10.0.0.256' }, { f: 'dest_ip', v: 'not an ip' }]) {
			let body = { target: 'ACCEPT', match: { src_zone: 'lan' } };
			body.match[c.f] = [c.v];
			let e = filter(rules.validate(body, null),
			               function(x) { return match(x.field, /^match\./) && x.field != "match.src_zone"; });
			t.assert_true(length(e) >= 1);
		}
	});

	t.it('accepts the port and address forms fw4 resolves', () => {
		let errs = rules.validate({ target: 'ACCEPT', match: {
			src_zone: 'lan', dest_port: ['1000:2000', '!22'],
			src_ip: ['10.0.0.0/8', '2001:db8::/32', 'lan', '10.0.0.1-10.0.0.9'],
		} }, null);
		t.assert_equal(length(errs), 0);
	});
});

// fw4 assigns src_port and dest_port only inside `case "tcp": case "udp":`, so
// a port beside any other protocol is dropped and the rule still emitted,
// matching the whole protocol. A rule gets no ensure_tcpudp rewrite, so even a
// wildcard loses its ports: {proto: ['all'], dest_port: ['22']} on an ACCEPT
// rule renders a rule accepting everything.
t.describe('firewall.rules ports and protocol wildcards', () => {
	function gate(protos, m) {
		let body = { target: 'ACCEPT', match: { src_zone: 'lan', proto: protos, ...m } };
		return length(filter(rules.validate(body, null),
		                     function(x) { return x.field == "match.proto"; })) == 0;
	}

	t.it('refuses a port beside any protocol that would lose it', () => {
		for (let p in [['tcp'], ['udp'], ['6'], ['17'], ['tcpudp'], ['TCP'], ['tcp', 'udp']])
			t.assert_true(gate(p, { dest_port: ['80'] }));
		for (let p in [['gre'], ['icmp'], ['esp'], ['tcp', 'gre']])
			t.assert_false(gate(p, { dest_port: ['80'] }));
	});

	// The wildcard is the worst case, not a free pass: it is the one that turns
	// a port rule into a rule matching every packet.
	t.it('refuses a wildcard with a port, since no rewrite saves it here', () => {
		for (let p in [['all'], ['any'], ['*']]) {
			t.assert_false(gate(p, { dest_port: ['80'] }));
			t.assert_false(gate(p, { src_port: ['80'] }));
			t.assert_true(gate(p, {}));
		}
	});

	t.it('leaves a protocol alone when no port is matched', () => {
		for (let p in [['gre'], ['icmp'], ['tcp', 'gre']])
			t.assert_true(gate(p, {}));
	});

	// An absent proto is [] and fw4 defaults it to tcpudp, which carries ports.
	t.it('accepts a port with no protocol at all', () => {
		t.assert_equal(length(rules.validate({ target: 'ACCEPT',
			match: { src_zone: 'lan', dest_port: ['22'] } }, null)), 0);
	});

	// An unresolvable token does not widen a rule, it makes nft reject the whole
	// ruleset, so reporting the port conflict on top of it would describe the
	// wrong failure.
	t.it('stays quiet about ports when the protocol itself does not parse', () => {
		let errs = rules.validate({ target: 'ACCEPT',
			match: { src_zone: 'lan', proto: ['bogus'], dest_port: ['80'] } }, null);
		t.assert_equal(length(filter(errs, function(x) { return x.field == "match.proto[0]"; })), 1);
		t.assert_equal(length(filter(errs, function(x) { return x.field == "match.proto"; })), 0);
	});
});

t.describe('firewall.rules empty values', () => {
	// fw4 cannot resolve an empty zone ref, port or address, and discards the
	// whole section over one, so none may reach uci.
	t.it('never writes an empty zone reference', () => {
		let u = rules.toUci({ target: 'ACCEPT', match: { src_zone: '', dest_zone: '' } });
		t.assert_equal(u.src, null);
		t.assert_equal(u.dest, null);
	});

	t.it('rejects an empty port or address element', () => {
		for (let f in ['src_port', 'dest_port', 'src_ip', 'dest_ip']) {
			let body = { target: 'ACCEPT', match: { src_zone: 'lan' } };
			body.match[f] = [''];
			let e = filter(rules.validate(body, null), function(x) { return x.field == "match." + f + "[0]"; });
			t.assert_equal(e[0].code, "invalid_format");
		}
	});
});
