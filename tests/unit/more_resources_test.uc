let t = require('harness');
let handler = require('handler');
let ubus = require('bus');

let zones = loadfile('src/resources/firewall.zones.uc')();
let redirects = loadfile('src/resources/firewall.redirects.uc')();
let interfaces = loadfile('src/resources/network.interfaces.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

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
		t.assert_equal(r.output_policy, 'REJECT');
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
		let errs = full_validate(zones, { name: 'lan', input: 'BOGUS' }, null);
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

	// fw4 marks src_dport a scalar on a redirect, so a second value would be
	// written as a uci list and make it discard the whole section.
	// Two values used to be a 422 at apply from a hand-written rule. The scalar type says the
	// same thing earlier and in a form a generated client can see, so the check moved from
	// validate() to the central type gate.
	t.it('a second value on a scalar match option is a type error, not a late conflict', () => {
		let handler = require('handler');
		let errs = handler.check_schema_types(redirects.schema_properties,
		                                      { match: { src_dport: ['8000-8100', '9000'] } });
		let e = filter(errs, function(x) { return x.field == "match.src_dport"; });
		t.assert_equal(e[0].code, "invalid_type");
	});

	t.it('validate accepts a single port range', () => {
		let errs = redirects.validate({ target: 'DNAT',
		                                match: { src_zone: 'wan', src_dport: '8000-8100' } }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('fromUci surfaces the scalar match options as scalars', () => {
		let r = redirects.fromUci({ '.name': 'fwd1', '.anonymous': false, '.type': 'redirect',
		                            src: 'wan', src_dport: '8443', dest_port: '443', dest_ip: '192.168.1.10' });
		t.assert_equal(r.match.src_dport, '8443');
		t.assert_equal(r.match.dest_port, '443');
		t.assert_equal(r.match.dest_ip, '192.168.1.10');
		t.assert_equal(r.match.src_ip, null);
	});

	// A hand-written `list dest_ip` is a section fw4 discards whole, and there is no field
	// here to say so. The first value is what the declared type can carry; the old array
	// shape promised at most one anyway, so nothing that used to be reported is lost.
	t.it('reports the first value when uci holds a list fw4 would reject', () => {
		let r = redirects.fromUci({ '.name': 'fwd2', '.anonymous': false, '.type': 'redirect',
		                            src: 'wan', dest_ip: ['192.168.1.10', '192.168.1.11'] });
		t.assert_equal(r.match.dest_ip, '192.168.1.10');
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

	t.it('validate requires ipaddrs for static proto', () => {
		let errs = interfaces.validate({ proto: 'static' }, null);
		let ip = filter(errs, function(e) { return e.field == "ipaddrs"; });
		t.assert_equal(ip[0].code, 'required');
	});

	// `ipaddr` is read-only from 3.0.0 and nothing writes it, so a body carrying it alone
	// must not satisfy the requirement: doing so created an addressless static interface
	// and answered 200. Relaxing the rule to accept IPv6 must not reopen that.
	t.it('validate does not accept the read-only ipaddr in place of ipaddrs', () => {
		let errs = interfaces.validate({ proto: 'static', ipaddr: '192.0.2.99' }, null);
		let ip = filter(errs, function(e) { return e.field == "ipaddrs" && e.code == "required"; });
		t.assert_equal(length(ip), 1);
	});

	// LuCI's static form marks neither address family required, so an interface addressed
	// only over IPv6 is valid there and has to be here.
	t.it('validate accepts a static interface addressed only over IPv6', () => {
		t.assert_equal(length(interfaces.validate(
			{ proto: 'static', ip6addrs: ['fd00:db8::1/64'] }, null)), 0);
	});

	t.it('validate accepts both families together', () => {
		t.assert_equal(length(interfaces.validate(
			{ proto: 'static', ipaddrs: ['192.0.2.1/24'], ip6addrs: ['fd00:db8::1/64'] }, null)), 0);
	});

	t.it('validate rejects an ip6addrs entry that is not an IPv6 address', () => {
		let errs = interfaces.validate({ proto: 'static', ip6addrs: ['192.0.2.1'] }, null);
		let e6 = filter(errs, function(e) { return e.field == "ip6addrs[0]"; });
		t.assert_equal(e6[0].code, 'invalid_format');
	});

	t.it('fromUci surfaces list ip6addr as ip6addrs, and null when absent', () => {
		let v6 = interfaces.fromUci({ '.name': 'v6', '.anonymous': false, '.type': 'interface',
		                              proto: 'static', ip6addr: ['fd00::1/64', 'fd00::2/64'] });
		t.assert_deep_equal(v6.ip6addrs, ['fd00::1/64', 'fd00::2/64']);
		let v4 = interfaces.fromUci({ '.name': 'v4', '.anonymous': false, '.type': 'interface',
		                              proto: 'static', ipaddr: '192.0.2.1' });
		t.assert_equal(v4.ip6addrs, null);
	});

	// The three fields LuCI offers on a static interface that had no counterpart here. Each
	// has a distinct accepted shape, which is the only reason they are worth separate cases.
	t.it('accepts the static IPv6 and broadcast fields LuCI declares', () => {
		t.assert_equal(length(interfaces.validate(
			{ proto: 'static', ipaddrs: ['192.0.2.1/24'], broadcast: '192.0.2.255',
			  ip6addrs: ['fd00::1/64'], ip6gw: 'fd00::ffff', ip6prefix: 'fd00:beef::/48' }, null)), 0);
	});

	t.it('rejects a broadcast that is not IPv4, and a prefixed ip6gw', () => {
		let b = filter(interfaces.validate({ proto: 'static', ipaddrs: ['192.0.2.1/24'],
		                                     broadcast: 'fd00::1' }, null),
		               function(e) { return e.field == 'broadcast'; });
		t.assert_equal(b[0].code, 'invalid_format');
		// netifd wants the gateway bare; a prefix length here is the common mistake.
		let g = filter(interfaces.validate({ proto: 'static', ipaddrs: ['192.0.2.1/24'],
		                                     ip6gw: 'fd00::ffff/64' }, null),
		               function(e) { return e.field == 'ip6gw'; });
		t.assert_equal(g[0].code, 'invalid_format');
	});

	// Whether an address is required depends on the proto; whether a value is an address
	// does not. Gating the format checks on static let a dhcp body carry nonsense that
	// toUci wrote anyway: `999.999.999.999` reached uci on a real box.
	t.it('validates address formats whatever the proto says', () => {
		let errs = interfaces.validate({ proto: 'dhcp', broadcast: '999.999.999.999',
		                                 ip6gw: 'not-an-address', gateway: 'nope' }, null);
		for (let f in ['broadcast', 'ip6gw', 'gateway']) {
			let e = filter(errs, function(x) { return x.field == f; });
			t.assert_equal(length(e), 1);
			t.assert_equal(e[0].code, 'invalid_format');
		}
	});

	t.it('still asks for an address only when the proto is static', () => {
		let dhcp = filter(interfaces.validate({ proto: 'dhcp' }, null),
		                  function(e) { return e.code == 'required'; });
		t.assert_equal(length(dhcp), 0);
		let stat = filter(interfaces.validate({ proto: 'static' }, null),
		                  function(e) { return e.field == 'ipaddrs' && e.code == 'required'; });
		t.assert_equal(length(stat), 1);
	});

	t.it('accepts ip6prefix with or without a prefix length', () => {
		for (let v in ['fd00:beef::/48', 'fd00:beef::1'])
			t.assert_equal(length(interfaces.validate(
				{ proto: 'static', ipaddrs: ['192.0.2.1/24'], ip6prefix: v }, null)), 0);
	});

	t.it('toUci writes ip6addrs onto the uci ip6addr option', () => {
		let u = interfaces.toUci({ proto: 'static', ip6addrs: ['fd00::1/64'] });
		t.assert_deep_equal(u.ip6addr, ['fd00::1/64']);
	});

	t.it('validate accepts dhcp without an address', () => {
		let errs = interfaces.validate({ proto: 'dhcp' }, null);
		t.assert_equal(length(errs), 0);
	});

	// v2.0.2 C1: caller-supplied `name` for wireguard interfaces.
	const WG = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=";  // example key

	// 2.2.0: `name` is deprecated in favour of `id`. Both accepted during
	// the deprecation window; must match if both supplied.
	t.it('validate accepts id alone (the 2.2.0 canonical input)', () => {
		let errs = interfaces.validate({ proto: 'wireguard', id: 'wg_prod',
			private_key: WG, addresses: ['10.0.0.1/24'] }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('validate accepts matching id and name', () => {
		let errs = interfaces.validate({ proto: 'static', id: 'lan', name: 'lan',
			ipaddr: '192.168.1.1' }, null);
		let ne = filter(errs, function(e) { return e.field == "name" || e.field == "id"; });
		t.assert_equal(length(ne), 0);
	});

	t.it('validate rejects id that exceeds IFNAMSIZ for proto=wireguard', () => {
		let errs = interfaces.validate({ proto: 'wireguard',
			id: 'this_is_way_too_long_for_ifnamsiz',
			private_key: WG, addresses: ['10.0.0.1/24'] }, null);
		let ie = filter(errs, function(e) { return e.field == "id" && e.code == "invalid_format"; });
		t.assert_equal(length(ie), 1);
	});

	t.it('id_for_create falls back to a `wg_<11-char>` id when no id is given and proto=wireguard', () => {
		let id = interfaces.id_for_create({ proto: 'wireguard' });
		t.assert_equal(length(id), 14);
		t.assert_match(id, /^wg_[0-9a-hjkmnp-tv-z]{11}$/);
	});

	t.it('id_for_create returns null for non-wireguard protos when no name is supplied', () => {
		t.assert_equal(interfaces.id_for_create({ proto: 'static' }), null);
		t.assert_equal(interfaces.id_for_create({ proto: 'dhcp' }), null);
		t.assert_equal(interfaces.id_for_create({}), null);
		t.assert_equal(interfaces.id_for_create(null), null);
	});

	// (Framework owns the in-package section-existence check as of 2.2.0;
	// the per-resource tests for that behavior moved into the handler-level
	// create tests.)

	t.it('validate rejects unknown proto', () => {
		let errs = full_validate(interfaces, { proto: 'whatever' }, null);
		let pe = filter(errs, function(e) { return e.field == "proto"; });
		t.assert_equal(pe[0].code, 'not_in_enum');
	});

	t.it('validate rejects octets > 255 in an ipaddrs CIDR', () => {
		let errs = interfaces.validate({ proto: 'static', ipaddrs: ['999.0.0.1/24'] }, null);
		let ip = filter(errs, function(e) { return e.field == "ipaddrs[0]"; });
		t.assert_equal(ip[0].code, 'invalid_format');
	});

	t.it('validate rejects prefix > 32 in an ipaddrs CIDR', () => {
		let errs = interfaces.validate({ proto: 'static', ipaddrs: ['192.168.1.0/99'] }, null);
		let ip = filter(errs, function(e) { return e.field == "ipaddrs[0]"; });
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

	// A wireguard interface could not be written through PUT at all before the
	// handler learned to restore a masked secret: the read view hides
	// private_key and validate requires it, so the round-trip 422'd.
	t.it('PUT and PATCH both keep a private_key the read view hid', () => {
		let ifh = handler.make(interfaces, {
			tx: {
				acquire: function() { return {}; }, release: function() {},
				reload: function() { return null; }, check_services: function() { return null; },
			},
		});
		let ctx = { request_id: "01hx0000000000000000000000" };
		let seed = function() {
			return ubus.stub({ uci: { network: {
				wg1: { '.type': 'interface', '.anonymous': false, proto: 'wireguard',
				       private_key: 'kK1+oLkW2yqs82bEN6FzVuOmIesYjY9hbAJTSAJfBVA=',
				       addresses: ['10.42.0.1/16'], listen_port: '51820' },
			} } });
		};

		let c1 = seed();
		t.assert_equal(ifh.patch(c1, ctx, 'wg1', { listen_port: 51999 }).status, 200);
		t.assert_equal(c1._state.uci.network.wg1.private_key,
			'kK1+oLkW2yqs82bEN6FzVuOmIesYjY9hbAJTSAJfBVA=');

		let c2 = seed();
		t.assert_equal(ifh.replace(c2, ctx, 'wg1',
			{ proto: 'wireguard', addresses: ['10.42.0.1/16'], listen_port: 51999 }).status, 200);
		t.assert_equal(c2._state.uci.network.wg1.private_key,
			'kK1+oLkW2yqs82bEN6FzVuOmIesYjY9hbAJTSAJfBVA=');
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
			ucode_prefix: ['/api/v3=/usr/share/uapi/main.uc', '/foo=/etc/foo.uc'],
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
		let errs = full_validate(uhttpd_inst, {
			listen_http: ['no-port-here'],
			ucode_prefix: ['/api/v3=/usr/share/uapi/main.uc'],
		}, null);
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
		t.assert_equal(r.metric, 100);
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
		let errs = full_validate(interfaces, { proto: 'dhcp', device: 'eth1', metric: -3 }, null);
		let found = false;
		for (let e in errs)
			if (e.field == 'metric' && e.code == 'out_of_range') { found = true; break; }
		t.assert_true(found);
	});
});

// netifd registers protocol handlers by scanning /lib/netifd/proto at startup
// and caches the result: a reload does not rescan, only a restart does. So a
// protocol whose package is absent, or was installed after netifd started, is
// silently discarded and reported as "none" while uci keeps the requested
// value. uapi does not refuse the write, because the config is legitimate and
// only the runtime is behind; it surfaces netifd's view so the gap is visible.
t.describe('network.interfaces effective_proto', () => {
	function with_status(status) {
		let c = ubus.stub({ uci: { network: {} } });
		c.set_ubus_response("network.interface.wg0", "status", status);
		return c;
	}
	const SECTION = { '.name': 'wg0', '.anonymous': false, proto: 'wireguard' };

	t.it('surfaces what netifd is running, not what uci asked for', () => {
		let r = interfaces.fromUci(SECTION, with_status({ up: false, proto: 'none' }));
		t.assert_equal(r.proto, 'wireguard');
		t.assert_equal(r.runtime.effective_proto, 'none');
	});

	t.it('agrees with uci when the handler is registered', () => {
		let r = interfaces.fromUci(SECTION, with_status({ up: true, proto: 'wireguard' }));
		t.assert_equal(r.runtime.effective_proto, 'wireguard');
	});

	t.it('never makes a write fail', () => {
		let body = { proto: 'wwan' };
		t.assert_equal(length(filter(interfaces.validate(body, with_status({ proto: 'none' })),
		                             function(e) { return e.field == "proto"; })), 0);
	});

	t.it('is null when netifd cannot be asked at all', () => {
		t.assert_equal(interfaces.fromUci(SECTION, null).runtime.effective_proto, null);
		let r = interfaces.fromUci(SECTION, ubus.stub({ uci: { network: {} } }));
		t.assert_equal(r.runtime.effective_proto ?? null, null);
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
		let errs = full_validate(interfaces, { proto: 'dhcpv6', reqaddress: 'always' }, null);
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
		let errs = full_validate(redirects, {
			match: { src_zone: 'wan' }, target: 'DNAT',
			reflection_src: 'wat',
		}, null);
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
		let errs = full_validate(unbound, { num_threads: 200 }, null);
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
		t.assert_equal(r.ipaddrs, null);
	});

	t.it('toUci: ipaddrs list takes precedence and writes a uci list', () => {
		let u = interfaces.toUci({
			proto: 'static',
			ipaddrs: ['192.168.1.1', '192.168.1.2'],
			ipaddr: 'IGNORED',
		});
		t.assert_deep_equal(u.ipaddr, ['192.168.1.1', '192.168.1.2']);
	});

	// `ipaddr` is read-only from v3: it is the first entry of the uci list, and a body
	// carrying it writes nothing. `ipaddrs` is the only write name.
	t.it('toUci: a bare ipaddr is ignored, since only ipaddrs writes', () => {
		let u = interfaces.toUci({ proto: 'static', ipaddr: '192.168.1.1' });
		t.assert_equal(u.ipaddr, null);
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

	t.it('validate: static proto with no ipaddrs reports required', () => {
		let errs = interfaces.validate({ proto: 'static', device: 'eth0' });
		let found = false;
		for (let e in errs)
			if (e.field == 'ipaddrs' && e.code == 'required') { found = true; break; }
		t.assert_true(found);
	});
});

t.describe('firewall.redirects mark match', () => {
	t.it('round-trips match.mark and omits it when absent', () => {
		let json = redirects.fromUci({
			'.name': 'r1', '.anonymous': false, '.type': 'redirect',
			target: 'DNAT', src: 'wan', mark: '!0x1/0xff',
		});
		t.assert_equal(json.match.mark, '!0x1/0xff');
		t.assert_equal(redirects.toUci(json).mark, '!0x1/0xff');

		let bare = redirects.fromUci({ '.name': 'r2', '.anonymous': false, '.type': 'redirect' });
		t.assert_equal(bare.match.mark, null);
		t.assert_equal(redirects.toUci(bare).mark, null);
	});

	t.it('rejects a mark past the 32-bit ceiling', () => {
		let errs = redirects.validate(
			{ target: 'DNAT', match: { src_zone: 'wan', mark: '4294967296' } }, null);
		let e = filter(errs, function(x) { return x.field == "match.mark"; });
		t.assert_equal(e[0].code, "out_of_range");
	});
});

// fw4 rewrites to dest_ip on a DNAT rather than matching on it, and returns
// before emitting anything if it is negated or carries a non-contiguous mask.
t.describe('firewall.redirects DNAT dest_ip', () => {
	// target defaults to DNAT in fromUci but validate reads the raw body, so a
	// request that omits it has to take the same branch.
	t.it('refuses a negated or non-contiguously masked dest_ip, target given or not', () => {
		for (let dip in ['!192.168.1.10', '10.0.0.0/255.0.255.0']) {
			for (let body in [{ target: 'DNAT', match: { src_zone: 'wan', dest_ip: dip } },
			                  { match: { src_zone: 'wan', dest_ip: dip } }]) {
				let e = filter(redirects.validate(body, null),
				               function(x) { return x.field == "match.dest_ip"; });
				t.assert_equal(e[0].code, "invalid_format");
			}
		}
	});

	t.it('keeps the forms fw4 rewrites to', () => {
		for (let dip in ['192.168.1.10', '10.0.0.0/255.255.0.0', '10.0.0.0/8'])
			t.assert_equal(length(redirects.validate(
				{ target: 'DNAT', match: { src_zone: 'wan', dest_ip: [dip] } }, null)), 0);
	});

	// On an SNAT redirect dest_ip is an ordinary match, where fw4 renders both
	// a negation and a non-contiguous mask.
	t.it('leaves dest_ip alone when the target is not DNAT', () => {
		for (let dip in ['!10.0.0.1', '10.0.0.0/255.0.255.0']) {
			let e = filter(redirects.validate({ target: 'SNAT',
				match: { src_zone: 'lan', dest_zone: 'wan', src_dip: '1.2.3.4', dest_ip: [dip] } }, null),
				function(x) { return x.field == "match.dest_ip"; });
			t.assert_equal(length(e), 0);
		}
	});
});

// Same widening as firewall.rules: fw4 keeps a port match only on tcp or udp,
// and a redirect gets no ensure_tcpudp rewrite to save a wildcard.
t.describe('firewall.redirects ports and protocol wildcards', () => {
	function gate(protos, m) {
		let body = { target: 'DNAT', match: { src_zone: 'wan', proto: protos, ...m } };
		return length(filter(redirects.validate(body, null),
		                     function(x) { return x.field == "match.proto"; })) == 0;
	}

	t.it('refuses a port beside any protocol that would lose it', () => {
		for (let p in [['tcp'], ['udp'], ['tcpudp'], ['tcp', 'udp']])
			t.assert_true(gate(p, { src_dport: '8443' }));
		for (let p in [['gre'], ['icmp'], ['tcp', 'gre'], ['all'], ['any'], ['*']])
			t.assert_false(gate(p, { src_dport: '8443' }));
	});

	t.it('leaves a protocol alone when no port is matched', () => {
		for (let p in [['gre'], ['all'], ['tcp', 'gre']])
			t.assert_true(gate(p, {}));
	});
});

t.describe('firewall.redirects SNAT', () => {
	// fw4's snat branch bails out unless the section names a real destination
	// zone and carries a src_dip to rewrite to, and refuses a negated one. Each
	// of those produces a section the router silently drops.
	t.it('accepts SNAT once fw4 requirements are met', () => {
		let errs = full_validate(redirects,
			{ target: 'SNAT', match: { src_zone: 'lan', dest_zone: 'wan',
			                           src_dip: '192.168.1.7' } }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('refuses SNAT where firewall4 would drop the section', () => {
		let cases = [
			{ f: "match.src_dip",   m: { src_zone: 'lan', dest_zone: 'wan' } },
			{ f: "match.dest_zone", m: { src_zone: 'lan', src_dip: '192.168.1.7' } },
			{ f: "match.dest_zone", m: { src_zone: 'lan', dest_zone: '*', src_dip: '192.168.1.7' } },
			{ f: "match.src_dip",   m: { src_zone: 'lan', dest_zone: 'wan', src_dip: '!192.168.1.7' } },
			{ f: "match.src_dip",   m: { src_zone: 'lan', dest_zone: 'wan',
			                             src_dip: '10.0.0.0/255.0.255.0' } },
		];
		for (let c in cases) {
			let errs = redirects.validate({ target: 'SNAT', match: c.m }, null);
			t.assert_equal(length(filter(errs, function(e) { return e.field == c.f; })), 1);
		}
	});

	// src_dip was unmodelled, so PUT's full-replace deleted it and firewall4
	// then discarded a working section. It has to survive a read-modify-write.
	t.it('round-trips src_dip instead of dropping it', () => {
		let u = redirects.toUci(redirects.fromUci({
			'.name': 'r1', '.anonymous': false, '.type': 'redirect',
			target: 'SNAT', src: 'lan', dest: 'wan', src_dip: '192.168.1.7',
		}));
		t.assert_equal(u.src_dip, '192.168.1.7');
		t.assert_equal(u.target, 'SNAT');
	});

	// fw4 reads src_dip on the DNAT path too, as the external address for NAT
	// reflection, so modelling it fixes the same data loss there.
	t.it('keeps src_dip on a DNAT reflection section', () => {
		let body = { target: 'DNAT', match: { src_zone: 'wan', src_dport: '80',
		                                      src_dip: '203.0.113.5', dest_ip: '10.0.0.1' } };
		t.assert_equal(length(full_validate(redirects, body, null)), 0);
		t.assert_equal(redirects.toUci(body).src_dip, '203.0.113.5');
	});

	t.it('still accepts DNAT and the DNAT default', () => {
		let body = { match: { src_zone: 'wan', src_dport: '80', dest_ip: '10.0.0.1' } };
		t.assert_equal(length(full_validate(redirects, body, null)), 0);
		body.target = 'DNAT';
		t.assert_equal(length(full_validate(redirects, body, null)), 0);
	});
});

// Both messages stated enum sets their constants contradict: `protocol` advertised
// `auto`, which the validator rejects, and omitted three values it accepts, while
// `resource_limits` omitted the accepted `default`. Derived now, so a new enum value
// cannot leave the message behind.
t.describe('unbound.server enum messages match what is accepted', () => {
	let srv = loadfile('src/resources/unbound.server.uc')();
	function message_for(field, bad) {
		let body = { [field]: bad };
		for (let e in srv.validate(body, null) ?? [])
			if (e.field == field && e.code == "not_in_enum") return e.message;
		return null;
	}

	function every_named_value_is_accepted(field, msg) {
		let listed = split(replace(msg, "must be one of ", ""), ", ");
		for (let v in listed) {
			let errs = srv.validate({ [field]: v }, null) ?? [];
			for (let e in errs)
				if (e.field == field && e.code == "not_in_enum") return false;
		}
		return true;
	}

	t.it('protocol no longer advertises a value it rejects', () => {
		let msg = message_for("protocol", "nonsense");
		t.assert_true(msg != null);
		t.assert_false(index(msg, "auto") >= 0);
		t.assert_true(every_named_value_is_accepted("protocol", msg));
	});

	t.it('resource_limits names every value it accepts, including default', () => {
		let msg = message_for("resource_limits", "nonsense");
		t.assert_true(index(msg, "default") >= 0);
		t.assert_true(every_named_value_is_accepted("resource_limits", msg));
	});
});

// Three fields wrote a uci key their daemon never reads, so the value never reached the
// device: lldpd reads `lldp_capability_advertisements` (lldpd.init:228), unbound reads
// `validator` (unbound.sh:1352), and snmpd reads `sysService` singular (snmpd.init:36,
// a typo uapi inherited from upstream's own sample config). Each now writes the key its
// daemon reads, and still reads the old one when the new is absent, or an upgrade would
// silently drop whatever the operator had set and report the default instead.
t.describe('fields repointed at the uci key their daemon actually reads', () => {
	let lldpd = loadfile('src/resources/lldpd.config.uc')();
	let unbound = loadfile('src/resources/unbound.server.uc')();
	let snmpd = loadfile('src/resources/snmpd.system.uc')();

	t.it('lldpd writes lldp_capability_advertisements', () => {
		t.assert_equal(lldpd.toUci({ lldp_capabilities: false }).lldp_capability_advertisements, '0');
		// The legacy key is emitted as an empty array, which is uci's "no such option":
		// it has to be in the write set or nothing ever deletes it from an upgraded box.
		t.assert_deep_equal(lldpd.toUci({ lldp_capabilities: false }).lldp_capabilities, []);
	});
	t.it('lldpd still reads a section carrying only the old key', () => {
		let v = lldpd.fromUci({ '.name': 'cfg', '.type': 'lldpd', lldp_capabilities: '0' }, null);
		t.assert_false(v.lldp_capabilities);
	});
	t.it('lldpd prefers the real key when both are present', () => {
		let v = lldpd.fromUci({ '.name': 'cfg', '.type': 'lldpd',
		                        lldp_capabilities: '1',
		                        lldp_capability_advertisements: '0' }, null);
		t.assert_false(v.lldp_capabilities);
	});

	t.it('unbound writes validator', () => {
		t.assert_equal(unbound.toUci({ dnssec_enabled: true }).validator, '1');
		t.assert_deep_equal(unbound.toUci({ dnssec_enabled: true }).dnssec_enabled, []);
	});
	t.it('unbound still reads a section carrying only the old key', () => {
		let v = unbound.fromUci({ '.name': 'ub', '.type': 'unbound', dnssec_enabled: '1' }, null);
		t.assert_true(v.dnssec_enabled);
	});

	t.it('snmpd writes sysService, singular', () => {
		t.assert_equal(snmpd.toUci({ sys_services: 72 }).sysService, '72');
		t.assert_deep_equal(snmpd.toUci({ sys_services: 72 }).sysServices, []);
	});
	t.it('snmpd still reads a section carrying only the plural', () => {
		let v = snmpd.fromUci({ '.name': 'c', '.type': 'system', sysServices: '72' }, null);
		t.assert_equal(v.sys_services, 72);
	});
});

// Clearing a repointed field has to clear the legacy key too. Without that the legacy key
// is never in the footprint diff_apply_patch deletes from, so the fallback read resurrects
// it: the 200 said false, the next GET said true, and the daemon had it off. Three answers,
// two of them wrong.
t.describe('clearing a repointed field clears the legacy key with it', () => {
	let ubus4 = require('bus');
	let handler4 = require('handler');
	let fx4 = require('resource_fixtures');
	let unbound4 = loadfile('src/resources/unbound.server.uc')();
	function tx4() {
		return { acquire: function() { return {}; }, release: function() {},
		         reload: function() { return null; }, check_services: function() { return null; },
		         wg_apply: function() { return null; }, wg_reconcile: function() { return null; } };
	}
	function c4() { return { request_id: "01hx0000000000000000000000" }; }
	function legacy_box() {
		let u = fx4.world();
		u.unbound = { ub: { '.anonymous': false, '.type': 'unbound', dnssec_enabled: '1' } };
		return ubus4.stub({ uci: u });
	}
	let h4 = handler4.make_singleton(unbound4, { tx: tx4() });

	t.it('an untouched box still reports the operator value', () => {
		t.assert_true(h4.get(legacy_box(), c4()).body.dnssec_enabled);
	});
	t.it('clearing it removes both keys, and the next read agrees with the write', () => {
		let c = legacy_box();
		let r = h4.patch(c, c4(), { dnssec_enabled: null });
		t.assert_equal(r.status, 200);
		t.assert_false(r.body.dnssec_enabled);
		t.assert_equal(c._state.uci.unbound.ub.dnssec_enabled, null);
		t.assert_equal(c._state.uci.unbound.ub.validator, null);
		t.assert_false(h4.get(c, c4()).body.dnssec_enabled);
	});
	t.it('setting it writes the real key and drops the legacy one', () => {
		let c = legacy_box();
		h4.patch(c, c4(), { dnssec_enabled: true });
		t.assert_equal(c._state.uci.unbound.ub.validator, '1');
		t.assert_equal(c._state.uci.unbound.ub.dnssec_enabled, null);
	});
});

// vnstat's init walks `config vnstat` sections and reads a `list interface` inside them
// (vnstat.init:21,28). uapi's `vnstat/interfaces` resource models `config interface`
// sections instead, which nothing reads, so every write to it returned 200 and changed
// nothing the daemon looks at. The working surface is on the singleton, which is already
// the `config vnstat` section.
t.describe('vnstat/config carries the interface list vnstat actually reads', () => {
	let vc = loadfile('src/resources/vnstat.config.uc')();

	t.it('reads the list off the vnstat section', () => {
		let v = vc.fromUci({ '.name': 'cfg', '.type': 'vnstat',
		                     interface: ['br-lan', 'eth0'] }, null);
		t.assert_deep_equal(v.interfaces, ['br-lan', 'eth0']);
	});
	t.it('writes it back as the list, not as sections', () => {
		t.assert_deep_equal(vc.toUci({ interfaces: ['br-lan'] }).interface, ['br-lan']);
	});
	t.it('a single device is still a list', () => {
		let v = vc.fromUci({ '.name': 'cfg', '.type': 'vnstat', interface: 'br-lan' }, null);
		t.assert_deep_equal(v.interfaces, ['br-lan']);
	});
	// Entries are device names as the kernel shows them. The old endpoint took uci
	// interface names, so migrating is a translation (`lan` -> `br-lan`), not a copy.
	t.it('rejects an empty entry, which cannot name a device', () => {
		let errs = vc.validate({ interfaces: ['', 'br-lan'] });
		t.assert_equal(length(errs), 1);
		t.assert_equal(errs[0].field, 'interfaces[0]');
	});
	t.it('accepts a plausible device list', () => {
		t.assert_equal(length(vc.validate({ interfaces: ['br-lan', 'eth0.30'] })), 0);
	});
});
