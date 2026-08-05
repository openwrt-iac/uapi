let t = require('harness');
let hosts = loadfile('src/resources/dhcp.hosts.uc')();

t.describe('dhcp.hosts contract', () => {
	t.it('declares package, type, and reload services', () => {
		t.assert_equal(hosts.package, "dhcp");
		t.assert_equal(hosts.type, "host");
		t.assert_deep_equal(hosts.reload, ["dnsmasq"]);
	});
});

t.describe('dhcp.hosts.fromUci', () => {
	t.it('renders a named section as managed', () => {
		let r = hosts.fromUci({
			'.name': 'h_01hx', '.anonymous': false, '.type': 'host',
			name: 'printer', mac: 'aa:bb:cc:dd:ee:ff', ip: '192.168.1.50',
		});
		t.assert_equal(r.id, 'h_01hx');
		t.assert_true(r.managed);
		t.assert_equal(r.name, 'printer');
		t.assert_equal(r.mac, 'aa:bb:cc:dd:ee:ff');
		t.assert_equal(r.ip, '192.168.1.50');
	});

	t.it('renders an anonymous section as unmanaged', () => {
		let r = hosts.fromUci({
			'.name': 'cfg00', '.anonymous': true, '.type': 'host',
			mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.5',
		});
		t.assert_false(r.managed);
	});

	t.it('normalizes dns to a boolean', () => {
		let on = hosts.fromUci({ '.name': 'h1', '.anonymous': false, '.type': 'host', dns: '1' });
		let off = hosts.fromUci({ '.name': 'h2', '.anonymous': false, '.type': 'host', dns: '0' });
		t.assert_true(on.dns);
		t.assert_false(off.dns);
	});
});

t.describe('dhcp.hosts.toUci', () => {
	t.it('emits the standard host options', () => {
		let u = hosts.toUci({
			name: 'router', mac: '00:11:22:33:44:55',
			ip: '192.168.1.1', leasetime: '12h', dns: true,
		});
		t.assert_equal(u.name, 'router');
		t.assert_equal(u.mac, '00:11:22:33:44:55');
		t.assert_equal(u.ip, '192.168.1.1');
		t.assert_equal(u.leasetime, '12h');
		t.assert_equal(u.dns, '1');
	});

	t.it('omits absent fields', () => {
		let u = hosts.toUci({ mac: '00:11:22:33:44:55', ip: '10.0.0.1' });
		t.assert_equal(u.leasetime, null);
		t.assert_equal(u.tag, null);
		t.assert_equal(u.dns, null);
	});
});

t.describe('dhcp.hosts.validate', () => {
	t.it('rejects an entry with neither mac nor duid (no identifier)', () => {
		let errs = hosts.validate({ ip: '10.0.0.1' }, null);
		let me = filter(errs, function(e) { return e.field == "mac" && e.code == "required"; });
		t.assert_equal(length(me), 1);
	});

	t.it('accepts a DNS-only entry: mac + name, no ip', () => {
		let errs = hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', name: 'host.lan' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects malformed mac', () => {
		let errs = hosts.validate({ mac: 'not-a-mac', ip: '10.0.0.1' }, null);
		let me_errs = filter(errs, function(e) { return e.field == "mac"; });
		t.assert_equal(me_errs[0].code, 'invalid_format');
	});

	t.it('accepts a valid MAC', () => {
		let errs = hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects malformed IPv4', () => {
		let errs = hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', ip: '999.0.0.1' }, null);
		let ip_errs = filter(errs, function(e) { return e.field == "ip"; });
		t.assert_equal(ip_errs[0].code, 'invalid_format');
	});

	t.it('accepts an IPv6 address', () => {
		let errs = hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', ip: 'fd00::1' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects bad leasetime', () => {
		let errs = hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', leasetime: 'forever' }, null);
		let le = filter(errs, function(e) { return e.field == "leasetime"; });
		t.assert_equal(le[0].code, 'invalid_format');
	});

	t.it('accepts valid leasetime formats', () => {
		t.assert_equal(length(hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', leasetime: '12h' }, null)), 0);
		t.assert_equal(length(hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', leasetime: '1d' }, null)), 0);
		t.assert_equal(length(hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', leasetime: '3600' }, null)), 0);
	});
});

let ubus = require('bus');

t.describe('dhcp.hosts v1.2 parity additions', () => {
	t.it('fromUci returns mac_aliases empty when uci has option mac (single)', () => {
		let r = hosts.fromUci({ '.name': 'h1', '.anonymous': false,
		                        mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.5' });
		t.assert_equal(r.mac, 'aa:bb:cc:dd:ee:ff');
		t.assert_deep_equal(r.mac_aliases, []);
	});
	t.it('fromUci splits a list mac into mac + mac_aliases', () => {
		let r = hosts.fromUci({ '.name': 'h2', '.anonymous': false,
		                        mac: ['aa:bb:cc:dd:ee:ff', '11:22:33:44:55:66'],
		                        ip: '10.0.0.6' });
		t.assert_equal(r.mac, 'aa:bb:cc:dd:ee:ff');
		t.assert_deep_equal(r.mac_aliases, ['11:22:33:44:55:66']);
	});
	t.it('toUci writes a string when only mac is set, a list when aliases are present', () => {
		let single = hosts.toUci({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1' });
		t.assert_equal(single.mac, 'aa:bb:cc:dd:ee:ff');
		let multi = hosts.toUci({ mac: 'aa:bb:cc:dd:ee:ff',
		                          mac_aliases: ['11:22:33:44:55:66'], ip: '10.0.0.1' });
		t.assert_deep_equal(multi.mac, ['aa:bb:cc:dd:ee:ff', '11:22:33:44:55:66']);
	});
	t.it('validate accepts duid-only entries (DHCPv6 reservation)', () => {
		let errs = hosts.validate({
			duid: '00:01:00:01:24:24:24:24:aa:bb:cc:dd:ee:ff',
			ip: '2001:db8::42',
		}, null);
		for (let e in errs)
			t.assert_not_equal(e.field + ':' + e.code, 'mac:required');
	});
	// The bug this pins: validate returned [] for a duid-only body carrying aliases, and
	// toUci then wrote no mac option at all, so the MACs were discarded on a 200. The test
	// above ("validate accepts duid-only entries") was one field away from catching it.
	t.it('rejects mac_aliases sent without mac, rather than dropping them', () => {
		let errs = hosts.validate({
			mac_aliases: ['11:22:33:44:55:66'],
			duid: '00:01:00:01:24:24:24:24:aa:bb:cc:dd:ee:ff',
			ip: '2001:db8::42',
		}, null);
		let found = false;
		for (let e in errs)
			if (e.field == 'mac_aliases' && e.code == 'conflict') found = true;
		t.assert_true(found);
	});

	// The shape toUci cannot express, which is why the body is refused rather than written:
	// with no primary there is no first entry to build the list from.
	t.it('toUci writes no mac option when only aliases are present', () => {
		let out = hosts.toUci({ mac: null, mac_aliases: ['11:22:33:44:55:66'], ip: '10.0.0.1' });
		t.assert_equal(out.mac, null);
		t.assert_equal(out.ip, '10.0.0.1');
	});

	t.it('an empty alias list is not a conflict, since there is no orphaned tail', () => {
		let errs = hosts.validate({ mac: 'aa:bb:cc:dd:ee:ff', mac_aliases: [], ip: '10.0.0.1' }, null);
		t.assert_equal(length(errs), 0);
	});

	// Distinct fields on purpose: reported against mac it would collide with the identifier
	// error under the field|code dedup and one of the two would vanish.
	t.it('reports both the missing identifier and the orphaned aliases', () => {
		let errs = hosts.validate({ mac_aliases: ['11:22:33:44:55:66'], ip: '10.0.0.1' }, null);
		let seen = {};
		for (let e in errs) seen[e.field + '/' + e.code] = true;
		t.assert_true(seen['mac/required']);
		t.assert_true(seen['mac_aliases/conflict']);
	});

	t.it('macs alone satisfies the identifier requirement', () => {
		t.assert_equal(length(hosts.validate({ macs: ['aa:bb:cc:dd:ee:01'], ip: '10.0.0.1' },
		                                    null)), 0);
	});
	t.it('macs writes one uci list mac, and a single entry writes a scalar', () => {
		t.assert_deep_equal(hosts.toUci({ macs: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'] }).mac,
		               ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02']);
		t.assert_equal(hosts.toUci({ macs: ['aa:bb:cc:dd:ee:01'] }).mac, 'aa:bb:cc:dd:ee:01');
	});
	t.it('macs wins over the deprecated pair, so a disagreement is refused', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'],
		                            mac: 'aa:bb:cc:dd:ee:09',
		                            mac_aliases: ['aa:bb:cc:dd:ee:02'] }, null);
		t.assert_equal(length(errs), 1);
		t.assert_deep_equal(errs[0].field, 'mac');
		t.assert_deep_equal(errs[0].code, 'conflict');
	});
	t.it('a tail disagreeing with macs is refused against mac_aliases', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'],
		                            mac: 'aa:bb:cc:dd:ee:01',
		                            mac_aliases: ['aa:bb:cc:dd:ee:09'] }, null);
		t.assert_equal(length(errs), 1);
		t.assert_deep_equal(errs[0].field, 'mac_aliases');
		t.assert_deep_equal(errs[0].code, 'conflict');
	});
	t.it('a body that agrees across all three names is accepted', () => {
		t.assert_equal(length(hosts.validate({ macs: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'],
		                                      mac: 'aa:bb:cc:dd:ee:01',
		                                      mac_aliases: ['aa:bb:cc:dd:ee:02'] }, null)), 0);
	});
	t.it('bad entries inside macs are reported by index', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:01', 'not-a-mac'] }, null);
		t.assert_equal(length(errs), 1);
		t.assert_deep_equal(errs[0].field, 'macs[1]');
		t.assert_deep_equal(errs[0].code, 'invalid_format');
	});
	t.it('aliases without mac are fine when macs carries the list', () => {
		t.assert_equal(length(hosts.validate({ macs: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'],
		                                      mac_aliases: ['aa:bb:cc:dd:ee:02'] }, null)), 0);
	});

	// A PUT cannot avoid sending the stale pair beside the new list: fromUci mirrors both.
	t.it('PUT resolves a stale pair to macs rather than refusing the body', () => {
		let out = hosts.resolve_for_replace({ macs: ['aa:bb:cc:dd:ee:03'],
		                                      mac: 'aa:bb:cc:dd:ee:01',
		                                      mac_aliases: ['aa:bb:cc:dd:ee:02'] });
		t.assert_true(!exists(out, 'mac'));
		t.assert_true(!exists(out, 'mac_aliases'));
		t.assert_deep_equal(out.macs, ['aa:bb:cc:dd:ee:03']);
	});
	t.it('PUT leaves an agreeing body alone, and a legacy-only body alone', () => {
		let agree = { macs: ['aa:bb:cc:dd:ee:01'], mac: 'aa:bb:cc:dd:ee:01' };
		t.assert_equal(hosts.resolve_for_replace(agree).mac, 'aa:bb:cc:dd:ee:01');
		let legacy = { mac: 'aa:bb:cc:dd:ee:01', mac_aliases: ['aa:bb:cc:dd:ee:02'] };
		t.assert_deep_equal(hosts.resolve_for_replace(legacy).mac_aliases, ['aa:bb:cc:dd:ee:02']);
	});
	t.it('PATCH drops whichever surface the body did not name', () => {
		let read = { macs: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'],
		             mac: 'aa:bb:cc:dd:ee:01', mac_aliases: ['aa:bb:cc:dd:ee:02'] };
		let by_list = hosts.merge_for_patch(read, { macs: ['aa:bb:cc:dd:ee:03'] });
		t.assert_equal(hosts.toUci(by_list).mac, 'aa:bb:cc:dd:ee:03');
		let by_scalar = hosts.merge_for_patch(read, { mac: 'aa:bb:cc:dd:ee:03' });
		t.assert_deep_equal(hosts.toUci(by_scalar).mac,
		               ['aa:bb:cc:dd:ee:03', 'aa:bb:cc:dd:ee:02']);
	});
	t.it('a PATCH naming neither keeps the list intact', () => {
		let read = { macs: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'],
		             mac: 'aa:bb:cc:dd:ee:01', mac_aliases: ['aa:bb:cc:dd:ee:02'],
		             ip: '10.0.0.1' };
		let merged = hosts.merge_for_patch(read, { ip: '10.0.0.9' });
		t.assert_deep_equal(hosts.toUci(merged).mac,
		               ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02']);
	});
	t.it('fromUci surfaces the list and the deprecated split together', () => {
		let v = hosts.fromUci({ '.name': 'h', '.type': 'host',
		                        mac: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'] }, null);
		t.assert_deep_equal(v.macs, ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02']);
		t.assert_equal(v.mac, 'aa:bb:cc:dd:ee:01');
		t.assert_deep_equal(v.mac_aliases, ['aa:bb:cc:dd:ee:02']);
	});

	t.it('validate requires either mac or duid', () => {
		let errs = hosts.validate({ ip: '10.0.0.1' }, null);
		t.assert_equal(errs[0].field, 'mac');
		t.assert_equal(errs[0].code, 'required');
	});
	t.it('validate rejects bad mac_aliases entries', () => {
		let errs = hosts.validate({
			mac: 'aa:bb:cc:dd:ee:ff',
			mac_aliases: ['not-a-mac'],
			ip: '10.0.0.1',
		}, null);
		let found = false;
		for (let e in errs)
			if (substr(e.field, 0, 11) == 'mac_aliases'
			    && e.code == 'invalid_format') { found = true; break; }
		t.assert_true(found);
	});
	t.it('validate rejects bad duid hex', () => {
		let errs = hosts.validate({ duid: 'not-hex', ip: '10.0.0.1' }, null);
		let found = false;
		for (let e in errs)
			if (e.field == 'duid' && e.code == 'invalid_format') { found = true; break; }
		t.assert_true(found);
	});
	t.it('validate rejects bad hostid', () => {
		let errs = hosts.validate({
			mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1',
			hostid: 'zz::nope',
		}, null);
		let found = false;
		for (let e in errs)
			if (e.field == 'hostid' && e.code == 'invalid_format') { found = true; break; }
		t.assert_true(found);
	});
	t.it('validate cross-refs instance against dhcp/dnsmasq sections (NOT dhcp/servers)', () => {
		let conn = ubus.stub({ uci: { dhcp: {
			main_dnsmasq: { '.type': 'dnsmasq' },
			lan_server:   { '.type': 'dhcp', interface: 'lan' },
		}}});
		let ok = hosts.validate({
			mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', instance: 'main_dnsmasq',
		}, conn);
		let conflict_for_ok = false;
		for (let e in ok)
			if (e.field == 'instance' && e.code == 'conflict') { conflict_for_ok = true; break; }
		t.assert_false(conflict_for_ok);
		// A dhcp.dhcp section name is NOT a valid instance reference (it's the
		// per-interface server, not the dnsmasq process). Should conflict.
		let wrong = hosts.validate({
			mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', instance: 'lan_server',
		}, conn);
		let conflict_for_wrong = false;
		for (let e in wrong)
			if (e.field == 'instance' && e.code == 'conflict') { conflict_for_wrong = true; break; }
		t.assert_true(conflict_for_wrong);
	});
});

// name, tag and dns were written by toUci but absent from schema_properties, so the
// central type gate never saw them: `dns: "0"` was a truthy string in ucode and wrote
// dns=1, the inverse of the request. These assert the gate now covers them.
t.describe('dhcp.hosts central type gate covers name, tag and dns', () => {
	let handler = require('handler');
	function types(body) { return handler.check_schema_types(hosts.schema_properties, body); }
	function has(errs, field, code) {
		for (let e in errs) if (e.field == field && e.code == code) return true;
		return false;
	}

	// The inverted write: a string "0" asked for dns off and got dns=1.
	t.it('rejects a stringly-typed dns instead of coercing it', () => {
		t.assert_true(has(types({ dns: "0" }), "dns", "invalid_type"));
	});

	t.it('still accepts a real boolean dns', () => {
		t.assert_equal(length(types({ dns: false })), 0);
		t.assert_equal(length(types({ dns: true })), 0);
	});

	t.it('rejects a non-string name', () => {
		t.assert_true(has(types({ name: 123 }), "name", "invalid_type"));
	});

	t.it('accepts the null and string forms name declares', () => {
		t.assert_equal(length(types({ name: "host.lan" })), 0);
		t.assert_equal(length(types({ name: null })), 0);
	});

	// `tag` declares a union because uci genuinely holds either shape: dnsmasq
	// word-splits a scalar, so `option tag 'a b'` and `list tag` are the same
	// configuration and a string-only schema would reject what LuCI writes. The
	// union is what v3 narrows to an array.
	t.it('accepts both shapes uci can hold, and null', () => {
		t.assert_equal(length(types({ tag: ["a", "b"] })), 0);
		t.assert_equal(length(types({ tag: "a b" })), 0);
		t.assert_equal(length(types({ tag: null })), 0);
	});

	// Undeclared meant unchecked, and unchecked meant an object reached toUci and
	// was handed to uci as an option value.
	t.it('rejects shapes uci cannot hold', () => {
		t.assert_true(has(types({ tag: 123 }), "tag", "invalid_type"));
		t.assert_true(has(types({ tag: { a: 1 } }), "tag", "invalid_type"));
	});

	t.it('rejects a non-string inside the list', () => {
		t.assert_true(has(types({ tag: ["ok", 7] }), "tag[1]", "invalid_type"));
	});
});

// Writes persist the shape they were given. Normalizing a scalar into a list would
// make a body written back unchanged come back changed, which is the one thing the
// read-honesty property forbids; v3 reconciles the shapes on the read side instead.
t.describe('dhcp.hosts tag write shape', () => {
	t.it('keeps an array an array, so uci gets a list', () => {
		let u = hosts.toUci({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1',
		                      tag: ['guest', 'iot'] });
		t.assert_equal(type(u.tag), 'array');
		t.assert_equal(u.tag[0], 'guest');
		t.assert_equal(u.tag[1], 'iot');
	});

	t.it('keeps a scalar a scalar, so a verbatim round trip does not rewrite it', () => {
		let u = hosts.toUci({ mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1',
		                      tag: 'guest iot' });
		t.assert_equal(type(u.tag), 'string');
		t.assert_equal(u.tag, 'guest iot');
	});
});
