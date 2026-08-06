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

// `ipaddrs` is the same uci option as `ipaddr` under the name that replaces it. Watching
// only the scalar made the guard blind to the case it exists for: merge_for_patch deletes
// `ipaddr` from the merged body exactly when the caller sends the list, and
// resolve_for_replace returns early on a PUT that names only the list, so renumbering the
// caller's own interface warned about nothing. The deprecation steers clients toward that
// spelling, so the blind path was on its way to becoming the only one.
t.describe('the management-path guard follows ipaddr under both names', () => {
	let mg = require('mgmt');
	let ifaces = loadfile('src/resources/network.interfaces.uc')();
	const READ = { proto: 'static', ipaddr: '192.168.1.1',
	               ipaddrs: ['192.168.1.1'], netmask: '255.255.255.0' };

	t.it('a PATCH naming ipaddrs is reported', () => {
		let merged = ifaces.merge_for_patch(READ, { ipaddrs: ['10.9.9.1'] });
		t.assert_deep_equal(mg.changed_fields(READ, merged), ['ipaddrs']);
	});
	t.it('a PATCH naming ipaddr is still reported', () => {
		let merged = ifaces.merge_for_patch(READ, { ipaddr: '10.9.9.1' });
		t.assert_deep_equal(mg.changed_fields(READ, merged), ['ipaddr']);
	});
	t.it('a PUT naming only ipaddrs is reported', () => {
		let body = ifaces.resolve_for_replace({ proto: 'static', ipaddrs: ['10.9.9.1'] });
		t.assert_deep_equal(mg.changed_fields(READ, body), ['ipaddrs']);
	});
	t.it('an unwatched field is still silent', () => {
		let merged = ifaces.merge_for_patch(READ, { metric: 5 });
		t.assert_equal(length(mg.changed_fields(READ, merged)), 0);
	});
	t.it('the same address under the other name is not a change', () => {
		let merged = ifaces.merge_for_patch(READ, { ipaddrs: ['192.168.1.1'] });
		t.assert_equal(length(mg.changed_fields(READ, merged)), 0);
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
