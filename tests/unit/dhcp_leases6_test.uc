let t = require('harness');
let bus = require('bus');
let fs = require('fs');
let odhcpd_leases = require('odhcpd_leases');
let handler = require('handler');
let leases = loadfile('src/resources/dhcp.leases.uc')();
let servers = loadfile('src/resources/dhcp.servers.uc')();

// The first line is what odhcpd 25.12.5 wrote for a DHCPv6 client on a test interface. The others
// follow statefiles.c of odhcpd: a prefix delegation that does not expire, an address lease with two
// addresses, a DHCPv4 lease that odhcpd serves, the hosts line that it writes beside them, a short
// line, and the line of a client hostname that odhcpd of 25.12 writes unescaped.
const FILE = "# uapi6a 000300019e09e3b126e0 615f3ec7 router-1 1794128831 aed 128 fd99:6::aed/128\n" +
             "# br-lan 00010001aabbccddeeff 1 - -1 5 56 fd99:7:100::/56\n" +
             "# br-lan 00030001aabbccddee00 2 laptop 1794128900 b 128 fd99:6::b/128 fd99:6::c/128\n" +
             "# br-lan 52:54:00:12:34:56 ipv4 host 1794128831 a 32 192.168.1.10/32\n" +
             "fd99:6::aed\trouter-1\n" +
             "# br-lan short\n" +
             "# br-lan 00030001aabbccddee01 3 broken\\x20a 1794128831 1 128 fd99:6::d/128 1794128831 c 128 fd99:6::e/128\n";

function with_leasefile(content, fn) {
	let path = sprintf("/tmp/uapi-leases6-test.%d", time());
	fs.writefile(path, content);
	let r = fn(bus.stub({ uci: { dhcp: { odhcpd: { '.type': 'odhcpd', leasefile: path } } } }));
	fs.unlink(path);
	return r;
}

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
	t.it('from the leasefile of the odhcpd section', () => {
		t.assert_deep_equal(with_leasefile(FILE, (c) => leases.list_fn(c, { family: "v6" })),
		                    with_leasefile(FILE, (c) => odhcpd_leases.read(c)));
		t.assert_equal(length(with_leasefile(FILE, (c) => leases.list_fn(c, { family: "v6" }))), 4);
	});
});

t.describe('odhcpd_leases.read', () => {
	t.it('gives one entry for each address or prefix of a DHCPv6 lease, from the leasefile of the odhcpd section', () => {
		t.assert_deep_equal(with_leasefile(FILE, (c) => odhcpd_leases.read(c)), [
			{ duid: "000300019e09e3b126e0", iaid: "615f3ec7", hostname: "router-1", interface: "uapi6a",
			  ia_type: "IA_NA", ip: "fd99:6::aed", prefix_length: null, expires_at: 1794128831 },
			{ duid: "00010001aabbccddeeff", iaid: "1", hostname: null, interface: "br-lan",
			  ia_type: "IA_PD", ip: "fd99:7:100::", prefix_length: 56, expires_at: null },
			{ duid: "00030001aabbccddee00", iaid: "2", hostname: "laptop", interface: "br-lan",
			  ia_type: "IA_NA", ip: "fd99:6::b", prefix_length: null, expires_at: 1794128900 },
			{ duid: "00030001aabbccddee00", iaid: "2", hostname: "laptop", interface: "br-lan",
			  ia_type: "IA_NA", ip: "fd99:6::c", prefix_length: null, expires_at: 1794128900 },
		]);
	});

	t.it('reads no lease from a missing file', () => {
		let c = bus.stub({ uci: { dhcp: { odhcpd: { '.type': 'odhcpd', leasefile: '/nonexistent/uapi-leases6' } } } });
		t.assert_deep_equal(odhcpd_leases.read(c), []);
	});
});

t.describe('dhcp/servers counts the DHCPv6 leases of its interface', () => {
	let runtime = (status) => with_leasefile(FILE, (c) => {
		c.set_ubus_response('network.interface.lan', 'status', status);
		return servers.fromUci({ '.type': 'dhcp', '.name': 'lan', interface: 'lan' }, c).runtime;
	});
	t.it('on the device that netifd reports for the interface, once for a lease of two addresses', () => {
		t.assert_equal(runtime({ up: true, l3_device: 'br-lan' }).active_leases_v6_iface, 2);
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
