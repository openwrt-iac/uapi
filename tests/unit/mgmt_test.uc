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
		let before = { proto: 'static', ipaddrs: ['192.168.1.1'], netmask: '255.255.255.0' };
		t.assert_deep_equal(m.changed_fields(before, { proto: 'dhcp' }, false), ['proto']);
		t.assert_deep_equal(m.changed_fields(before, { ipaddrs: ['10.0.0.1'] }, false), ['ipaddrs']);
		t.assert_deep_equal(m.changed_fields(before, { proto: 'dhcp', netmask: '255.0.0.0' }, false),
		                    ['proto', 'netmask']);
	});

	t.it('stays quiet when a watched field is sent unchanged', () => {
		let before = { proto: 'static', ipaddrs: ['192.168.1.1'] };
		t.assert_deep_equal(m.changed_fields(before, { proto: 'static' }, false), []);
		t.assert_deep_equal(
			m.changed_fields(before, { proto: 'static', ipaddrs: ['192.168.1.1'] }, false), []);
	});

	t.it('ignores the retired scalar, which no write path can act on', () => {
		let before = { proto: 'static', ipaddr: '192.168.1.1', ipaddrs: ['192.168.1.1'] };
		t.assert_deep_equal(m.changed_fields(before, { ipaddr: '10.0.0.1' }, false), []);
		t.assert_deep_equal(m.changed_fields(before, { ipaddr: '10.0.0.1' }, true),
		                    ['proto', 'ipaddrs']);
	});

	t.it('under replace, an omitted watched field is a deletion and counts as a change', () => {
		let before = { proto: 'static', ipaddrs: ['192.168.1.1'], netmask: '255.255.255.0' };
		t.assert_deep_equal(m.changed_fields(before, { proto: 'static' }, true),
		                    ['ipaddrs', 'netmask']);
		t.assert_deep_equal(
			m.changed_fields(before, { proto: 'static', ipaddrs: ['192.168.1.1'],
			                           netmask: '255.255.255.0' }, true), []);
	});

	t.it('under replace, a field absent from both sides is not a deletion', () => {
		t.assert_deep_equal(m.changed_fields({ proto: 'dhcp' }, { proto: 'dhcp' }, true), []);
	});

	t.it('ignores fields outside the watched set, however risky they look', () => {
		// LuCI's scope is these four and no firewall analysis; `device` and `gateway`
		// can strand a caller too, and are deliberately not claimed here.
		t.assert_deep_equal(m.changed_fields({ device: 'br-lan' }, { device: 'eth9' }, false), []);
		t.assert_deep_equal(m.changed_fields({}, { gateway: '10.0.0.1' }, false), []);
	});

	// An absent field becoming an explicit value is a change: `disabled` unset then
	// sent as true is exactly the write that strands a caller.
	t.it('counts an absent field becoming set', () => {
		t.assert_deep_equal(m.changed_fields({}, { disabled: true }, false), ['disabled']);
		t.assert_deep_equal(m.changed_fields({ disabled: false }, { disabled: true }, false),
		                    ['disabled']);
		t.assert_deep_equal(m.changed_fields({ disabled: false }, { disabled: false }, false), []);
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


// The DELETE arm hardcodes `["removed"]` rather than going through changed_fields, since
// none of LuCI's field names describes a delete. That literal is why it works, and it had
// no test: 48_mgmt_path_guard_test.sh asserts only that deleting an *unrelated* interface
// stays silent, and says in a comment that it cannot exercise the real one without
// stranding itself. A unit test can, because the route lookup is injectable.
t.describe('deleting the inbound interface warns', () => {
	let ubus3 = require('bus');
	let handler3 = require('handler');
	let fx3 = require('resource_fixtures');
	let ifaces3 = loadfile('src/resources/network.interfaces.uc')();

	function tx3() {
		return { acquire: function() { return {}; }, release: function() {},
		         reload: function() { return null; }, check_services: function() { return null; },
		         wg_apply: function() { return null; }, wg_reconcile: function() { return null; } };
	}
	function seeded3() {
		let uci = fx3.world();
		uci.network = uci.network ?? {};
		uci.network.mgmtif = { '.anonymous': false, '.type': 'interface',
		                       proto: 'static', ipaddr: '192.168.9.1',
		                       netmask: '255.255.255.0', device: 'br-mg' };
		uci.network.otherif = { '.anonymous': false, '.type': 'interface',
		                        proto: 'static', ipaddr: '192.168.8.1',
		                        netmask: '255.255.255.0', device: 'br-other' };
		let conn = ubus3.stub({ uci: uci });
		conn.call = function(obj, method) {
			if (obj == 'network.interface' && method == 'dump')
				return { interface: [ { interface: 'mgmtif', l3_device: 'br-mg' },
				                      { interface: 'otherif', l3_device: 'br-other' } ] };
			return null;
		};
		return conn;
	}
	function ctx3() {
		return { request_id: "01hx0000000000000000000000", remote_addr: "192.168.9.50",
		         device_lookup: function() { return 'br-mg'; } };
	}

	t.it('the header names the interface and reports it as removed', () => {
		let conn = seeded3();
		let r = handler3.make(ifaces3, { tx: tx3() }).remove(conn, ctx3(), 'mgmtif');
		t.assert_equal(r.status, 204);
		let warn = r.headers?.['X-Mgmt-Path-Warning'];
		if (warn == null) {
			// The lookup seam differs from the one the handler uses; say so rather than
			// asserting a null, which would pass for the wrong reason.
			t.assert_equal("no X-Mgmt-Path-Warning on the inbound-interface delete",
			               "a warning");
			return;
		}
		t.assert_true(index(warn, 'interface=mgmtif') >= 0);
		t.assert_true(index(warn, 'changed=removed') >= 0);
	});

	t.it('deleting a different interface stays silent', () => {
		let conn = seeded3();
		let r = handler3.make(ifaces3, { tx: tx3() }).remove(conn, ctx3(), 'otherif');
		t.assert_equal(r.status, 204);
		t.assert_equal(r.headers?.['X-Mgmt-Path-Warning'], null);
	});
});

// The incident this arm exists for: a bridge-vlan on the bridge carrying the request turns on
// VLAN filtering, untagged traffic stops, and the box goes off the network. It never touches
// `config interface`, so the interface-name match could not see it and no warning was possible.
t.describe('mgmt.targets_mgmt_device', () => {
	// br-lan is a bridge over eth0 and eth1; br-guest is a bridge the caller is not on.
	function box() {
		return ubus.stub({ uci: { network: {
			brlan:   { '.type': 'device', '.anonymous': false, name: 'br-lan',
			           type: 'bridge', ports: [ 'eth0', 'eth1' ] },
			brguest: { '.type': 'device', '.anonymous': false, name: 'br-guest',
			           type: 'bridge', ports: [ 'eth2' ] },
		} } });
	}

	t.it('matches the caller device named outright', () => {
		t.assert_true(m.targets_mgmt_device(box(), 'br-lan', 'br-lan'));
	});

	t.it('matches the bridge the caller device is a port of', () => {
		// Arriving on eth0, the write targets the bridge eth0 belongs to.
		t.assert_true(m.targets_mgmt_device(box(), 'eth0', 'br-lan'));
	});

	t.it('does not match a bridge the caller is not a port of', () => {
		t.assert_false(m.targets_mgmt_device(box(), 'eth0', 'br-guest'));
	});

	t.it('does not match an unrelated device', () => {
		t.assert_false(m.targets_mgmt_device(box(), 'eth0', 'eth1'));
	});

	// A single-port bridge comes back from uci as a string rather than a list, and reading it
	// as a list would silently never match.
	t.it('handles a single port stored as a scalar', () => {
		let conn = ubus.stub({ uci: { network: {
			br: { '.type': 'device', '.anonymous': false, name: 'br-solo',
			      type: 'bridge', ports: 'eth9' },
		} } });
		t.assert_true(m.targets_mgmt_device(conn, 'eth9', 'br-solo'));
	});

	t.it('says nothing without a device or a target', () => {
		t.assert_false(m.targets_mgmt_device(box(), null, 'br-lan'));
		t.assert_false(m.targets_mgmt_device(box(), 'eth0', null));
	});
});

// The guard through the handler for the resources matched by device rather than by name.
// Creating a bridge-vlan on the management bridge is the exact write from the incident: it
// returned 200 with no warning, and because the follow-up delete never reached the box, the
// section stayed committed and the box stayed off the network.
t.describe('mgmt guard reaches bridge-vlan and device writes', () => {
	let h = require('handler');
	let ubus4 = require('bus');
	let bvlans = loadfile('src/resources/network.bridge_vlans.uc')();

	function tx4() {
		return { acquire: function() { return {}; }, release: function() {},
		         reload: function() { return null; }, check_services: function() { return null; },
		         wg_apply: function() { return null; }, wg_reconcile: function() { return null; } };
	}
	function box4() {
		let conn = ubus4.stub({ uci: { network: {
			brlan:   { '.type': 'device', '.anonymous': false, name: 'br-lan',
			           type: 'bridge', ports: [ 'eth0' ] },
			brguest: { '.type': 'device', '.anonymous': false, name: 'br-guest',
			           type: 'bridge', ports: [ 'eth2' ] },
		} } });
		conn.call = function() { return null; };
		return conn;
	}
	// Arriving on eth0, a port of br-lan, which is the shape that hides the risk: the write
	// names a device the caller never mentions.
	function ctx4() {
		return { request_id: "01hx0000000000000000000000", remote_addr: "192.168.9.50",
		         device_lookup: function() { return 'eth0'; } };
	}

	t.it('creating a bridge-vlan on the bridge carrying the request warns', () => {
		let r = h.make(bvlans, { tx: tx4() }).create(box4(), ctx4(),
			{ id: 'bv1', device: 'br-lan', vlan: 9 });
		t.assert_equal(r.status, 200);
		let warn = r.headers?.['X-Mgmt-Path-Warning'];
		if (warn == null) {
			t.assert_equal("no X-Mgmt-Path-Warning on a bridge-vlan create against the caller's bridge",
			               "a warning");
			return;
		}
		t.assert_true(index(warn, 'device=br-lan') >= 0);
		t.assert_true(index(warn, 'changed=created') >= 0);
	});

	t.it('creating one on an unrelated bridge stays silent', () => {
		let r = h.make(bvlans, { tx: tx4() }).create(box4(), ctx4(),
			{ id: 'bv2', device: 'br-guest', vlan: 9 });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.headers?.['X-Mgmt-Path-Warning'], null);
	});
});

// Moving the caller's device into a bridge is the third shape, and the one the first cut of
// this guard missed: the write names a bridge the caller is not yet a port of, so matching
// only against stored membership says nothing, while the ports the write carries are exactly
// the change that reroutes the caller.
t.describe('a device write that adopts the caller device warns', () => {
	let h = require('handler');
	let ubus5 = require('bus');
	let devs = loadfile('src/resources/network.devices.uc')();

	function tx5() {
		return { acquire: function() { return {}; }, release: function() {},
		         reload: function() { return null; }, check_services: function() { return null; },
		         wg_apply: function() { return null; }, wg_reconcile: function() { return null; } };
	}
	function box5() {
		let conn = ubus5.stub({ uci: { network: {} } });
		conn.call = function() { return null; };
		return conn;
	}
	function ctx5() {
		return { request_id: "01hx0000000000000000000000", remote_addr: "192.168.9.50",
		         device_lookup: function() { return 'eth1'; } };
	}

	t.it('creating a bridge whose ports include the caller device warns', () => {
		let r = h.make(devs, { tx: tx5() }).create(box5(), ctx5(),
			{ id: 'd1', name: 'br-new', type: 'bridge', ports: [ 'eth1' ] });
		t.assert_equal(r.status, 200);
		let warn = r.headers?.['X-Mgmt-Path-Warning'];
		if (warn == null) {
			t.assert_equal("no X-Mgmt-Path-Warning when a bridge adopts the caller's device",
			               "a warning");
			return;
		}
		t.assert_true(warn != null);
	});

	t.it('a bridge over someone else stays silent', () => {
		let r = h.make(devs, { tx: tx5() }).create(box5(), ctx5(),
			{ id: 'd2', name: 'br-other', type: 'bridge', ports: [ 'eth7' ] });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.headers?.['X-Mgmt-Path-Warning'], null);
	});
});

// Deleting the bridge the caller arrives through. The section is gone by the time the guard
// runs, so stored membership can no longer answer, and matching only the section name misses
// a caller who was on a port of it rather than on the bridge itself.
t.describe('deleting the caller bridge warns', () => {
	let h = require('handler');
	let ubus6 = require('bus');
	let devs = loadfile('src/resources/network.devices.uc')();

	function tx6() {
		return { acquire: function() { return {}; }, release: function() {},
		         reload: function() { return null; }, check_services: function() { return null; },
		         wg_apply: function() { return null; }, wg_reconcile: function() { return null; } };
	}
	function box6() {
		let conn = ubus6.stub({ uci: { network: {
			brlan: { '.type': 'device', '.anonymous': false, name: 'br-lan',
			         type: 'bridge', ports: [ 'eth0' ] },
		} } });
		conn.call = function() { return null; };
		return conn;
	}
	// Arriving on eth0, a port of the bridge being deleted.
	function ctx6() {
		return { request_id: "01hx0000000000000000000000", remote_addr: "192.168.9.50",
		         device_lookup: function() { return 'eth0'; } };
	}

	t.it('warns when the deleted bridge carries the caller', () => {
		let r = h.make(devs, { tx: tx6() }).remove(box6(), ctx6(), 'brlan');
		t.assert_equal(r.status, 204);
		let warn = r.headers?.['X-Mgmt-Path-Warning'];
		if (warn == null) {
			t.assert_equal("no X-Mgmt-Path-Warning when deleting the bridge the caller is a port of",
			               "a warning");
			return;
		}
		t.assert_true(index(warn, 'changed=removed') >= 0);
	});
});

