let t = require('harness');
let bus = require('bus');
let odhcpd_leases = require('odhcpd_leases');
let handler = require('handler');
let leases = loadfile('src/resources/dhcp.leases.uc')();
let servers = loadfile('src/resources/dhcp.servers.uc')();

// `ubus call dhcp ipv6leases` of odhcpd 2026.11.17 as ucode reads it, with each u32 as a signed
// int32: an address lease, a prefix delegation that does not expire, a lease of two addresses with
// an iaid from 2^31, a lease that odhcpd only offered, and a client hostname with a space, a control
// byte, a backslash and a byte that is not UTF-8.
const REPLY = { device: {
	uapi6a: { leases: [
		{ duid: "000300019e09e3b126e0", iaid: 1633631943, hostname: "router-1", "accept-reconf": false,
		  assigned: 2797, flags: [ "bound" ],
		  "ipv6-addr": [ { address: "fd99:6::aed", "preferred-lifetime": 3600, "valid-lifetime": 7200 } ], valid: 7200 },
	] },
	"br-lan": { leases: [
		{ duid: "00010001aabbccddeeff", iaid: 1, hostname: "", "accept-reconf": false, assigned: 5,
		  flags: [ "bound", "static" ],
		  "ipv6-prefix": [ { address: "fd99:7:100::", "preferred-lifetime": -1,
		                     "valid-lifetime": -1, "prefix-length": 56 } ], valid: -1 },
		{ duid: "00030001aabbccddee00", iaid: -784789893, hostname: "laptop", "accept-reconf": false, assigned: 11,
		  flags: [ "bound" ],
		  "ipv6-addr": [ { address: "fd99:6::b", "preferred-lifetime": 60, "valid-lifetime": 120 },
		                 { address: "fd99:6::c", "preferred-lifetime": 60, "valid-lifetime": 120 } ], valid: 120 },
		{ duid: "00030001aabbccddee01", iaid: 3, hostname: "offered", "accept-reconf": false, assigned: 13,
		  flags: [], "ipv6-addr": [ { address: "fd99:6::d", "preferred-lifetime": 60, "valid-lifetime": 120 } ],
		  valid: 120 },
		{ duid: "00030001aabbccddee02", iaid: 4, hostname: "my host" + chr(1) + "\\" + chr(0xff),
		  "accept-reconf": false, assigned: 14, flags: [ "bound" ],
		  "ipv6-addr": [ { address: "fd99:6::e", "preferred-lifetime": 60, "valid-lifetime": 120 } ], valid: 120 },
	] },
} };

function with_reply(reply, fn) {
	let c = bus.stub();
	c.set_ubus_response('dhcp', 'ipv6leases', reply);
	return fn(c);
}

// expires_at is the time of the read plus `valid`, so each run compares it apart.
function without_expiry(list) { return map(list, (e) => { let o = { ...e }; delete o.expires_at; return o; }); }

// v4 (#320): dhcp/leases6 merged into dhcp/leases with ?family=v6.
t.describe('dhcp.leases merged endpoint (#320)', () => {
	function ctx() { return { request_id: "01hx0000000000000000000000" }; }

	t.it('id_field is mac for v4 and ip for v6', () => {
		t.assert_equal(leases.id_field({}), "mac");
		t.assert_equal(leases.id_field(null), "mac");
		t.assert_equal(leases.id_field({ family: "v6" }), "ip");
	});

	t.it('get_one with family=v6 finds an entry by ip', () => {
		let h = handler.make_collection({
			package: "dhcp", type: "lease",
			id_field: (q) => (q != null && q.family == "v6") ? "ip" : "mac",
			list_fn: function(conn, query) {
				return (query != null && query.family == "v6")
					? [ { ip: "2001:db8::1", duid: "aa" } ] : [ { mac: "aa:bb", ip: "192.0.2.1" } ];
			},
		});
		let c = bus.stub();
		let r = h.get_one(c, ctx(), "2001:db8::1", { family: "v6" });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.ip, "2001:db8::1");
		t.assert_equal(h.get_one(c, ctx(), "aa:bb", {}).status, 200);
		t.assert_equal(h.get_one(c, ctx(), "2001:db8::1", {}).status, 404);
	});
});

t.describe('dhcp/leases?family=v6 lists what odhcpd_leases reads', () => {
	t.it('from ubus call dhcp ipv6leases', () => {
		t.assert_deep_equal(without_expiry(with_reply(REPLY, (c) => leases.list_fn(c, { family: "v6" }))),
		                    without_expiry(with_reply(REPLY, (c) => odhcpd_leases.read(c))));
		t.assert_equal(length(with_reply(REPLY, (c) => leases.list_fn(c, { family: "v6" }))), 5);
	});
});

t.describe('odhcpd_leases.read', () => {
	t.it('gives one entry for each address or prefix of a bound lease', () => {
		t.assert_deep_equal(without_expiry(with_reply(REPLY, (c) => odhcpd_leases.read(c))), [
			{ duid: "000300019e09e3b126e0", iaid: "615f3ec7", hostname: "router-1", interface: "uapi6a",
			  ia_type: "IA_NA", ip: "fd99:6::aed", prefix_length: null },
			{ duid: "00010001aabbccddeeff", iaid: "1", hostname: null, interface: "br-lan",
			  ia_type: "IA_PD", ip: "fd99:7:100::", prefix_length: 56 },
			{ duid: "00030001aabbccddee00", iaid: "d1390e7b", hostname: "laptop", interface: "br-lan",
			  ia_type: "IA_NA", ip: "fd99:6::b", prefix_length: null },
			{ duid: "00030001aabbccddee00", iaid: "d1390e7b", hostname: "laptop", interface: "br-lan",
			  ia_type: "IA_NA", ip: "fd99:6::c", prefix_length: null },
			{ duid: "00030001aabbccddee02", iaid: "4", hostname: "my host\\x01\\x5c\\xff", interface: "br-lan",
			  ia_type: "IA_NA", ip: "fd99:6::e", prefix_length: null },
		]);
	});

	t.it('reads expires_at as the time of the read plus valid, and null for a lease that does not expire', () => {
		let before = time();
		let r = with_reply(REPLY, (c) => odhcpd_leases.read(c));
		let after = time();
		t.assert_true(r[0].expires_at >= before + 7200 && r[0].expires_at <= after + 7200);
		t.assert_equal(r[1].expires_at, null);
	});

	t.it('reads no lease when odhcpd does not run', () => {
		t.assert_deep_equal(with_reply({ _error: 'Not found' }, (c) => odhcpd_leases.read(c)), []);
		t.assert_deep_equal(with_reply(null, (c) => odhcpd_leases.read(c)), []);
	});
});

t.describe('odhcpd_leases.escape_hostname', () => {
	t.it('escapes control bytes, the backslash and invalid UTF-8 as rpcd-mod-luci does, and keeps valid UTF-8', () => {
		let e = odhcpd_leases.escape_hostname;
		t.assert_equal(e("foo!"), "foo!");
		t.assert_equal(e("caf" + chr(0xc3, 0xa9)), "caf" + chr(0xc3, 0xa9));
		t.assert_equal(e("a" + chr(0x1b) + "[2J" + chr(0x7f)), "a\\x1b[2J\\x7f");
		t.assert_equal(e("x\\x20"), "x\\x5cx20");
		t.assert_equal(e("bad" + chr(0xc3)), "bad\\xc3");
		t.assert_equal(e(chr(0xc0, 0x80)), "\\xc0\\x80");
		t.assert_equal(e(chr(0xed, 0xa0, 0x80)), "\\xed\\xa0\\x80");
		t.assert_equal(e(chr(0xf4, 0x90, 0x80, 0x80)), "\\xf4\\x90\\x80\\x80");
	});
});

t.describe('dhcp/servers counts the DHCPv6 leases of its interface', () => {
	let runtime = (status) => with_reply(REPLY, (c) => {
		c.set_ubus_response('network.interface.lan', 'status', status);
		return servers.fromUci({ '.type': 'dhcp', '.name': 'lan', interface: 'lan' }, c).runtime;
	});
	t.it('on the device that netifd reports for the interface, once for a lease of two addresses', () => {
		t.assert_equal(runtime({ up: true, l3_device: 'br-lan' }).active_leases_v6_iface, 3);
		t.assert_equal(runtime({ up: true, l3_device: 'uapi6a' }).active_leases_v6_iface, 1);
		t.assert_equal(runtime({ up: false }).active_leases_v6_iface, 0);
	});
	// The stock `config dhcp wan` names an interface that a device without a wan port lacks.
	t.it('as 0 for an interface that netifd does not know, and keeps the v4 count', () => {
		let r = runtime({ _error: 'Not found' });
		t.assert_equal(r.active_leases_v6_iface, 0);
		t.assert_equal(type(r.active_leases_v4_box_total), 'int');
	});
});
