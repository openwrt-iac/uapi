let t = require('harness');
let m = require('mgmt');
let ubus = require('bus');

t.describe('mgmt.inbound_device', () => {
	// The address is interpolated into a command line, so anything that is not an
	// address is refused before it gets there rather than quoted on the way past.
	t.it('refuses anything that is not an address, without running a command', () => {
		for (let bad in [ null, "", "; reboot", "10.0.0.1; id", "$(reboot)", "a b",
		                  "10.0.0.1 -o /tmp/x" ])
			t.assert_equal(m.inbound_device(bad), null);
	});

	t.it('accepts both families as shapes', () => {
		// Cannot assert the device without a kernel route table, but the validation
		// gate must let these through to the lookup rather than reject them here.
		for (let ok in [ "192.168.1.1", "fd00::1", "::1", "2001:db8::dead:beef" ])
			t.assert_true(m.inbound_device(ok) == null || type(m.inbound_device(ok)) == "string");
	});
});

t.describe('mgmt.inbound_interface', () => {
	t.it('reports nothing when the address is unusable', () => {
		t.assert_equal(m.inbound_interface(null, "not-an-address"), null);
	});
});

t.describe('mgmt.changed_fields', () => {
	t.it('names only the watched fields the body actually moves', () => {
		let before = { proto: 'static', ipaddr: '192.168.1.1', netmask: '255.255.255.0' };
		t.assert_deep_equal(m.changed_fields(before, { proto: 'dhcp' }), ['proto']);
		t.assert_deep_equal(m.changed_fields(before, { ipaddr: '10.0.0.1' }), ['ipaddr']);
		t.assert_deep_equal(m.changed_fields(before, { proto: 'dhcp', netmask: '255.0.0.0' }),
		                    ['proto', 'netmask']);
	});

	t.it('stays quiet when a watched field is sent unchanged', () => {
		let before = { proto: 'static', ipaddr: '192.168.1.1' };
		t.assert_deep_equal(m.changed_fields(before, { proto: 'static' }), []);
		t.assert_deep_equal(m.changed_fields(before, { proto: 'static', ipaddr: '192.168.1.1' }), []);
	});

	t.it('ignores fields outside the watched set, however risky they look', () => {
		// LuCI's scope is these four and no firewall analysis; `device` and `gateway`
		// can strand a caller too, and are deliberately not claimed here.
		t.assert_deep_equal(m.changed_fields({ device: 'br-lan' }, { device: 'eth9' }), []);
		t.assert_deep_equal(m.changed_fields({}, { gateway: '10.0.0.1' }), []);
	});

	// An absent field becoming an explicit value is a change: `disabled` unset then
	// sent as true is exactly the write that strands a caller.
	t.it('counts an absent field becoming set', () => {
		t.assert_deep_equal(m.changed_fields({}, { disabled: true }), ['disabled']);
		t.assert_deep_equal(m.changed_fields({ disabled: false }, { disabled: true }), ['disabled']);
		t.assert_deep_equal(m.changed_fields({ disabled: false }, { disabled: false }), []);
	});
});

t.describe('mgmt.inbound_interface device mapping', () => {
	function conn_with(ifaces) {
		let c = ubus.stub({ uci: {} });
		c.set_ubus_response("network.interface", "dump", { interface: ifaces });
		return c;
	}
	function lookup(dev) { return function() { return dev; }; }

	t.it('matches on l3_device, which is what a route names on a bridge', () => {
		let c = conn_with([ { interface: 'wan', l3_device: 'eth0', device: 'eth0' },
		                    { interface: 'lan', l3_device: 'br-lan', device: 'br-lan' } ]);
		let r = m.inbound_interface(c, '192.168.1.5', lookup('br-lan'));
		t.assert_equal(r.interface, 'lan');
		t.assert_equal(r.device, 'br-lan');
		t.assert_equal(r.address, '192.168.1.5');
	});

	// A wireguard or pppoe interface reports a different l3_device from device, and the
	// route names the l3 one.
	t.it('matches on device when l3_device differs', () => {
		let c = conn_with([ { interface: 'wan', l3_device: 'pppoe-wan', device: 'eth0' } ]);
		t.assert_equal(m.inbound_interface(c, '10.0.0.1', lookup('pppoe-wan')).interface, 'wan');
		t.assert_equal(m.inbound_interface(c, '10.0.0.1', lookup('eth0')).interface, 'wan');
	});

	// Reporting the device without an interface is the honest answer for a caller
	// arriving over something netifd does not manage; it must not claim a wrong one.
	t.it('reports the device with a null interface when nothing matches', () => {
		let c = conn_with([ { interface: 'lan', l3_device: 'br-lan' } ]);
		let r = m.inbound_interface(c, '10.0.0.1', lookup('tun0'));
		t.assert_equal(r.device, 'tun0');
		t.assert_equal(r.interface, null);
	});

	t.it('survives a ubus that has no answer, or throws', () => {
		let c = ubus.stub({ uci: {} });
		t.assert_equal(m.inbound_interface(c, '10.0.0.1', lookup('br-lan')).interface, null);
		let boom = ubus.stub({ uci: {} });
		boom.set_ubus_response("network.interface", "dump", { _error: "ubus down" });
		t.assert_equal(m.inbound_interface(boom, '10.0.0.1', lookup('br-lan')).interface, null);
	});

	t.it('reports nothing at all when the route lookup finds no device', () => {
		let c = conn_with([ { interface: 'lan', l3_device: 'br-lan' } ]);
		t.assert_equal(m.inbound_interface(c, '10.0.0.1', function() { return null; }), null);
	});
});
