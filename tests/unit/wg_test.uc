let t = require('harness');
let ubus = require('bus');
let wg = require('wg');

const PK = 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=';

// endpoint_host is caller-supplied free-form text that ends up in a shell command,
// so this is the only thing standing between a hostname and command execution.
// Same idiom as LuCI's wireguard backend.
t.describe('wg.shellquote', () => {
	t.it('wraps a plain value in single quotes', () => {
		t.assert_equal(wg.shellquote("vpn.example.org"), "'vpn.example.org'");
	});
	t.it('neutralises a command substitution', () => {
		t.assert_equal(wg.shellquote("$(reboot)"), "'$(reboot)'");
	});
	t.it('escapes an embedded single quote so the quoting cannot be broken out of', () => {
		t.assert_equal(wg.shellquote("a'b"), "'a'\\''b'");
	});
	t.it('escapes every embedded quote, not just the first', () => {
		t.assert_equal(wg.shellquote("a'b'c"), "'a'\\''b'\\''c'");
	});
	t.it('renders null as an empty quoted string', () => {
		t.assert_equal(wg.shellquote(null), "''");
	});
});

t.describe('wg.interfaces_of', () => {
	t.it('dedups while preserving first-seen order', () => {
		t.assert_deep_equal(wg.interfaces_of([
			{ iface: "wgB" }, { iface: "wgA" }, { iface: "wgB" },
		]), ["wgB", "wgA"]);
	});
	t.it('ignores ops with no interface', () => {
		t.assert_deep_equal(wg.interfaces_of([{ action: "set" }, { iface: "wg1" }]), ["wg1"]);
	});
	t.it('is empty for no ops', () => {
		t.assert_deep_equal(wg.interfaces_of([]), []);
	});
});

t.describe('wg.to_peer', () => {
	t.it('reads the fields off a uci section', () => {
		let p = wg.to_peer({
			public_key: PK, allowed_ips: ['10.0.0.2/32'],
			endpoint_host: 'vpn.example.org', endpoint_port: '51820',
			persistent_keepalive: '25', preshared_key: 'psk',
		});
		t.assert_equal(p.public_key, PK);
		t.assert_deep_equal(p.allowed_ips, ['10.0.0.2/32']);
		t.assert_equal(p.endpoint_host, 'vpn.example.org');
		t.assert_equal(p.preshared_key, 'psk');
	});

	// uci collapses a single-element list to a scalar on read, so a peer with one
	// allowed_ips entry arrives as a string and would otherwise be iterated
	// character by character.
	t.it('lifts a scalar allowed_ips into a list', () => {
		t.assert_deep_equal(wg.to_peer({ allowed_ips: '10.0.0.2/32' }).allowed_ips,
		                    ['10.0.0.2/32']);
	});
	t.it('yields an empty list when allowed_ips is absent', () => {
		t.assert_deep_equal(wg.to_peer({}).allowed_ips, []);
	});
});

// These assert the paths that decide NOT to run wg, which is what makes them
// testable off-device: reaching the command would fail on a box without wg and
// surface as an error string rather than null.
t.describe('wg.apply', () => {
	function down_conn() {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.wg1', 'status', { up: false });
		return c;
	}

	t.it('does nothing when there are no ops', () => {
		let c = ubus.stub();
		t.assert_equal(wg.apply(c, []), null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});

	// A down interface holds no peer state and ifup reads the peers from uci, so
	// there is nothing to apply.
	t.it('skips ops for an interface that is down', () => {
		t.assert_equal(wg.apply(down_conn(), [
			{ iface: "wg1", action: "set", public_key: PK, allowed_ips: ['10.0.0.2/32'] },
		]), null);
	});

	// An interface netifd does not know is the same case, and it is how a peer
	// orphaned by deleting its parent stays deletable instead of failing the write.
	t.it('skips ops for an interface netifd does not know', () => {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.gone', 'status', { _error: 'Not found' });
		t.assert_equal(wg.apply(c, [
			{ iface: "gone", action: "remove", public_key: PK },
		]), null);
	});

	t.it('checks each interface once however many ops it has', () => {
		let c = down_conn();
		wg.apply(c, [
			{ iface: "wg1", action: "remove", public_key: PK },
			{ iface: "wg1", action: "remove", public_key: PK },
			{ iface: "wg1", action: "remove", public_key: PK },
		]);
		let status = filter(c._state.ubus_calls, function(x) { return x[1] == "status"; });
		t.assert_equal(length(status), 1);
	});

	t.it('refuses an interface name that could escape into a command', () => {
		let c = ubus.stub();
		let err = wg.apply(c, [{ iface: "wg1; reboot", action: "remove", public_key: PK }]);
		t.assert_true(err != null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});
});

t.describe('wg.reconcile', () => {
	t.it('does nothing for an empty interface list', () => {
		let c = ubus.stub();
		t.assert_equal(wg.reconcile(c, []), null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});

	t.it('skips an interface that is down', () => {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.wg1', 'status', { up: false });
		t.assert_equal(wg.reconcile(c, ["wg1"]), null);
	});

	t.it('skips a name that could escape into a command', () => {
		let c = ubus.stub();
		t.assert_equal(wg.reconcile(c, ["wg1 && reboot"]), null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});
});

// route_allowed_ips asks netifd to install a route per allowed IP from its proto
// handler, so a peer-level apply has to install them or the peer sits in the
// kernel with no path to it. The mapping mirrors wireguard.sh.
t.describe('wg route prefixes', () => {
	t.it('keeps a prefix as written and turns a bare address into a host route', () => {
		t.assert_deep_equal(wg.route_prefixes(['10.0.0.0/24', '10.0.1.5'], true),
		                    [{ prefix: '10.0.0.0/24', v6: false },
		                     { prefix: '10.0.1.5/32', v6: false }]);
	});

	t.it('uses /128 for a bare IPv6 address', () => {
		t.assert_deep_equal(wg.route_prefixes(['fd00::1'], true),
		                    [{ prefix: 'fd00::1/128', v6: true }]);
	});

	t.it('marks an IPv6 prefix so the apply uses ip -6', () => {
		t.assert_true(wg.route_prefixes(['fd00:90::/64'], true)[0].v6);
	});

	// The flag defaults to false, and a peer without it gets no routes at all,
	// which is what netifd does.
	t.it('yields nothing when route_allowed_ips is not set', () => {
		t.assert_deep_equal(wg.route_prefixes(['10.0.0.0/24'], false), []);
	});

	t.it('skips entries that are not addresses or prefixes', () => {
		t.assert_deep_equal(wg.route_prefixes(['not-an-ip', '10.0.0.0/24'], true),
		                    [{ prefix: '10.0.0.0/24', v6: false }]);
	});

	t.it('tolerates a missing allowed_ips list', () => {
		t.assert_deep_equal(wg.route_prefixes(null, true), []);
	});

	// The catch-all forms are real: peers on production routers carry
	// allowed_ips=0.0.0.0/0. The kernel prints those back as "default", which is
	// handled where kernel output is read rather than treated as an address here.
	t.it('handles the catch-all prefixes', () => {
		t.assert_deep_equal(wg.route_prefixes(['0.0.0.0/0'], true),
		                    [{ prefix: '0.0.0.0/0', v6: false }]);
		t.assert_deep_equal(wg.route_prefixes(['::/0'], true),
		                    [{ prefix: '::/0', v6: true }]);
	});

	t.it('rejects an out-of-range prefix length', () => {
		t.assert_deep_equal(wg.route_prefixes(['10.0.0.0/33'], true), []);
		t.assert_deep_equal(wg.route_prefixes(['fd00::/129'], true), []);
	});
});

// netifd puts an interface's routes in ip4table / ip6table when set, so a route
// installed into main would leave the peer without a path.
t.describe('wg.route_table', () => {
	function conn_with(opts) {
		let c = ubus.stub({ uci: { network: { wg1: { '.type': 'interface', ...opts } } } });
		return c;
	}
	t.it('is null when the interface sets no table', () => {
		t.assert_equal(wg.route_table(conn_with({}), 'wg1', false), null);
	});
	t.it('reads ip4table for v4 and ip6table for v6', () => {
		let c = conn_with({ ip4table: '77', ip6table: '88' });
		t.assert_equal(wg.route_table(c, 'wg1', false), '77');
		t.assert_equal(wg.route_table(c, 'wg1', true), '88');
	});
	t.it('refuses a table name that could escape into a command', () => {
		t.assert_equal(wg.route_table(conn_with({ ip4table: '77; reboot' }), 'wg1', false), null);
	});
	t.it('is null for an interface that does not exist', () => {
		t.assert_equal(wg.route_table(ubus.stub(), 'nope', false), null);
	});
});
