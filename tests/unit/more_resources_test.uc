let t = require('harness');

let zones = loadfile('src/resources/firewall.zones.uc')();
let redirects = loadfile('src/resources/firewall.redirects.uc')();
let interfaces = loadfile('src/resources/network.interfaces.uc')();

t.describe('firewall.zones', () => {
	t.it('contract', () => {
		t.assert_equal(zones.package, "firewall");
		t.assert_equal(zones.type, "zone");
		t.assert_deep_equal(zones.reload, ["firewall"]);
	});

	t.it('fromUci defaults policies to REJECT', () => {
		let r = zones.fromUci({ '.name': 'z_lan', '.anonymous': false, '.type': 'zone',
		                        name: 'lan', input: 'ACCEPT' });
		t.assert_equal(r.input, 'ACCEPT');
		t.assert_equal(r.output, 'REJECT');
		t.assert_equal(r.forward, 'REJECT');
	});

	t.it('toUci preserves network list', () => {
		let u = zones.toUci({ name: 'lan', input: 'ACCEPT', network: ['lan', 'lan2'] });
		t.assert_deep_equal(u.network, ['lan', 'lan2']);
	});

	t.it('validate rejects missing name', () => {
		let errs = zones.validate({}, null);
		t.assert_true(length(filter(errs, function(e) { return e.field == "name"; })) >= 1);
	});

	t.it('validate rejects bad policy', () => {
		let errs = zones.validate({ name: 'lan', input: 'BOGUS' }, null);
		let ie = filter(errs, function(e) { return e.field == "input"; });
		t.assert_equal(ie[0].code, 'not_in_enum');
	});
});

t.describe('firewall.redirects', () => {
	t.it('contract', () => {
		t.assert_equal(redirects.package, "firewall");
		t.assert_equal(redirects.type, "redirect");
	});

	t.it('fromUci defaults target to DNAT', () => {
		let r = redirects.fromUci({ '.name': 'fwd1', '.anonymous': false, '.type': 'redirect',
		                            src: 'wan' });
		t.assert_equal(r.target, 'DNAT');
		t.assert_equal(r.match.src_zone, 'wan');
	});

	t.it('validate rejects missing src_zone', () => {
		let errs = redirects.validate({ target: 'DNAT', match: {} }, null);
		let sz = filter(errs, function(e) { return e.field == "match.src_zone"; });
		t.assert_equal(sz[0].code, 'required');
	});

	t.it('validate rejects bad dest_ip', () => {
		let errs = redirects.validate({ target: 'DNAT',
		                                match: { src_zone: 'wan', dest_ip: '999.0.0.1' } }, null);
		let de = filter(errs, function(e) { return match(e.field, /^match\.dest_ip/); });
		t.assert_equal(de[0].code, 'invalid_format');
	});

	t.it('validate accepts port ranges given as scalars', () => {
		let errs = redirects.validate({ target: 'DNAT',
		                                match: { src_zone: 'wan', src_dport: '8000-8100' } }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('validate accepts port ranges given as arrays', () => {
		let errs = redirects.validate({ target: 'DNAT',
		                                match: { src_zone: 'wan', src_dport: ['8000-8100', '9000'] } }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('fromUci lifts scalar port options to arrays (matching firewall.rules)', () => {
		let r = redirects.fromUci({ '.name': 'fwd1', '.anonymous': false, '.type': 'redirect',
		                            src: 'wan', src_dport: '8443', dest_port: '443', dest_ip: '192.168.1.10' });
		t.assert_deep_equal(r.match.src_dport, ['8443']);
		t.assert_deep_equal(r.match.dest_port, ['443']);
		t.assert_deep_equal(r.match.dest_ip, ['192.168.1.10']);
	});
});

t.describe('network.interfaces', () => {
	t.it('contract', () => {
		t.assert_equal(interfaces.package, "network");
		t.assert_equal(interfaces.type, "interface");
		t.assert_deep_equal(interfaces.reload, ["network"]);
	});

	t.it('fromUci surfaces proto and addresses', () => {
		let r = interfaces.fromUci({ '.name': 'lan', '.anonymous': false, '.type': 'interface',
		                             proto: 'static', ipaddr: '192.168.1.1', netmask: '255.255.255.0' });
		t.assert_equal(r.proto, 'static');
		t.assert_equal(r.ipaddr, '192.168.1.1');
		t.assert_equal(r.netmask, '255.255.255.0');
	});

	t.it('validate requires ipaddr for static proto', () => {
		let errs = interfaces.validate({ proto: 'static' }, null);
		let ip = filter(errs, function(e) { return e.field == "ipaddr"; });
		t.assert_equal(ip[0].code, 'required');
	});

	t.it('validate accepts dhcp without ipaddr', () => {
		let errs = interfaces.validate({ proto: 'dhcp' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('validate rejects unknown proto', () => {
		let errs = interfaces.validate({ proto: 'whatever' }, null);
		let pe = filter(errs, function(e) { return e.field == "proto"; });
		t.assert_equal(pe[0].code, 'not_in_enum');
	});

	t.it('validate rejects octets > 255 in ipaddr CIDR', () => {
		let errs = interfaces.validate({ proto: 'static', ipaddr: '999.0.0.1/24' }, null);
		let ip = filter(errs, function(e) { return e.field == "ipaddr"; });
		t.assert_equal(ip[0].code, 'invalid_format');
	});

	t.it('validate rejects prefix > 32 in ipaddr CIDR', () => {
		let errs = interfaces.validate({ proto: 'static', ipaddr: '192.168.1.0/99' }, null);
		let ip = filter(errs, function(e) { return e.field == "ipaddr"; });
		t.assert_equal(ip[0].code, 'invalid_format');
	});

	t.it('validate rejects octets > 255 in netmask', () => {
		let errs = interfaces.validate({ proto: 'static', ipaddr: '192.168.1.1', netmask: '999.0.0.0' }, null);
		let nm = filter(errs, function(e) { return e.field == "netmask"; });
		t.assert_equal(nm[0].code, 'invalid_format');
	});

	t.it('proto=wireguard requires private_key + addresses', () => {
		let errs = interfaces.validate({ proto: 'wireguard' }, null);
		let pk = filter(errs, function(e) { return e.field == "private_key"; });
		let ad = filter(errs, function(e) { return e.field == "addresses"; });
		t.assert_equal(pk[0].code, 'required');
		t.assert_equal(ad[0].code, 'required');
	});

	t.it('proto=wireguard rejects bad private_key shape', () => {
		let errs = interfaces.validate({
			proto: 'wireguard', private_key: 'tooshort',
			addresses: ['10.42.0.1/16'],
		}, null);
		let pk = filter(errs, function(e) { return e.field == "private_key"; });
		t.assert_equal(pk[0].code, 'invalid_format');
	});

	t.it('proto=wireguard accepts a real-shape key + CIDRs', () => {
		let errs = interfaces.validate({
			proto: 'wireguard',
			private_key: 'kK1+oLkW2yqs82bEN6FzVuOmIesYjY9hbAJTSAJfBVA=',
			addresses: ['10.42.0.1/16'],
			listen_port: 51820,
		}, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('fromUci on wireguard surfaces has_private_key but masks the key', () => {
		let r = interfaces.fromUci({
			'.name': 'wg1', '.anonymous': false, '.type': 'interface',
			proto: 'wireguard', listen_port: '51820',
			private_key: 'kK1+oLkW2yqs82bEN6FzVuOmIesYjY9hbAJTSAJfBVA=',
			addresses: ['10.42.0.1/16'],
		});
		t.assert_true(r.has_private_key);
		t.assert_equal(r.private_key, null);
		t.assert_deep_equal(r.addresses, ['10.42.0.1/16']);
	});

	t.it('merge_for_patch carries forward the existing private_key', () => {
		let existing = {
			'.name': 'wg1', '.anonymous': false, '.type': 'interface',
			proto: 'wireguard',
			private_key: 'kK1+oLkW2yqs82bEN6FzVuOmIesYjY9hbAJTSAJfBVA=',
			addresses: ['10.42.0.1/16'],
		};
		let merged = interfaces.merge_for_patch(existing,
			interfaces.fromUci(existing), { listen_port: 51999 });
		t.assert_equal(merged.private_key,
			'kK1+oLkW2yqs82bEN6FzVuOmIesYjY9hbAJTSAJfBVA=');
		t.assert_equal(merged.listen_port, 51999);
	});

	t.it('toUci stringifies numeric ip6assign', () => {
		let u = interfaces.toUci({ proto: 'dhcp', ip6assign: 64 });
		t.assert_equal(u.ip6assign, '64');
	});
});
