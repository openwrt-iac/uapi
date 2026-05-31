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
	t.it('rejects missing mac and ip together', () => {
		let errs = hosts.validate({}, null);
		t.assert_true(length(errs) >= 2);
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
	t.it('validate cross-refs instance against dhcp/servers sections', () => {
		let conn = ubus.stub({ uci: { dhcp: {
			lan_server: { '.type': 'dhcp', interface: 'lan' },
		}}});
		let ok = hosts.validate({
			mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', instance: 'lan_server',
		}, conn);
		for (let e in ok)
			t.assert_not_equal(e.field + ':' + e.code, 'instance:conflict');
		let bad = hosts.validate({
			mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.1', instance: 'nope',
		}, conn);
		let found = false;
		for (let e in bad)
			if (e.field == 'instance' && e.code == 'conflict') { found = true; break; }
		t.assert_true(found);
	});
});
