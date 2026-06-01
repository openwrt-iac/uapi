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

let uhttpd_inst = loadfile('src/resources/uhttpd.instances.uc')();

t.describe('uhttpd.instances self-lockout protection', () => {
	t.it("validate(id='main') rejects a body that omits uapi's ucode_prefix", () => {
		let errs = uhttpd_inst.validate({
			listen_http: ['0.0.0.0:80'],
			listen_https: ['0.0.0.0:443'],
			ucode_prefix: ['/foo=/etc/foo.uc'],
		}, null, 'main');
		let found = false;
		for (let e in errs)
			if (e.field == 'ucode_prefix' && e.code == 'conflict') { found = true; break; }
		t.assert_true(found);
	});

	t.it("validate(id='main') accepts a body that keeps uapi's ucode_prefix", () => {
		let errs = uhttpd_inst.validate({
			listen_http: ['0.0.0.0:80'],
			ucode_prefix: ['/api/v1=/usr/share/uapi/main.uc', '/foo=/etc/foo.uc'],
		}, null, 'main');
		for (let e in errs)
			t.assert_not_equal(e.field + ':' + e.code, 'ucode_prefix:conflict');
	});

	t.it("validate(id='other') does NOT enforce the lockout check", () => {
		let errs = uhttpd_inst.validate({
			listen_http: ['0.0.0.0:81'],
			ucode_prefix: ['/foo=/etc/foo.uc'],
		}, null, 'other');
		for (let e in errs)
			t.assert_not_equal(e.field + ':' + e.code, 'ucode_prefix:conflict');
	});

	t.it("validate rejects bogus listen entries with invalid_format", () => {
		let errs = uhttpd_inst.validate({
			listen_http: ['no-port-here'],
			ucode_prefix: ['/api/v1=/usr/share/uapi/main.uc'],
		}, null, 'main');
		let found = false;
		for (let e in errs)
			if (e.code == 'invalid_format') { found = true; break; }
		t.assert_true(found);
	});
});

t.describe('network.interfaces proto=dhcp client fields', () => {
	t.it('fromUci surfaces peerdns/defaultroute/metric/hostname/clientid', () => {
		let r = interfaces.fromUci({
			'.name': 'wan', '.anonymous': false,
			proto: 'dhcp', device: 'eth1',
			peerdns: '0', defaultroute: '1', metric: '100',
			hostname: 'router', clientid: 'aa:bb',
		});
		t.assert_equal(r.proto, 'dhcp');
		t.assert_false(r.peerdns);
		t.assert_true(r.defaultroute);
		t.assert_equal(r.metric, '100');
		t.assert_equal(r.hostname, 'router');
		t.assert_equal(r.clientid, 'aa:bb');
	});
	t.it('toUci serializes the dhcp fields under proto=dhcp', () => {
		let u = interfaces.toUci({
			proto: 'dhcp', peerdns: false, defaultroute: true,
			metric: 50, hostname: 'r', clientid: 'x',
		});
		t.assert_equal(u.peerdns, '0');
		t.assert_equal(u.defaultroute, '1');
		t.assert_equal(u.metric, '50');
		t.assert_equal(u.hostname, 'r');
		t.assert_equal(u.clientid, 'x');
	});
	t.it('validate rejects negative metric on dhcp', () => {
		let errs = interfaces.validate({ proto: 'dhcp', device: 'eth1', metric: -3 });
		let found = false;
		for (let e in errs)
			if (e.field == 'metric' && e.code == 'out_of_range') { found = true; break; }
		t.assert_true(found);
	});
});

t.describe('network.interfaces proto=dhcpv6 client fields', () => {
	t.it('fromUci surfaces reqprefix/reqaddress/ip6hint/ip6ifaceid/delegate/peerdns', () => {
		let r = interfaces.fromUci({
			'.name': 'wan6', '.anonymous': false,
			proto: 'dhcpv6', device: 'eth1',
			reqprefix: 'auto', reqaddress: 'try',
			ip6hint: '2001:db8::/56', ip6ifaceid: '::1',
			delegate: '0', peerdns: '0',
		});
		t.assert_equal(r.proto, 'dhcpv6');
		t.assert_equal(r.reqprefix, 'auto');
		t.assert_equal(r.reqaddress, 'try');
		t.assert_equal(r.ip6hint, '2001:db8::/56');
		t.assert_equal(r.ip6ifaceid, '::1');
		t.assert_false(r.delegate);
		t.assert_false(r.peerdns);
	});
	t.it('toUci serializes dhcpv6 fields', () => {
		let u = interfaces.toUci({
			proto: 'dhcpv6', reqprefix: 56, reqaddress: 'force',
			ip6hint: '2001:db8::/56', delegate: true,
		});
		t.assert_equal(u.reqprefix, '56');
		t.assert_equal(u.reqaddress, 'force');
		t.assert_equal(u.delegate, '1');
	});
	t.it('validate rejects bad reqaddress enum', () => {
		let errs = interfaces.validate({ proto: 'dhcpv6', reqaddress: 'always' });
		let found = false;
		for (let e in errs)
			if (e.field == 'reqaddress' && e.code == 'not_in_enum') { found = true; break; }
		t.assert_true(found);
	});
	t.it('validate rejects malformed ip6hint', () => {
		let errs = interfaces.validate({ proto: 'dhcpv6', ip6hint: 'not-an-ipv6' });
		let found = false;
		for (let e in errs)
			if (e.field == 'ip6hint' && e.code == 'invalid_format') { found = true; break; }
		t.assert_true(found);
	});
});

let redirects = loadfile('src/resources/firewall.redirects.uc')();

t.describe('firewall.redirects reflection', () => {
	t.it('fromUci surfaces reflection as null when uci has nothing set (preserves daemon default on PATCH)', () => {
		let r = redirects.fromUci({
			'.name': 'r1', '.anonymous': false,
			target: 'DNAT', src: 'wan', dest_port: '443',
		});
		t.assert_equal(r.reflection, null);
		t.assert_equal(r.reflection_src, null);
	});
	t.it('fromUci respects explicit reflection=0 and reflection_src=external', () => {
		let r = redirects.fromUci({
			'.name': 'r2', '.anonymous': false,
			target: 'DNAT', src: 'wan',
			reflection: '0', reflection_src: 'external',
		});
		t.assert_false(r.reflection);
		t.assert_equal(r.reflection_src, 'external');
	});
	t.it('toUci passes through reflection bits', () => {
		let u = redirects.toUci({
			match: { src_zone: 'wan' }, target: 'DNAT',
			reflection: false, reflection_src: 'external',
		});
		t.assert_equal(u.reflection, '0');
		t.assert_equal(u.reflection_src, 'external');
	});
	t.it('validate rejects bad reflection_src', () => {
		let errs = redirects.validate({
			match: { src_zone: 'wan' }, target: 'DNAT',
			reflection_src: 'wat',
		});
		let found = false;
		for (let e in errs)
			if (e.field == 'reflection_src' && e.code == 'not_in_enum') { found = true; break; }
		t.assert_true(found);
	});
});

let unbound = loadfile('src/resources/unbound.server.uc')();

t.describe('unbound.server parity additions', () => {
	t.it('fromUci surfaces manual_conf etc. as null when uci has nothing set', () => {
		let r = unbound.fromUci({ '.name': 'ub_main' });
		t.assert_equal(r.manual_conf, null);
		t.assert_equal(r.extended_stats, null);
		t.assert_equal(r.interface_auto, null);
		t.assert_equal(r.localservice, null);
		t.assert_equal(r.hide_binddata, null);
	});

	t.it('fromUci surfaces explicit uci values normally', () => {
		let r = unbound.fromUci({
			'.name': 'ub_main',
			manual_conf: '1', interface_auto: '0', localservice: '0',
		});
		t.assert_true(r.manual_conf);
		t.assert_false(r.interface_auto);
		t.assert_false(r.localservice);
	});
	t.it('toUci serializes new fields', () => {
		let u = unbound.toUci({
			manual_conf: true, extended_stats: true,
			interface_auto: false, num_threads: 4,
			rebind_protection: 2, domain_type: 'static',
			ttl_min: 60, domain: 'lan',
		});
		t.assert_equal(u.manual_conf, '1');
		t.assert_equal(u.extended_stats, '1');
		t.assert_equal(u.interface_auto, '0');
		t.assert_equal(u.num_threads, '4');
		t.assert_equal(u.rebind_protection, '2');
		t.assert_equal(u.domain_type, 'static');
		t.assert_equal(u.ttl_min, '60');
		t.assert_equal(u.domain, 'lan');
	});
	t.it('validate rejects bad rebind_protection', () => {
		let errs = unbound.validate({ rebind_protection: 9 });
		t.assert_equal(errs[0].field, 'rebind_protection');
		t.assert_equal(errs[0].code, 'not_in_enum');
	});
	t.it('validate rejects bad domain_type enum', () => {
		let errs = unbound.validate({ domain_type: 'bogus' });
		t.assert_equal(errs[0].field, 'domain_type');
		t.assert_equal(errs[0].code, 'not_in_enum');
	});
	t.it('validate bounds num_threads', () => {
		let errs = unbound.validate({ num_threads: 200 });
		t.assert_equal(errs[0].field, 'num_threads');
		t.assert_equal(errs[0].code, 'out_of_range');
	});
});

t.describe('network.interfaces ipaddr / ipaddrs (uci option vs list forms)', () => {
	t.it('fromUci: option ipaddr (string) surfaces in both ipaddr and ipaddrs', () => {
		let r = interfaces.fromUci({
			'.name': 'lan', '.anonymous': false,
			proto: 'static', ipaddr: '192.168.1.1', netmask: '255.255.255.0',
		});
		t.assert_equal(r.ipaddr, '192.168.1.1');
		t.assert_deep_equal(r.ipaddrs, ['192.168.1.1']);
	});

	t.it('fromUci: list ipaddr surfaces first in ipaddr, full list in ipaddrs', () => {
		let r = interfaces.fromUci({
			'.name': 'loopback', '.anonymous': false,
			proto: 'static',
			ipaddr: ['127.0.0.1/8', '127.0.0.2/8'],
		});
		t.assert_equal(r.ipaddr, '127.0.0.1/8');
		t.assert_deep_equal(r.ipaddrs, ['127.0.0.1/8', '127.0.0.2/8']);
	});

	t.it('fromUci: missing ipaddr returns null/[]', () => {
		let r = interfaces.fromUci({
			'.name': 'wan6', '.anonymous': false, proto: 'dhcpv6', device: 'eth1',
		});
		t.assert_equal(r.ipaddr, null);
		t.assert_deep_equal(r.ipaddrs, []);
	});

	t.it('toUci: ipaddrs list takes precedence and writes a uci list', () => {
		let u = interfaces.toUci({
			proto: 'static',
			ipaddrs: ['192.168.1.1', '192.168.1.2'],
			ipaddr: 'IGNORED',  // ipaddrs wins
		});
		t.assert_deep_equal(u.ipaddr, ['192.168.1.1', '192.168.1.2']);
	});

	t.it('toUci: bare ipaddr (string) writes a uci option', () => {
		let u = interfaces.toUci({ proto: 'static', ipaddr: '192.168.1.1' });
		t.assert_equal(u.ipaddr, '192.168.1.1');
	});

	t.it('validate: ipaddrs with bad entries reports per-index invalid_format', () => {
		let errs = interfaces.validate({
			proto: 'static',
			ipaddrs: ['192.168.1.1', '999.0.0.0'],
		});
		let found = false;
		for (let e in errs)
			if (e.field == 'ipaddrs[1]' && e.code == 'invalid_format') { found = true; break; }
		t.assert_true(found);
	});

	t.it('validate: static proto with neither ipaddr nor ipaddrs reports required', () => {
		let errs = interfaces.validate({ proto: 'static', device: 'eth0' });
		let found = false;
		for (let e in errs)
			if (e.field == 'ipaddr' && e.code == 'required') { found = true; break; }
		t.assert_true(found);
	});
});
