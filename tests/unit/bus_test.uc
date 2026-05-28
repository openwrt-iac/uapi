let t = require('harness');
let ubus = require('bus');

t.describe('ubus.stub, ubus call', () => {
	t.it('records each call with normalized args', () => {
		let c = ubus.stub();
		c.call('system', 'info');
		c.call('network', 'reload', { wait: 1 });
		t.assert_deep_equal(c._state.ubus_calls, [
			['system', 'info', {}],
			['network', 'reload', { wait: 1 }],
		]);
	});

	t.it('returns programmed responses', () => {
		let c = ubus.stub({ ubus: { 'system info': { uptime: 42 } } });
		t.assert_deep_equal(c.call('system', 'info'), { uptime: 42 });
	});

	t.it('returns null when no response is programmed', () => {
		let c = ubus.stub();
		t.assert_equal(c.call('whatever', 'thing'), null);
	});

	t.it('supports function responses that see the args', () => {
		let c = ubus.stub({
			ubus: {
				'svc m': function(args) { return { echoed: args.x }; }
			}
		});
		t.assert_deep_equal(c.call('svc', 'm', { x: 7 }), { echoed: 7 });
	});

	t.it('throws when the programmed response has _error', () => {
		let c = ubus.stub({ ubus: { 'network reload': { _error: 'kaboom' } } });
		t.assert_throws(() => c.call('network', 'reload'));
	});

	t.it('set_ubus_response programs responses at runtime', () => {
		let c = ubus.stub();
		c.set_ubus_response('fw4', 'reload', { ok: true });
		t.assert_deep_equal(c.call('fw4', 'reload'), { ok: true });
	});
});

t.describe('ubus.stub, uci read', () => {
	t.it('uci_get returns null for missing package, section, or option', () => {
		let c = ubus.stub();
		t.assert_equal(c.uci_get('network', 'lan', 'proto'), null);
		t.assert_equal(c.uci_get('network', 'lan'), null);
	});

	t.it('uci_get returns the option value when present', () => {
		let c = ubus.stub({
			uci: { network: { lan: { proto: 'static', ipaddr: '10.0.0.1' } } }
		});
		t.assert_equal(c.uci_get('network', 'lan', 'proto'), 'static');
		t.assert_equal(c.uci_get('network', 'lan', 'missing'), null);
	});

	t.it('uci_get without option returns the whole section', () => {
		let c = ubus.stub({
			uci: { sys: { main: { hostname: 'r1' } } }
		});
		t.assert_deep_equal(c.uci_get('sys', 'main'), { hostname: 'r1' });
	});
});

t.describe('ubus.stub, uci mutations', () => {
	t.it('uci_set creates the section if absent and records the op', () => {
		let c = ubus.stub();
		c.uci_set('network', 'lan', 'proto', 'static');
		t.assert_equal(c._state.uci.network.lan.proto, 'static');
		t.assert_deep_equal(c._state.uci_ops[0],
		                    ['set', 'network', 'lan', 'proto', 'static']);
	});

	t.it('uci_add generates non-colliding anonymous names', () => {
		let c = ubus.stub();
		let a = c.uci_add('firewall', 'rule');
		let b = c.uci_add('firewall', 'rule');
		t.assert_true(a != b);
		t.assert_match(a, /^cfg[0-9a-f]{6}$/);
		t.assert_equal(c._state.uci.firewall[a]['.type'], 'rule');
	});

	t.it('uci_rename moves a section and records the op', () => {
		let c = ubus.stub({
			uci: { firewall: { cfg00 : { '.type': 'rule', target: 'ACCEPT' } } }
		});
		t.assert_true(c.uci_rename('firewall', 'cfg00', 'r_01hx'));
		t.assert_equal(c._state.uci.firewall.cfg00, null);
		t.assert_equal(c._state.uci.firewall.r_01hx.target, 'ACCEPT');
	});

	t.it('uci_rename returns false when the source section is absent', () => {
		let c = ubus.stub();
		t.assert_false(c.uci_rename('firewall', 'nope', 'whatever'));
	});

	t.it('uci_delete with option deletes that option only', () => {
		let c = ubus.stub({
			uci: { net: { lan: { proto: 'static', ipaddr: '1.2.3.4' } } }
		});
		c.uci_delete('net', 'lan', 'ipaddr');
		t.assert_deep_equal(c._state.uci.net.lan, { proto: 'static' });
	});

	t.it('uci_delete without option deletes the whole section', () => {
		let c = ubus.stub({
			uci: { net: { lan: { proto: 'static' } } }
		});
		c.uci_delete('net', 'lan');
		t.assert_equal(c._state.uci.net.lan, null);
	});

	t.it('uci_commit and uci_revert just record their ops', () => {
		let c = ubus.stub();
		c.uci_commit('firewall');
		c.uci_revert('network');
		t.assert_deep_equal(c._state.uci_ops, [
			['commit', 'firewall'],
			['revert', 'network'],
		]);
	});
});

t.describe('ubus.stub, snapshot round-trip', () => {
	t.it('uci_export then uci_import restores the package state', () => {
		let c = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } }
		});
		let snap = c.uci_export('fw');
		c.uci_set('fw', 'r1', 'target', 'DROP');
		t.assert_equal(c._state.uci.fw.r1.target, 'DROP');
		c.uci_import('fw', snap);
		t.assert_equal(c._state.uci.fw.r1.target, 'ACCEPT');
	});
});

t.describe('ubus.stub, uci_foreach', () => {
	let initial = {
		uci: {
			fw: {
				z1: { '.type': 'zone', name: 'lan' },
				r1: { '.type': 'rule', target: 'ACCEPT' },
				r2: { '.type': 'rule', target: 'DROP' },
			}
		}
	};

	t.it('iterates all sections when sec_type is null', () => {
		let c = ubus.stub(initial);
		let seen = [];
		c.uci_foreach('fw', null, function(s) { push(seen, s['.name']); });
		t.assert_equal(length(seen), 3);
	});

	t.it('filters by section type', () => {
		let c = ubus.stub(initial);
		let seen = [];
		c.uci_foreach('fw', 'rule', function(s) { push(seen, s['.name']); });
		t.assert_equal(length(seen), 2);
		sort(seen);
		t.assert_deep_equal(seen, ['r1', 'r2']);
	});

	t.it('stops early when the callback returns false', () => {
		let c = ubus.stub(initial);
		let count = 0;
		c.uci_foreach('fw', 'rule', function(s) {
			count++;
			return false;
		});
		t.assert_equal(count, 1);
	});

	t.it('returns true when iteration completes', () => {
		let c = ubus.stub(initial);
		let r = c.uci_foreach('fw', 'zone', function(s) { });
		t.assert_equal(r, true);
	});
});

t.describe('ubus.stub, isolation', () => {
	t.it('mutating initial state does not affect the stub after construction', () => {
		let initial_uci = { net: { lan: { proto: 'static' } } };
		let c = ubus.stub({ uci: initial_uci });
		initial_uci.net.lan.proto = 'dhcp';
		t.assert_equal(c.uci_get('net', 'lan', 'proto'), 'static');
	});
});
