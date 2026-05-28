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

	t.it('maps dhcp to dnsmasq via fallback', () => {
		let c = ubus.stub();
		let r = ucitrack.reload_services(c, 'dhcp');
		t.assert_deep_equal(r.services, ['dnsmasq']);
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
		let r = ucitrack.reload_services(c, 'totally_unknown_pkg');
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
