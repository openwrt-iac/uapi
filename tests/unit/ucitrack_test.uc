let t = require('harness');
let ucitrack = require('ucitrack');
let ubus = require('bus');

t.describe('ucitrack.reload_services, ucitrack present', () => {
	t.it('returns the init service named in /etc/config/ucitrack', () => {
		let c = ubus.stub({
			uci: { ucitrack: {
				net: { '.type': 'network', init: 'network' },
			} }
		});
		let r = ucitrack.reload_services(c, 'network');
		t.assert_true(r.known);
		t.assert_deep_equal(r.services, ['network']);
	});

	t.it('defaults init to the package name when option init is absent', () => {
		let c = ubus.stub({
			uci: { ucitrack: {
				fw: { '.type': 'firewall' },
			} }
		});
		let r = ucitrack.reload_services(c, 'firewall');
		t.assert_true(r.known);
		t.assert_deep_equal(r.services, ['firewall']);
	});

	t.it('chains affected packages into the reload list', () => {
		let c = ubus.stub({
			uci: { ucitrack: {
				ws: { '.type': 'wireless', affects: 'network' },
				net: { '.type': 'network', init: 'network' },
			} }
		});
		let r = ucitrack.reload_services(c, 'wireless');
		t.assert_true(r.known);
		t.assert_deep_equal(r.services, ['wireless', 'network']);
	});

	t.it('accepts affects as an array', () => {
		let c = ubus.stub({
			uci: { ucitrack: {
				fw: { '.type': 'firewall', init: 'firewall',
				      affects: ['qos', 'splash'] },
				q:  { '.type': 'qos', init: 'qos' },
				s:  { '.type': 'splash' },
			} }
		});
		let r = ucitrack.reload_services(c, 'firewall');
		t.assert_true(r.known);
		t.assert_deep_equal(r.services, ['firewall', 'qos', 'splash']);
	});

	t.it('de-duplicates services across affects chains', () => {
		let c = ubus.stub({
			uci: { ucitrack: {
				fw: { '.type': 'firewall', init: 'firewall', affects: 'firewall' },
			} }
		});
		let r = ucitrack.reload_services(c, 'firewall');
		t.assert_deep_equal(r.services, ['firewall']);
	});
});

t.describe('ucitrack.reload_services, fallback table', () => {
	t.it('uses the hardcoded fallback when ucitrack has no entry', () => {
		let c = ubus.stub();
		let r = ucitrack.reload_services(c, 'network');
		t.assert_true(r.known);
		t.assert_deep_equal(r.services, ['network']);
	});

	// procd reloads them on a LuCI save only while they run, and dnsmasq.init and unbound.init start
	// a stopped daemon on reload. Their triggers do not fire for a commit through libuci.
	t.it('reloads dnsmasq, odhcpd and unbound for dhcp only while procd runs them', () => {
		let r = ucitrack.reload_services(ubus.stub(), 'dhcp');
		t.assert_deep_equal([ r.known, r.services, r.if_running ], [ true, [], ['dnsmasq', 'odhcpd', 'unbound'] ]);
		t.assert_deep_equal(ucitrack.reload_services(ubus.stub(), 'firewall').if_running, []);
	});

	// odhcpd reads the network config and has a procd trigger on it, and a raw network write reloaded
	// only network. dnsmasq, unbound and wireless are left out on purpose, as docs/raw.md says.
	t.it('reloads odhcpd for network, after network, and nothing more for wireless', () => {
		let net = ucitrack.reload_services(ubus.stub(), 'network'), wifi = ucitrack.reload_services(ubus.stub(), 'wireless');
		t.assert_deep_equal([ net.services, net.if_running ], [ ['network'], ['odhcpd'] ]);
		t.assert_deep_equal([ wifi.services, wifi.if_running ], [ ['network'], [] ]);
	});

	t.it('reloads them for system too, after the system service', () => {
		let r = ucitrack.reload_services(ubus.stub(), 'system', { init_exists: () => false });
		t.assert_deep_equal([ r.known, r.services, r.if_running ], [ true, ['system'], ['dnsmasq', 'odhcpd', 'unbound'] ]);
	});

	t.it('maps wireless to network via fallback', () => {
		let c = ubus.stub();
		let r = ucitrack.reload_services(c, 'wireless');
		t.assert_deep_equal(r.services, ['network']);
	});
});

t.describe('ucitrack.reload_services, unknown package', () => {
	t.it('returns known=false with empty service list', () => {
		let c = ubus.stub();
		let r = ucitrack.reload_services(c, 'totally_unknown_pkg', {
			init_exists: function(pkg) { return false; },
		});
		t.assert_false(r.known);
		t.assert_deep_equal(r.services, []);
	});

	t.it('ucitrack entry wins over the fallback table', () => {
		let c = ubus.stub({
			uci: { ucitrack: {
				net: { '.type': 'network', init: 'custom_netd' },
			} }
		});
		let r = ucitrack.reload_services(c, 'network');
		t.assert_deep_equal(r.services, ['custom_netd']);
	});
});

t.describe('ucitrack.reload_services, init.d fallback', () => {
	t.it('falls back to /etc/init.d/<package> when ucitrack and FALLBACK are silent', () => {
		let c = ubus.stub();
		let r = ucitrack.reload_services(c, 'dropbear', {
			init_exists: function(pkg) { return pkg == 'dropbear'; },
		});
		t.assert_true(r.known);
		t.assert_deep_equal(r.services, ['dropbear']);
	});

	t.it('FALLBACK table wins over the init.d fallback', () => {
		let c = ubus.stub();
		let r = ucitrack.reload_services(c, 'dhcp', {
			init_exists: function(pkg) { return true; },
		});
		t.assert_deep_equal(r.services, []);
	});
});
