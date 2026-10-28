let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let wgp = loadfile('src/resources/network.wireguard_peers.uc')();

const PK = 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=';
const PK2 = 'TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=';

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	for (let e in (r.validate_new != null) ? r.validate_new(body) : []) push(out, e);
	return out;
}

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

function with_wg() {
	return ubus.stub({
		uci: {
			network: {
				wg1: { '.type': 'interface', '.anonymous': false,
				       proto: 'wireguard',
				       private_key: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=' },
				g_existing: {
					'.type': 'wireguard_wg1', '.anonymous': false,
					public_key: PK,
					allowed_ips: ['10.42.0.2/32'],
				},
			},
		},
	});
}

t.describe('network.wireguard_peers contract', () => {
	t.it('declares package, sentinel type, reload', () => {
		t.assert_equal(wgp.package, "network");
		t.assert_equal(wgp.type, "wireguard_peer");
		t.assert_deep_equal(wgp.reload, ["network"]);
	});
	t.it('type_predicate matches wireguard_<anything>', () => {
		t.assert_true(wgp.type_predicate("wireguard_wg1"));
		t.assert_true(wgp.type_predicate("wireguard_VPNMLV"));
		t.assert_false(wgp.type_predicate("wireguard"));
		t.assert_false(wgp.type_predicate("interface"));
		t.assert_false(wgp.type_predicate(null));
	});
	t.it('create_type uses body.interface for the uci section type', () => {
		t.assert_equal(wgp.create_type({ interface: 'wg1' }), 'wireguard_wg1');
	});
	t.it('id_prefix is g', () => {
		t.assert_equal(wgp.id_prefix, "g");
	});
});

t.describe('network.wireguard_peers.fromUci', () => {
	t.it('recovers parent interface from the dynamic type', () => {
		let r = wgp.fromUci({
			'.name': 'g_01hx', '.anonymous': false, '.type': 'wireguard_wg1',
			public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['10.42.0.2/32'],
		});
		t.assert_equal(r.interface, 'wg1');
		t.assert_equal(r.public_key, 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=');
		t.assert_deep_equal(r.allowed_ips, ['10.42.0.2/32']);
		t.assert_false(r.has_preshared_key);
	});
	t.it('masks preshared_key (omitted on read, only has_preshared_key surfaces)', () => {
		let r = wgp.fromUci({
			'.name': 'g_01hx', '.type': 'wireguard_wg1',
			public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			preshared_key: 'sssssssssssssssssssssssssssssssssssssssssss=',
			allowed_ips: ['10.42.0.2/32'],
		});
		t.assert_true(r.has_preshared_key);
		t.assert_equal(r.preshared_key, null);
	});
});

t.describe('network.wireguard_peers.validate', () => {
	t.it('rejects missing interface, public_key, allowed_ips', () => {
		let errs = wgp.validate({}, null);
		let fields = {};
		for (let e in errs) fields[e.field] = e.code;
		t.assert_equal(fields.interface, "required");
		t.assert_equal(fields.public_key, "required");
		t.assert_equal(fields.allowed_ips, "required");
	});
	t.it('rejects bad public_key shape', () => {
		let errs = full_validate(wgp, {
			interface: 'wg1', public_key: 'shortkey', allowed_ips: ['10.42.0.2/32'],
		}, null);
		let pk = filter(errs, function(e) { return e.field == "public_key"; });
		t.assert_equal(pk[0].code, "invalid_format");
	});
	t.it('rejects bad CIDR in allowed_ips', () => {
		let errs = wgp.validate({
			interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['999.0.0.0/24'],
		}, null);
		let ae = filter(errs, function(e) { return match(e.field, /^allowed_ips\[/); });
		t.assert_equal(ae[0].code, "invalid_format");
	});

	// Every shape below was checked against `wg set ... allowed-ips` on a real
	// interface. Requiring an IPv4 CIDR refused every IPv6 peer, so a dual-stack
	// tunnel could not be built through the API at all, and refused the bare
	// address form that `wg show` prints back and netifd turns into a host route.
	t.it('accepts every allowed_ips form wg accepts', () => {
		for (let a in ['10.0.0.0/24', '10.0.0.5', 'fd00::/64', 'fd00::1',
		               '0.0.0.0/0', '::/0']) {
			let errs = wgp.validate({
				interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
				allowed_ips: [a],
			}, null);
			let ae = filter(errs, function(e) { return match(e.field, /^allowed_ips\[/); });
			t.assert_equal(length(ae), 0, sprintf("%s should be accepted", a));
		}
	});

	t.it('still rejects what wg rejects', () => {
		for (let a in ['10.0.0.0/33', 'fd00::/129', 'garbage', '', '10.0.0.256']) {
			let errs = wgp.validate({
				interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
				allowed_ips: [a],
			}, null);
			let ae = filter(errs, function(e) { return match(e.field, /^allowed_ips\[/); });
			t.assert_equal(length(ae), 1, sprintf("%s should be rejected", a));
		}
	});

	t.it('refuses an IPv6 prefix with anything after its length', () => {
		let errs = wgp.validate({
			interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['::/0;id>x;'],
		}, null);
		t.assert_deep_equal(map(filter(errs, (e) => e.field == 'allowed_ips[0]'), (e) => e.code),
		                    [ 'invalid_format' ]);
	});

	// wireguard.sh expands the escapes of the whole config with `printf %b`, so plain-text `\n`
	// became a line break inside the config that `wg syncconf` reads. It also brackets every host
	// with a colon, and only those. Any other host is left to wg, as before.
	// wg cuts its config line at `#`, and finds a port after a bracketed host only when that host is
	// an IPv6 address.
	t.it('refuses an escape, a newline, a #, or a colon outside an IPv6 address in endpoint_host', () => {
		function host_errs(h) {
			return filter(full_validate(wgp, { interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			                                  allowed_ips: ['10.0.0.2/32'], endpoint_host: h }, null),
			              (e) => e.field == 'endpoint_host');
		}
		for (let h in [ 'vpn.example.com', '198.51.100.7', 'fd00::1', 'fe80::1%eth1', '1.2.3', '',
		                '[192.0.2.1]', '[vpn.example.com]', ' fd00::1 ' ])
			t.assert_equal(length(host_errs(h)), 0, h);
		for (let h in [ '192.0.2.1\\0072443', 'vpn.example.com\nx', '[fd00::1]', 'fd00::1]', 'vpn.example.com#x',
		                '192.0.2.1:51820', 'vpn:1', 'fd00::1x%eth1' ])
			t.assert_deep_equal(map(host_errs(h), (e) => e.code), [ 'invalid_format' ], h);
		// Each problem is its own error.
		t.assert_deep_equal(map(host_errs('fd00::1\\n[Peer]'), (e) => e.code), [ 'invalid_format', 'invalid_format' ]);
		t.assert_equal(length(host_errs('vpn.example.com\t')), 0);
		// wireguard.sh reads a list option as its words joined by spaces.
		t.assert_deep_equal(map(wgp.validate_new({ endpoint_host: [ '192.0.2.1\\nPeer' ] }), (e) => [ e.field, e.code ]),
		                    [ [ 'endpoint_host', 'invalid_format' ] ]);
	});

	// netifd and `ip route` read a prefix length in base 0, and wg in base 10.
	t.it('reports a prefix length with a leading zero, live when the peer is enabled and routes it', () => {
		let errs = (extra) => map(filter(wgp.validate_new({ allowed_ips: [ 'fd00::/010', '10.0.0.0/07', 'fd00::/0', '10.0.0.0/08', 'fd00::/007' ],
		                                                     ...extra }),
		                                 (e) => substr(e.field, 0, 11) == 'allowed_ips'),
		                          (e) => [ e.field, e.live ]);
		t.assert_deep_equal(errs({ route_allowed_ips: true }), [ [ 'allowed_ips[0]', true ], [ 'allowed_ips[3]', true ] ]);
		t.assert_deep_equal(errs({ route_allowed_ips: false }), [ [ 'allowed_ips[0]', false ], [ 'allowed_ips[3]', false ] ]);
		t.assert_deep_equal(errs({ route_allowed_ips: true, disabled: true }), [ [ 'allowed_ips[0]', false ], [ 'allowed_ips[3]', false ] ]);
	});

	t.it('reads a key as wg does, without whitespace, and refuses one that wg refuses', () => {
		let errs = (k) => map(wgp.validate_new({ public_key: k }), (e) => e.field);
		for (let k in [ PK, ' ' + PK + '\t', [ PK ] ])
			t.assert_deep_equal(errs(k), [], k);
		for (let k in [ substr(PK, 0, 42) + '5=', PK + '\n[Peer]', substr(PK, 0, 43) + '\\075', 'not-a-key' ])
			t.assert_deep_equal(errs(k), [ 'public_key' ], k);
	});

	t.it('refuses an escape in allowed_ips, which wireguard.sh expands too', () => {
		let errs = wgp.validate({ interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
		                          allowed_ips: [ '::/0\\n[Peer]\\nPublicKey=K\\nAllowedIPs=0.0.0.0\\0570' ] }, null);
		t.assert_deep_equal(map(filter(errs, (e) => e.field == 'allowed_ips[0]'), (e) => e.code), [ 'invalid_format' ]);
	});

	// LuCI's Enable writes only disabled=0, so a value stored on a disabled peer becomes live later.
	t.it('refuses a broken value that a write sends to a disabled peer', () => {
		t.assert_deep_equal(map(full_validate(wgp, { interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
		                                             allowed_ips: [ '::/0;id>x;' ], endpoint_host: '[fd00::1]', disabled: true }, null),
		                        (e) => e.field), [ 'allowed_ips[0]', 'endpoint_host' ]);
	});

	t.it('accepts a dual-stack peer', () => {
		let errs = wgp.validate({
			interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['10.42.0.2/32', 'fd00:42::2/128'],
		}, null);
		t.assert_equal(length(errs), 0);
	});
	t.it('reports conflict when parent interface has wrong proto', () => {
		let conn = ubus.stub({ uci: { network: {
			lan: { '.type': 'interface', proto: 'static' },
		} } });
		let errs = wgp.validate({
			interface: 'lan',
			public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['10.42.0.2/32'],
		}, conn);
		let ie = filter(errs, function(e) { return e.field == "interface"; });
		t.assert_equal(ie[0].code, "conflict");
	});
	t.it('accepts a valid peer against a wireguard interface', () => {
		let conn = ubus.stub({ uci: { network: {
			wg1: { '.type': 'interface', proto: 'wireguard' },
		} } });
		let errs = wgp.validate({
			interface: 'wg1',
			public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['10.42.0.2/32'],
			persistent_keepalive: 25,
		}, conn);
		t.assert_equal(length(errs), 0);
	});
});

t.describe('network.wireguard_peers via handler.make (dynamic-type plumbing)', () => {
	function make_handler() {
		return handler.make(wgp, {
			tx: {
				acquire: function() { return {}; },
				release: function() {},
				reload: function() { return null; },
				check_services: function() { return null; },
			},
		});
	}

	// The handler compares the errors of the peer before and after the write, so a merge PATCH that
	// leaves a stored host or key as it is is never refused for it by validation, and the sweep lists
	// the peer whether it is enabled or not. Enabling it is refused until a write replaces the value.
	// A PUT still carries a stored key into the schema check, as on main.
	t.it('a stored broken host or key blocks only the write that enables the peer', () => {
		for (let extra in [ { endpoint_host: '[fd00::1]' }, { endpoint_host: '192.0.2.1\\n[Peer]' },
		                    { preshared_key: 'K\\n[Peer]' } ]) {
			let c = with_wg();
			for (let k, v in extra) c._state.uci.network.g_existing[k] = v;
			let h = make_handler();
			t.assert_equal(length(h.sweep(c)), 1, extra);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x' }).status, 200, extra);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: true }).status, 200, extra);
			t.assert_equal(length(h.sweep(c)), 1, extra);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: false }).status, 422, extra);
		}
	});

	let fields_of = (r) => map(r.body?.errors ?? [], (e) => [ e.field, e.code ]);
	const UNUSABLE = [ { persistent_keepalive: '25x' }, { endpoint_host: '192.0.2.1', endpoint_port: 'nosuchservice' },
	                   { endpoint_host: '192.0.2.1', endpoint_port: '0' } ];

	t.it('a stored port or keepalive that wg cannot use does not block a write that leaves it as it is', () => {
		for (let stored in UNUSABLE) {
			let c = with_wg();
			for (let k, v in stored) c._state.uci.network.g_existing[k] = v;
			let h = make_handler();
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x' }).status, 200, stored);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: true }).status, 200, stored);
			for (let k, v in stored) t.assert_equal(c._state.uci.network.g_existing[k], v, stored);
			t.assert_equal(length(h.sweep(c)), 1, stored);
		}
	});

	t.it('enabling a peer that stores such a port or keepalive is refused for it', () => {
		for (let stored in UNUSABLE) {
			let c = with_wg();
			for (let k, v in { ...stored, disabled: '1' }) c._state.uci.network.g_existing[k] = v;
			let r = make_handler().patch(c, ctx(), 'g_existing', { disabled: false });
			t.assert_deep_equal(fields_of(r), [ [ (stored.endpoint_port != null) ? 'endpoint_port' : 'persistent_keepalive', 'out_of_range' ] ], stored);
		}
	});

	// wireguard.sh writes the port only with a host, and no peer without a key.
	t.it('a port that reads 0 is live only with a host, and a value only on a peer with a key', () => {
		let c = with_wg();
		for (let k, v in { endpoint_port: 'nosuchservice', disabled: '1' }) c._state.uci.network.g_existing[k] = v;
		let h = make_handler();
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: false }).status, 200);
		t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.1' })), [ [ 'endpoint_port', 'out_of_range' ] ]);
		t.assert_deep_equal(map(wgp.validate_new({ persistent_keepalive: -1 }), (e) => e.live), [ false ]);
		t.assert_deep_equal(map(wgp.validate_new({ persistent_keepalive: -1, public_key: PK }), (e) => e.live), [ true ]);
	});

	// The kernel apply sends an endpoint only with a port.
	t.it('a write that changes the host or the key of an enabled peer whose port reads 0 is refused', () => {
		for (let port in [ '0', 'nosuchservice' ]) {
			let c = with_wg();
			for (let k, v in { endpoint_host: '192.0.2.1', endpoint_port: port }) c._state.uci.network.g_existing[k] = v;
			let h = make_handler();
			t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.2' })), [ [ 'endpoint_port', 'out_of_range' ] ], port);
			t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { public_key: PK2 })), [ [ 'endpoint_port', 'out_of_range' ] ], port);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { endpoint_host: ' 192.0.2.1 ' }).status, 200, port);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { public_key: PK2, endpoint_port: 51820 }).status, 200, port);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.2', endpoint_port: 51820 }).status, 200, port);
		}
		let c = with_wg();
		for (let k, v in { endpoint_host: '192.0.2.1', endpoint_port: '0', disabled: '1' }) c._state.uci.network.g_existing[k] = v;
		t.assert_equal(make_handler().patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.2' }).status, 200);
	});

	t.it('a write that sends -1 or 0 is refused', () => {
		let h = make_handler();
		t.assert_deep_equal(fields_of(h.patch(with_wg(), ctx(), 'g_existing', { persistent_keepalive: -1 })), [ [ 'persistent_keepalive', 'out_of_range' ] ]);
		t.assert_deep_equal(fields_of(h.patch(with_wg(), ctx(), 'g_existing', { endpoint_host: '192.0.2.1', endpoint_port: 0 })), [ [ 'endpoint_port', 'out_of_range' ] ]);
		let c = with_wg();
		for (let k, v in { disabled: '1', endpoint_host: '192.0.2.1', endpoint_port: '51820' }) c._state.uci.network.g_existing[k] = v;
		t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { endpoint_port: 0 })), [ [ 'endpoint_port', 'out_of_range' ] ]);
		t.assert_deep_equal(fields_of(h.create(with_wg(), ctx(), { interface: 'wg1', public_key: PK2, allowed_ips: [ '10.42.0.9/32' ],
		                                                           persistent_keepalive: -1 })), [ [ 'persistent_keepalive', 'out_of_range' ] ]);
	});

	// toUci writes the number that the PUT sends. wg refuses -1 as it refuses the stored text, and a
	// stored decimal 0 is what it was, but wg takes port 0 where it cannot resolve the stored name.
	t.it('a PUT of the read stores only a port or keepalive that wg reads as it read the stored one', () => {
		let put_read = function(stored) {
			let c = with_wg();
			for (let k, v in stored) c._state.uci.network.g_existing[k] = v;
			let h = make_handler();
			let body = h.get_one(c, ctx(), 'g_existing').body;
			for (let k in [ 'id', 'managed', 'runtime', 'has_preshared_key' ]) delete body[k];
			let r = h.replace(c, ctx(), 'g_existing', body);
			return { r, c, read: h.get_one(c, ctx(), 'g_existing').body };
		};
		let p = put_read(UNUSABLE[0]);
		t.assert_equal(p.r.status, 200);
		t.assert_equal(p.c._state.uci.network.g_existing.persistent_keepalive, '-1');
		t.assert_equal(p.read.persistent_keepalive, -1);
		p = put_read(UNUSABLE[1]);
		t.assert_deep_equal(fields_of(p.r), [ [ 'endpoint_port', 'conflict' ] ]);
		t.assert_equal(p.c._state.uci.network.g_existing.endpoint_port, 'nosuchservice');
		for (let stored in [ ' 70000', '  ' ])
			t.assert_deep_equal(fields_of(put_read({ endpoint_host: '192.0.2.1', endpoint_port: stored }).r), [ [ 'endpoint_port', 'conflict' ] ], stored);
		for (let stored in [ UNUSABLE[2], { endpoint_host: '192.0.2.1', endpoint_port: ' +00' } ]) {
			p = put_read(stored);
			t.assert_equal(p.r.status, 200, stored);
			t.assert_equal(p.read.endpoint_port, 0, stored);
		}
	});

	t.it('a stored prefix length with a leading zero blocks only the write that routes it', () => {
		let conn = with_wg();
		conn._state.uci.network.g_existing.allowed_ips = [ 'fd00::/010' ];
		let h = make_handler();
		t.assert_equal(h.patch(conn, ctx(), 'g_existing', { description: 'x' }).status, 200);
		t.assert_equal(h.patch(conn, ctx(), 'g_existing', { route_allowed_ips: true }).status, 422);
	});

	t.it('a stored key with whitespace, which wg reads, does not block enabling the peer', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.public_key = PK + ' ';
		c._state.uci.network.g_existing.disabled = '1';
		t.assert_equal(make_handler().patch(c, ctx(), 'g_existing', { disabled: false }).status, 200);
	});

	t.it('refuses a key whose unused bits are not zero, which wg refuses', () => {
		let r = make_handler().create(with_wg(), ctx(), { interface: 'wg1', public_key: substr(PK, 0, 42) + '5=',
		                                                  allowed_ips: [ '10.42.0.9/32' ] });
		t.assert_equal(r.status, 422);
	});

	// allowed_ips keeps the rule it had on main: every write checks it, so the peer answers 422
	// rather than letting wg refuse it with a 500.
	t.it('a stored invalid allowed IP blocks every write until one replaces it', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.allowed_ips = [ '::/0\\n[Peer]\\nPublicKey=K\\nAllowedIPs=0.0.0.0\\0570' ];
		let h = make_handler();
		t.assert_equal(length(h.sweep(c)), 1);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x' }).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { allowed_ips: [ '10.42.0.2/32' ] }).status, 200);
	});

	// An error that the host already had is new when the write changes the host, so swapping one
	// injection for another is refused. wireguard.sh reads a list option as its words joined.
	t.it('a write that changes a broken host, or enables a peer with a list key, is refused', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.endpoint_host = 'a\nb';
		let h = make_handler();
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.1\\0072443\nPublicKey=X' }).status, 422);
		c = with_wg();
		c._state.uci.network.g_existing.disabled = '1';
		c._state.uci.network.g_existing.preshared_key = [ 'K\n[Peer]\nPublicKey=X' ];
		t.assert_equal(length(h.sweep(c)), 1);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: false }).status, 422);
	});

	// A PUT sends the read back, without its write-only keys and without `disabled` when the client
	// leaves the default out.
	t.it('a PUT is judged like a PATCH: a stored host it resends is old, and enabling is new', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.endpoint_host = '[fd00::1]';
		let h = make_handler();
		let body = h.get_one(c, ctx(), 'g_existing').body;
		for (let k in [ 'id', 'managed', 'runtime', 'has_preshared_key' ]) delete body[k];
		t.assert_equal(h.replace(c, ctx(), 'g_existing', { ...body, description: 'x' }).status, 200);
		t.assert_equal(h.replace(c, ctx(), 'g_existing', { ...body, disabled: true }).status, 200);
		let enable = { ...body };
		delete enable.disabled;
		t.assert_equal(h.replace(c, ctx(), 'g_existing', enable).status, 422);
		c._state.uci.network.g_existing.endpoint_host = [ '[fd00::1]', 'x' ];
		t.assert_equal(h.replace(c, ctx(), 'g_existing', { ...body, disabled: true, endpoint_host: '[fd00::1] x' }).status, 200);
	});

	t.it('a write to a disabled peer still refuses a broken value that it sends', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.disabled = '1';
		let h = make_handler();
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.1\\n[Peer]' }).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { allowed_ips: [ '::/0;id>x;' ] }).status, 422);
	});

	// preshared_key is masked on read, so a client that GETs a peer and PUTs it
	// back cannot send it. PUT is full-replace, so without the carry-forward the
	// key is deleted from uci and the tunnel loses it, with a 200 in reply.
	t.it('PUT does not erase a preshared_key the masked read view hid', () => {
		let h = make_handler();
		let c = with_wg();
		c.uci_set('network', 'g_existing', 'preshared_key',
		          'c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MDA=');
		let view = wgp.fromUci(c.uci_get('network', 'g_existing'), c);
		t.assert_equal(view.preshared_key, null);
		t.assert_true(view.has_preshared_key);

		let r = h.replace(c, ctx(), 'g_existing', {
			interface: 'wg1',
			public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['10.42.0.5/32'],
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(c.uci_get('network', 'g_existing', 'preshared_key'),
		               'c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MDA=');
	});

	t.it('PUT still replaces a preshared_key the client does send', () => {
		let h = make_handler();
		let c = with_wg();
		c.uci_set('network', 'g_existing', 'preshared_key',
		          'c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MDA=');
		let r = h.replace(c, ctx(), 'g_existing', {
			interface: 'wg1',
			public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['10.42.0.5/32'],
			preshared_key: 'bmV3c2VjcmV0bmV3c2VjcmV0bmV3c2VjcmV0bmV3c2U=',
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(c.uci_get('network', 'g_existing', 'preshared_key'),
		               'bmV3c2VjcmV0bmV3c2VjcmV0bmV3c2VjcmV0bmV3c2U=');
	});

	t.it('PUT response preserves the parent interface from the real uci type', () => {
		let h = make_handler();
		let c = with_wg();
		let r = h.replace(c, ctx(), 'g_existing', {
			interface: 'wg1',
			public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			allowed_ips: ['10.42.0.5/32'],
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.interface, 'wg1');
	});

	t.it('PATCH response preserves the parent interface from the real uci type', () => {
		let h = make_handler();
		let c = with_wg();
		let r = h.patch(c, ctx(), 'g_existing', { allowed_ips: ['10.42.0.6/32'] });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.interface, 'wg1');
	});
});

// wireguard.sh gives every enabled peer of an interface to one `wg syncconf`, so the write of the
// interface that makes its stored peers live is refused for a peer that wg refuses.
t.describe('network.interfaces refuses a write that makes a stored peer that wg refuses live', () => {
	let ifaces = loadfile('src/resources/network.interfaces.uc')();
	let h = handler.make(ifaces, { tx: {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	} });
	const WG = { proto: 'wireguard', private_key: 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=', addresses: [ '10.42.0.1/24' ] };
	const STATIC = { proto: 'static', ipaddr: [ '192.0.2.1/24' ] };
	const BAD = { g_ka: { persistent_keepalive: '25x' },
	              g_psk: { public_key: PK2, preshared_key: 'K\\n[Peer]', endpoint_host: '192.0.2.9', endpoint_port: 'nosuchservice' } };
	function world(iface, peers, parent) {
		let network = { [parent ?? 'wg1']: { '.type': 'interface', '.anonymous': false, ...iface } };
		for (let id, p in peers)
			network[id] = { '.type': 'wireguard_wg1', '.anonymous': false, public_key: PK, allowed_ips: [ '10.42.0.2/32' ], ...p };
		return ubus.stub({ uci: { network } });
	}
	let errs = (r) => map(r.body?.errors ?? [], (e) => [ e.field, e.code ]);

	t.it('a switch to wireguard names each peer that wg refuses and the fields, and no value', () => {
		let r = h.patch(world(STATIC, { ...BAD, g_ok: { public_key: PK2 } }), ctx(), 'wg1', WG);
		t.assert_deep_equal(errs(r), [ [ 'proto', 'conflict' ] ]);
		let m = r.body.errors[0].message;
		t.assert_true(index(m, 'g_ka (persistent_keepalive)') >= 0, m);
		t.assert_true(index(m, 'g_psk (preshared_key, endpoint_port)') >= 0, m);
		t.assert_true(index(m, 'g_ok') < 0 && index(m, '25x') < 0 && index(m, 'Peer]') < 0 && index(m, 'nosuchservice') < 0, m);
		// A peer write refuses a parent that is not on wireguard, so the way out is a disabled switch.
		t.assert_true(index(m, 'Switch with disabled true') >= 0, m);
	});

	t.it('a switch to wireguard passes when such a peer is disabled or has no key, or when every peer is clean', () => {
		t.assert_equal(h.patch(world(STATIC, { g_ka: { persistent_keepalive: '25x', disabled: '1' } }), ctx(), 'wg1', WG).status, 200);
		t.assert_equal(h.patch(world(STATIC, { g_ka: { persistent_keepalive: '25x', public_key: null } }), ctx(), 'wg1', WG).status, 200);
		t.assert_equal(h.patch(world(STATIC, { g_ok: {}, g_ok2: { public_key: PK2, persistent_keepalive: '25' } }), ctx(), 'wg1', WG).status, 200);
		t.assert_equal(h.patch(world(STATIC, BAD), ctx(), 'wg1', { ...WG, disabled: true }).status, 200);
	});

	// wg cannot parse such an allowed IP, and a peer write refuses it on every write.
	t.it('a switch to wireguard also refuses a stored allowed IP that wg cannot parse, on a peer that wg reads', () => {
		let r = h.patch(world(STATIC, { g_ip: { allowed_ips: [ '10.42.0.2/32', 'foo' ] } }), ctx(), 'wg1', WG);
		t.assert_deep_equal(errs(r), [ [ 'proto', 'conflict' ] ]);
		t.assert_true(index(r.body.errors[0].message, 'g_ip (allowed_ips[1])') >= 0, r.body.errors[0].message);
		for (let off in [ { disabled: '1' }, { public_key: null } ])
			t.assert_equal(h.patch(world(STATIC, { g_ip: { allowed_ips: [ 'foo' ], ...off } }), ctx(), 'wg1', WG).status, 200, off);
	});

	t.it('the way out that the message gives works: switch disabled, fix the peer, enable', () => {
		let ph = handler.make(wgp, { tx: {
			acquire: function() { return {}; }, release: function() {},
			reload: function() { return null; }, check_services: function() { return null; },
		} });
		let c = world(STATIC, { g_ka: BAD.g_ka });
		t.assert_equal(h.patch(c, ctx(), 'wg1', WG).status, 422);
		t.assert_equal(ph.patch(c, ctx(), 'g_ka', { persistent_keepalive: 25 }).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'wg1', { ...WG, disabled: true }).status, 200);
		t.assert_equal(ph.patch(c, ctx(), 'g_ka', { persistent_keepalive: 25 }).status, 200);
		t.assert_equal(h.patch(c, ctx(), 'wg1', { disabled: false }).status, 200);
	});

	t.it('a write of an interface already live on wireguard does not check its peers', () => {
		t.assert_equal(h.patch(world(WG, BAD), ctx(), 'wg1', { mtu: 1400 }).status, 200);
	});

	t.it('enabling a wireguard interface refuses such a peer on disabled, also a PUT that leaves disabled out', () => {
		let off = { ...WG, disabled: '1' };
		let r = h.patch(world(off, BAD), ctx(), 'wg1', { disabled: false });
		t.assert_deep_equal(errs(r), [ [ 'disabled', 'conflict' ] ]);
		t.assert_true(index(r.body.errors[0].message, 'Fix or disable each of them first') >= 0, r.body.errors[0].message);
		t.assert_deep_equal(errs(h.replace(world(off, BAD), ctx(), 'wg1', { proto: 'wireguard', addresses: WG.addresses })),
		                    [ [ 'disabled', 'conflict' ] ]);
		t.assert_equal(h.patch(world(off, BAD), ctx(), 'wg1', { mtu: 1400 }).status, 200);
	});

	t.it('a create checks the stored peers of the name that it sends', () => {
		let c = world(STATIC, BAD, 'lan');
		t.assert_deep_equal(errs(h.create(c, ctx(), { id: 'wg1', ...WG })), [ [ 'proto', 'conflict' ] ]);
	});

	// netifd cannot bring the interface up with a listen port that /etc/services does not resolve.
	t.it('a write that brings up an interface with a stored listen_port that reads -1 is refused for it', () => {
		let ports = (r) => filter(errs(r), (e) => e[0] == 'listen_port');
		t.assert_deep_equal(ports(h.patch(world({ ...WG, listen_port: '65536', disabled: '1' }), ctx(), 'wg1', { disabled: false })),
		                    [ [ 'listen_port', 'out_of_range' ] ]);
		t.assert_equal(h.patch(world({ ...WG, listen_port: '65536' }), ctx(), 'wg1', { mtu: 1400 }).status, 200);
		t.assert_equal(h.patch(world({ ...WG, listen_port: '65536', disabled: '1' }), ctx(), 'wg1', { mtu: 1400 }).status, 200);
	});

	// The read of proto static hides listen_port, and a PATCH keeps what it leaves out, so the switch
	// gave wireguard.sh a port name that wg cannot resolve, and the interface did not come up.
	const HAND = { proto: 'static', ipaddr: [ '10.9.0.1/24' ], listen_port: 'nosuchservice' };
	const TO_WG = { proto: 'wireguard', private_key: WG.private_key, addresses: [ '10.9.0.1/24' ] };
	t.it('a PATCH that switches to wireguard is refused for a stored listen_port that the old read hides and that reads -1', () => {
		let c = world(HAND);
		let r = h.patch(c, ctx(), 'wg1', TO_WG);
		t.assert_deep_equal(errs(r), [ [ 'listen_port', 'conflict' ] ]);
		let m = r.body.errors[0].message;
		t.assert_true(index(m, 'disabled true') >= 0 && index(m, 'null') >= 0 && index(m, 'nosuchservice') < 0, m);
		t.assert_equal(c._state.uci.network.wg1.proto, 'static');
		let jp = { ...ctx(), json_patch: true };
		t.assert_deep_equal(errs(h.patch(world(HAND), jp, 'wg1', [ { op: 'replace', path: '/proto', value: 'wireguard' },
		                                                           { op: 'add', path: '/private_key', value: WG.private_key },
		                                                           { op: 'add', path: '/addresses', value: TO_WG.addresses } ])),
		                    [ [ 'listen_port', 'conflict' ] ]);
	});

	t.it('the switch passes with a port or null, and a null removes the stored option', () => {
		let c = world(HAND);
		t.assert_equal(h.patch(c, ctx(), 'wg1', { ...TO_WG, listen_port: null }).status, 200);
		t.assert_false(exists(c._state.uci.network.wg1, 'listen_port'));
		c = world(HAND);
		t.assert_equal(h.patch(c, ctx(), 'wg1', { ...TO_WG, listen_port: 51820 }).status, 200);
		t.assert_equal(c._state.uci.network.wg1.listen_port, '51820');
	});

	t.it('the switch passes with disabled true, and the interface is enabled once the port is sent', () => {
		let c = world(HAND);
		t.assert_equal(h.patch(c, ctx(), 'wg1', { ...TO_WG, disabled: true }).status, 200);
		t.assert_deep_equal(errs(h.patch(c, ctx(), 'wg1', { disabled: false })), [ [ 'listen_port', 'out_of_range' ] ]);
		t.assert_equal(h.patch(c, ctx(), 'wg1', { disabled: false, listen_port: null }).status, 200);
		t.assert_false(exists(c._state.uci.network.wg1, 'listen_port'));
	});

	// A PUT removes every option that it does not write, so it does not bring up the stored value.
	t.it('the switch passes for a stored port that resolves, which it keeps, and a PUT, which removes the option', () => {
		let c = world({ ...HAND, listen_port: '51820' });
		t.assert_equal(h.patch(c, ctx(), 'wg1', TO_WG).status, 200);
		t.assert_equal(c._state.uci.network.wg1.listen_port, '51820');
		c = world(HAND);
		t.assert_equal(h.replace(c, ctx(), 'wg1', TO_WG).status, 200);
		t.assert_false(exists(c._state.uci.network.wg1, 'listen_port'));
	});

	// toUci clears listen_port when a write sends it as null, and a wireguard read without the option
	// reads null, so every PATCH would delete an option that is not there.
	t.it('a PATCH of a wireguard interface without listen_port does not write listen_port', () => {
		for (let body in [ { mtu: 1400 }, [ { op: 'remove', path: '/listen_port' } ] ]) {
			let c = world(WG);
			t.assert_equal(h.patch(c, type(body) == 'array' ? { ...ctx(), json_patch: true } : ctx(), 'wg1', body).status, 200, body);
			t.assert_deep_equal(filter(c._state.uci_ops, (op) => op[3] == 'listen_port'), [], body);
		}
	});

	// A JSON Patch remove names the field, and deletes the option, so the interface comes up without it.
	t.it('a JSON Patch that makes the interface live and removes /listen_port passes and deletes the option', () => {
		let jp = { ...ctx(), json_patch: true };
		let c = world({ ...WG, disabled: '1', listen_port: 'nosuchservice' });
		t.assert_equal(h.patch(c, jp, 'wg1', [ { op: 'replace', path: '/disabled', value: false },
		                                       { op: 'remove', path: '/listen_port' } ]).status, 200);
		t.assert_false(exists(c._state.uci.network.wg1, 'listen_port'));
		c = world({ proto: '6in4', listen_port: 'nosuchservice' });
		t.assert_equal(h.patch(c, jp, 'wg1', [ { op: 'replace', path: '/proto', value: 'wireguard' },
		                                       { op: 'add', path: '/private_key', value: WG.private_key },
		                                       { op: 'add', path: '/addresses', value: TO_WG.addresses },
		                                       { op: 'remove', path: '/listen_port' } ]).status, 200);
		t.assert_false(exists(c._state.uci.network.wg1, 'listen_port'));
	});

	t.it('the sweep reports nothing for the peers of a live or disabled wireguard interface', () => {
		for (let iface in [ WG, { ...WG, disabled: '1' } ])
			t.assert_deep_equal(h.sweep(world(iface, BAD)), [], iface);
	});
});

// netifd only reads peer sections inside the proto setup step, so a network
// reload leaves the kernel untouched: the peer is committed and never applied,
// and a delete does not revoke it. Every write has to emit the peer operations
// the transaction then pushes to the kernel.
t.describe('network.wireguard_peers kernel apply', () => {
	function op_tracking_handler(sink) {
		return handler.make(wgp, {
			tx: {
				acquire: function() { return {}; },
				release: function() {},
				reload: function() { return null; },
				check_services: function() { return null; },
				wg_apply: function(conn, ops) { for (let o in ops) push(sink, o); return null; },
				wg_reconcile: function() { return null; },
			},
		});
	}

	// `route_allowed_ips` routes are withdrawn only if the op says the previous
	// config installed them, so reading that flag off the raw uci section has to
	// accept every spelling netifd accepts. A section written by hand or by another
	// tool can carry `true`, and reading it as false left the routes installed for
	// prefixes the peer no longer wants.
	t.it('carries prev_route_allowed_ips for an existing section spelled true', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.route_allowed_ips = 'true';
		let ops = [];
		let r = op_tracking_handler(ops).remove(c, ctx(), 'g_existing');
		t.assert_equal(r.status, 204);
		t.assert_equal(length(ops), 1);
		t.assert_true(ops[0].prev_route_allowed_ips);
	});

	t.it('carries prev_route_allowed_ips for the "1" spelling too', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.route_allowed_ips = '1';
		let ops = [];
		op_tracking_handler(ops).remove(c, ctx(), 'g_existing');
		t.assert_true(ops[0].prev_route_allowed_ips);
	});

	t.it('leaves prev_route_allowed_ips false when the option is absent', () => {
		let ops = [];
		op_tracking_handler(ops).remove(with_wg(), ctx(), 'g_existing');
		t.assert_false(ops[0].prev_route_allowed_ips);
	});

	t.it('POST emits a set for the parent interface', () => {
		let ops = [];
		let r = op_tracking_handler(ops).create(with_wg(), ctx(), {
			interface: 'wg1', public_key: PK, allowed_ips: ['10.42.0.7/32'],
			endpoint_host: '198.51.100.7', endpoint_port: 51820, persistent_keepalive: 25,
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(length(ops), 1);
		t.assert_equal(ops[0].action, "set");
		t.assert_equal(ops[0].iface, "wg1");
		t.assert_equal(ops[0].public_key, PK);
		t.assert_deep_equal(ops[0].allowed_ips, ['10.42.0.7/32']);
		t.assert_equal(ops[0].endpoint_port, 51820);
		t.assert_equal(ops[0].persistent_keepalive, 25);
	});

	// The read view masks preshared_key, so an op built from it would silently
	// drop the secret and `wg set` would clear the key on the running tunnel.
	t.it('a set carries the preshared key, which the read view masks', () => {
		let ops = [];
		let r = op_tracking_handler(ops).create(with_wg(), ctx(), {
			interface: 'wg1', public_key: PK, allowed_ips: ['10.42.0.7/32'],
			preshared_key: 'c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MDA=',
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(ops[0].preshared_key, 'c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MDA=');
	});

	t.it('PATCH emits a set for the parent read off the uci type', () => {
		let ops = [];
		let r = op_tracking_handler(ops).patch(with_wg(), ctx(), 'g_existing',
		                                       { allowed_ips: ['10.42.0.6/32'] });
		t.assert_equal(r.status, 200);
		t.assert_equal(length(ops), 1);
		t.assert_equal(ops[0].iface, "wg1");
		t.assert_deep_equal(ops[0].allowed_ips, ['10.42.0.6/32']);
	});

	// Without removing the old key first the kernel keeps the previous peer under
	// it, so rotating a key would leave the old peer installed and its access live.
	t.it('rotating the public key removes the old peer before setting the new one', () => {
		let ops = [];
		let r = op_tracking_handler(ops).replace(with_wg(), ctx(), 'g_existing', {
			interface: 'wg1', public_key: PK2, allowed_ips: ['10.42.0.5/32'],
		});
		t.assert_equal(r.status, 200);
		t.assert_equal(length(ops), 2);
		t.assert_equal(ops[0].action, "remove");
		t.assert_equal(ops[0].public_key, PK);
		t.assert_equal(ops[1].action, "set");
		t.assert_equal(ops[1].public_key, PK2);
	});

	// A remove and a set of one key cut the tunnel of the peer.
	t.it('a key that uci holds as a list or with whitespace is no rotation', () => {
		for (let stored in [ [ PK ], PK + ' ' ]) {
			let c = with_wg();
			c._state.uci.network.g_existing.public_key = stored;
			let ops = [];
			let r = op_tracking_handler(ops).replace(c, ctx(), 'g_existing', {
				interface: 'wg1', public_key: PK, allowed_ips: ['10.42.0.5/32'],
			});
			t.assert_equal(r.status, 200, stored);
			t.assert_deep_equal(map(ops, (o) => o.action), [ 'set' ], stored);
		}
	});

	t.it('an unchanged public key emits only the set', () => {
		let ops = [];
		op_tracking_handler(ops).replace(with_wg(), ctx(), 'g_existing', {
			interface: 'wg1', public_key: PK, allowed_ips: ['10.42.0.5/32'],
		});
		t.assert_equal(length(ops), 1);
		t.assert_equal(ops[0].action, "set");
	});

	// netifd omits a disabled peer when it builds the config, so the kernel must
	// not carry it either.
	t.it('disabling a peer removes it from the kernel rather than setting it', () => {
		let ops = [];
		let r = op_tracking_handler(ops).patch(with_wg(), ctx(), 'g_existing',
		                                       { disabled: true });
		t.assert_equal(r.status, 200);
		t.assert_equal(length(ops), 1);
		t.assert_equal(ops[0].action, "remove");
		t.assert_equal(ops[0].public_key, PK);
	});

	// The parent is encoded in the uci section type, never stored as an option,
	// and a DELETE has no body to read it from. Without this the peer stays live
	// after a 204, so revoking access through the API does not revoke it.
	t.it('DELETE emits a remove for the parent read off the uci type', () => {
		let ops = [];
		let r = op_tracking_handler(ops).remove(with_wg(), ctx(), 'g_existing');
		t.assert_equal(r.status, 204);
		t.assert_equal(length(ops), 1);
		t.assert_equal(ops[0].action, "remove");
		t.assert_equal(ops[0].iface, "wg1");
		t.assert_equal(ops[0].public_key, PK);
	});

	t.it('a validation failure emits nothing, since nothing was written', () => {
		let ops = [];
		let r = op_tracking_handler(ops).create(with_wg(), ctx(), {
			interface: 'wg1', public_key: 'tooshort', allowed_ips: ['10.42.0.7/32'],
		});
		t.assert_equal(r.status, 422);
		t.assert_equal(length(ops), 0);
	});

	// /batch runs handlers in bare mode, which returns before any commit, so the
	// apply cannot happen per sub-request. Sub-requests accumulate into one
	// ordered sink that the outer multi_transaction applies once.
	t.it('bare-mode writes accumulate in order into one shared sink', () => {
		let h = handler.make(wgp, { tx: { bare: true } });
		let c = with_wg();
		let sink = [];
		let batch_ctx = { request_id: "01hx0000000000000000000000.0", kernel_sink: sink };
		for (let ip in ['10.42.0.11/32', '10.42.0.12/32']) {
			let r = h.create(c, batch_ctx, {
				interface: 'wg1', public_key: PK, allowed_ips: [ip],
			});
			t.assert_equal(r.status, 200);
		}
		t.assert_equal(length(sink), 2);
		t.assert_deep_equal(sink[0].allowed_ips, ['10.42.0.11/32']);
		t.assert_deep_equal(sink[1].allowed_ips, ['10.42.0.12/32']);
	});

	// The hook is opt-in, so every other resource keeps its reload-only apply.
	t.it('a resource with no kernel_ops hook emits nothing', () => {
		let ops = [];
		let routes = loadfile('src/resources/network.routes.uc')();
		let h = handler.make(routes, {
			tx: {
				acquire: function() { return {}; },
				release: function() {},
				reload: function() { return null; },
				check_services: function() { return null; },
				wg_apply: function(conn, o) { for (let x in o) push(ops, x); return null; },
			},
		});
		let c = ubus.stub({ uci: { network: {
			lan: { '.type': 'interface', proto: 'static' },
		} } });
		let r = h.create(c, ctx(), { target: '10.9.0.0/24', interface: 'lan', gateway: '10.0.0.1' });
		t.assert_equal(r.status, 200);
		t.assert_equal(length(ops), 0);
	});
});

// `disabled` and `route_allowed_ips` are read by wireguard.sh with config_get_bool, which
// accepts `on`, `yes` and `enabled` as well as `1`. Reading them with the netifd-strict
// helper made an operator-disabled peer report enabled, and because toUci writes the view
// back, an unrelated PATCH then rewrote uci to '0' and kernel_ops emitted a `set` that
// installed the peer live. Every spelling the shell honours has to survive the round trip.
t.describe('network.wireguard_peers boolean spellings match config_get_bool', () => {
	function peer(disabled) {
		return { '.name': 'p1', '.type': 'wireguard_wg0', '.anonymous': false,
		         public_key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=',
		         allowed_ips: ['10.0.0.2/32'], disabled: disabled };
	}
	for (let spelling in ['1', 'true', 'on', 'yes', 'enabled']) {
		t.it(sprintf("disabled=%s reads as disabled and stays disabled", spelling), () => {
			let view = wgp.fromUci(peer(spelling), null);
			t.assert_true(view.disabled);
			t.assert_equal(wgp.toUci(view).disabled, '1');
		});
	}
	for (let spelling in ['0', 'false', 'off', 'no', 'disabled']) {
		t.it(sprintf("disabled=%s reads as enabled", spelling), () => {
			t.assert_false(wgp.fromUci(peer(spelling), null).disabled);
		});
	}
	t.it('route_allowed_ips honours the same set', () => {
		let sec = peer('0');
		sec.route_allowed_ips = 'yes';
		t.assert_true(wgp.fromUci(sec, null).route_allowed_ips);
	});
	// config_get joins a list with spaces before config_get_bool reads it.
	t.it('reads a list as config_get gives it to config_get_bool', () => {
		let sec = peer([ '1' ]);
		sec.route_allowed_ips = [ '1' ];
		let view = wgp.fromUci(sec, null);
		t.assert_true(view.disabled);
		t.assert_true(view.route_allowed_ips);
		t.assert_true(wgp.kernel_ops('remove', null, 'wireguard_wg0', sec)[0].prev_route_allowed_ips);
	});
});

// wireguard.sh reads allowed_ips with config_get, so a scalar holds one prefix per word, and a
// DELETE has to withdraw the routes of each.
t.describe('network.wireguard_peers reads a scalar allowed_ips as words', () => {
	let sec = { '.name': 'p1', '.type': 'wireguard_wg0', '.anonymous': false,
	            public_key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=',
	            allowed_ips: '10.0.0.2/32 10.0.1.0/24', route_allowed_ips: '1' };
	t.it('fromUci', () => {
		t.assert_deep_equal(wgp.fromUci(sec, null).allowed_ips, [ '10.0.0.2/32', '10.0.1.0/24' ]);
	});
	t.it('kernel_ops on remove', () => {
		let ops = wgp.kernel_ops('remove', null, 'wireguard_wg0', sec);
		t.assert_deep_equal(ops[0].prev_allowed_ips, [ '10.0.0.2/32', '10.0.1.0/24' ]);
	});
});

// wireguard.sh hands endpoint_port to wg, which strips whitespace and resolves a service name.
t.describe('network.wireguard_peers reads endpoint_port as wg does', () => {
	let read = (port) => wgp.fromUci({ '.name': 'p1', '.type': 'wireguard_wg0', '.anonymous': false,
	                                   public_key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=', allowed_ips: ['10.0.0.2/32'],
	                                   endpoint_host: '198.51.100.7', endpoint_port: port }, null).endpoint_port;
	t.it('reads decimals, nothing and whitespace', () => {
		t.assert_equal(read('51820'), 51820);
		t.assert_equal(read(' +443'), 443);
		t.assert_equal(read(null), null);
		t.assert_equal(read(''), null);
		t.assert_equal(read('  '), 0);
	});
	t.it('refuses port 0, which is also what a name that does not resolve reads', () => {
		let errs = filter(full_validate(wgp, { interface: 'wg0', public_key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=',
		                                       allowed_ips: ['10.0.0.2/32'], endpoint_port: 0 }, null),
		                  (e) => e.field == 'endpoint_port');
		t.assert_deep_equal(map(errs, (e) => e.code), [ 'out_of_range' ]);
	});
});

// wireguard.sh reads each option with config_get and writes it on a line of the config for wg.
t.describe('network.wireguard_peers reads endpoint_host and persistent_keepalive as wg does', () => {
	let read = (k, v) => wgp.fromUci({ '.name': 'p1', '.type': 'wireguard_wg0', [k]: v }, null)[k];
	t.it('reads a list endpoint_host as one string', () => {
		t.assert_equal(read('endpoint_host', [ 'vpn.example.com' ]), 'vpn.example.com');
	});
	t.it('reads a keepalive that wg refuses as -1, and off as 0', () => {
		t.assert_equal(read('persistent_keepalive', '25x'), -1);
		t.assert_equal(read('persistent_keepalive', '65536'), -1);
		t.assert_equal(read('persistent_keepalive', 'off'), 0);
		t.assert_equal(read('persistent_keepalive', ' 25 '), 25);
	});
});
