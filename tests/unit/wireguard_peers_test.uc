let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let wg = require('wg');
let wgp = loadfile('src/resources/network.wireguard_peers.uc')();
let fs = require('fs');

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
	t.it('requires interface and public_key, and takes a peer without allowed IPs, which LuCI allows', () => {
		let errs = wgp.validate({}, null);
		let fields = {};
		for (let e in errs) fields[e.field] = e.code;
		t.assert_equal(fields.interface, "required");
		t.assert_equal(fields.public_key, "required");
		t.assert_false(exists(fields, "allowed_ips"));
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

	// The handler writes the host on a line of the config that `wg syncconf` reads, so a newline adds
	// a line. It brackets every host with a colon, and only those. wg cuts its config line at `#`, and
	// finds a port after a bracketed host only when that host is an IPv6 address.
	t.it('refuses an escape, a newline, a #, or a colon outside an IPv6 address in endpoint_host', () => {
		function host_errs(h) {
			return filter(full_validate(wgp, { interface: 'wg1', public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
			                                  allowed_ips: ['10.0.0.2/32'], endpoint_host: h }, null),
			              (e) => e.field == 'endpoint_host');
		}
		for (let h in [ 'vpn.example.com', '198.51.100.7', 'fd00::1', 'fe80::1%eth1', '1.2.3', '',
		                '[192.0.2.1]', '[vpn.example.com]', ' fd00::1 ' ])
			t.assert_equal(length(host_errs(h)), 0, h);
		for (let h in [ '192.0.2.1\\0072443', '[fd00::1]', 'fd00::1]', 'vpn.example.com#x',
		                '192.0.2.1:51820', 'vpn:1', 'fd00::1x%eth1' ])
			t.assert_deep_equal(map(host_errs(h), (e) => e.code), [ 'invalid_format' ], h);
		// The schema check and validate_new() both refuse a newline, and a 422 keeps only the second.
		t.assert_deep_equal(map(host_errs('vpn.example.com\nx'), (e) => e.code),
		                    [ 'invalid_format', 'invalid_format' ]);
		// Each problem is its own error.
		t.assert_deep_equal(map(host_errs('fd00::1\\n[Peer]'), (e) => e.code), [ 'invalid_format', 'invalid_format' ]);
		t.assert_equal(length(host_errs('vpn.example.com\t')), 0);
		// A list reads as one host, its entries joined by spaces.
		t.assert_deep_equal(map(wgp.validate_new({ endpoint_host: [ '192.0.2.1\\nPeer' ] }), (e) => [ e.field, e.code ]),
		                    [ [ 'endpoint_host', 'invalid_format' ] ]);
	});

	// The handler gives wg a key as uci holds it, and leaves out a list or one with whitespace.
	t.it('takes a key only as uci holds it, and refuses one that wg refuses', () => {
		let errs = (k) => map(wgp.validate_new({ public_key: k }), (e) => e.field);
		t.assert_deep_equal(errs(PK), []);
		for (let k in [ ' ' + PK + '\t', [ PK ], substr(PK, 0, 42) + '5=', PK + '\n[Peer]', substr(PK, 0, 43) + '\\075', 'not-a-key' ])
			t.assert_deep_equal(errs(k), [ 'public_key' ], k);
	});

	t.it('refuses an escape in allowed_ips', () => {
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

	// v4 (#308): LuCI's model, a merge PATCH that leaves a stored host or key as it is is
	// refused for it all the same, and the sweep lists the peer whether it is enabled or not.
	// Enabling it is refused until a write replaces the value.
	t.it('a stored broken host or key blocks every write of the peer', () => {
		for (let extra in [ { endpoint_host: '[fd00::1]' }, { endpoint_host: '192.0.2.1\\n[Peer]' },
		                    { preshared_key: 'K\\n[Peer]' } ]) {
			let c = with_wg();
			let field = null;
			for (let k, v in extra) { c._state.uci.network.g_existing[k] = v; field = k; }
			let h = make_handler();
			t.assert_equal(length(h.sweep(c)), 1, extra);
			let r = h.patch(c, ctx(), 'g_existing', { description: 'x' });
			t.assert_equal(r.status, 422, extra);
			t.assert_deep_equal(map(r.body.errors, (e) => e.field), [ field ], extra);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: true }).status, 422, extra);
			t.assert_equal(length(h.sweep(c)), 1, extra);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: false }).status, 422, extra);
		}
	});

	let fields_of = (r) => map(r.body?.errors ?? [], (e) => [ e.field, e.code ]);
	const UNUSABLE = [ { persistent_keepalive: '25x' }, { endpoint_host: '192.0.2.1', endpoint_port: 'nosuchservice' },
	                   { endpoint_host: '192.0.2.1', endpoint_port: '0' } ];

	// v4 (#308): a stored port or keepalive that wg cannot use blocks every write of the peer,
	// and the sweep still lists the peer.
	t.it('a stored port or keepalive that wg cannot use blocks every write of the peer', () => {
		for (let stored in UNUSABLE) {
			let c = with_wg();
			for (let k, v in stored) c._state.uci.network.g_existing[k] = v;
			let h = make_handler();
			let r = h.patch(c, ctx(), 'g_existing', { description: 'x' });
			t.assert_equal(r.status, 422, stored);
			t.assert_equal(length(r.body.errors), 1, stored);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: true }).status, 422, stored);
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

	// The handler leaves out a port and a keepalive that it cannot read, so neither keeps the interface
	// down. v4 (#308): the stored port blocks every write meanwhile, even one that only enables the peer.
	t.it('a port that reads 0 or a keepalive that reads -1 is never live, and blocks every write of the peer', () => {
		let c = with_wg();
		for (let k, v in { endpoint_port: 'nosuchservice', disabled: '1' }) c._state.uci.network.g_existing[k] = v;
		let h = make_handler();
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: false }).status, 422);
		t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.1' })), [ [ 'endpoint_port', 'out_of_range' ] ]);
		t.assert_deep_equal(map(wgp.validate_new({ persistent_keepalive: -1, public_key: PK }), (e) => e.live), [ false ]);
		t.assert_deep_equal(map(wgp.validate_new({ endpoint_port: 0, endpoint_host: '192.0.2.1', public_key: PK }), (e) => e.live), [ false ]);
	});

	// The kernel apply sends an endpoint only with a port. v4 (#308): the stored port that wg
	// cannot use blocks every write of the peer, whichever field the write names.
	t.it('a write that changes the host or the key of an enabled peer whose port reads 0 is refused', () => {
		for (let port in [ '0', 'nosuchservice' ]) {
			let c = with_wg();
			for (let k, v in { endpoint_host: '192.0.2.1', endpoint_port: port }) c._state.uci.network.g_existing[k] = v;
			let h = make_handler();
			t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.2' })), [ [ 'endpoint_port', 'out_of_range' ] ], port);
			t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { public_key: PK2 })), [ [ 'endpoint_port', 'out_of_range' ] ], port);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { endpoint_host: ' 192.0.2.1 ' }).status, 422, port);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { public_key: PK2, endpoint_port: 51820 }).status, 200, port);
			t.assert_equal(h.patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.2', endpoint_port: 51820 }).status, 200, port);
		}
		let c = with_wg();
		for (let k, v in { endpoint_host: '192.0.2.1', endpoint_port: '0', disabled: '1' }) c._state.uci.network.g_existing[k] = v;
		t.assert_equal(make_handler().patch(c, ctx(), 'g_existing', { endpoint_host: '192.0.2.2' }).status, 422);
	});

	// The handler leaves out the endpoint of a name that does not resolve and keeps the peer, so the
	// write takes such a name, and the kernel apply reports it.
	t.it('takes a host name that does not resolve', () => {
		let body = { interface: 'wg1', public_key: PK2, allowed_ips: [ '10.42.0.3/32' ], endpoint_host: ' nx.invalid ', endpoint_port: 51820 };
		t.assert_equal(make_handler().create(with_wg(), ctx(), body).status, 200);
	});

	// The handler gives a host of digits and dots to wg as it stands, as uci holds it, and wg looks
	// up one that inet_aton does not read as a name that no DNS holds.
	t.it('refuses a host of digits and dots that wg cannot read, a stored one too', () => {
		let h = make_handler();
		for (let host in [ '10.0.0.256', '1.2.3.4.5', '08.0.0.1', '.' ])
			t.assert_deep_equal(fields_of(h.patch(with_wg(), ctx(), 'g_existing', { endpoint_host: host })), [ [ 'endpoint_host', 'invalid_format' ] ], host);
		for (let host in [ '192.168.1.01', '010.0.0.1', '167772161', '0x0a000001', ' 10.0.0.256' ])
			t.assert_equal(h.patch(with_wg(), ctx(), 'g_existing', { endpoint_host: host }).status, 200, host);
		let c = with_wg();
		let stored = c._state.uci.network.g_existing;
		stored.endpoint_host = '10.0.0.256';
		t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { description: 'x' })), [ [ 'endpoint_host', 'invalid_format' ] ]);
		let live = () => map(filter(h.sweep(c)[0].errors, (e) => e.field == 'endpoint_host'), (e) => e.live);
		t.assert_deep_equal(live(), [ true ]);
		for (let k, v in { public_key: PK + ' ', endpoint_port: 'nosuchservice', disabled: '1' }) {
			let kept = stored[k];
			stored[k] = v;
			t.assert_deep_equal(live(), [ false ], k);
			stored[k] = kept;
		}
	});

	// The handler gives wg an IPv6 address as it stands, and musl's getaddrinfo refuses one whose zone
	// it cannot read, so wg refused the config of the whole interface and the restore answered 500.
	t.it('refuses an IPv6 host whose zone musl refuses', () => {
		let m = t.load_with_fs({ ...fs, access: (p) => p == '/sys/class/net/br-lan' }, [ 'wg' ]);
		let h = handler.make(t.load_with({ wg: m }, [ '../resources/network.wireguard_peers' ]),
		                     { tx: { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null } });
		for (let host in [ 'fd00::1', 'fe80::1%3', '2001:db8::1%3', 'fe80::1%br-lan', ' fe80::1%br-lan ' ])
			t.assert_equal(h.patch(with_wg(), ctx(), 'g_existing', { endpoint_host: host }).status, 200, host);
		for (let host in [ '2001:db8::1%x', 'fd00::1%br-lan', 'fe80::1%', '2001:db8::1%4294967296' ])
			t.assert_deep_equal(fields_of(h.patch(with_wg(), ctx(), 'g_existing', { endpoint_host: host, disabled: true })),
			                    [ [ 'endpoint_host', 'invalid_format' ] ], host);
		let c = with_wg();
		let body = { interface: 'wg1', public_key: PK2, allowed_ips: [ '10.42.0.3/32' ], endpoint_host: 'fe80::1%nosuchdev' };
		t.assert_deep_equal(fields_of(h.create(c, ctx(), body)), [ [ 'endpoint_host', 'conflict' ] ]);
		t.assert_deep_equal(sort(keys(c._state.uci.network)), [ 'g_existing', 'wg1' ]);
		t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { endpoint_host: 'fe80::1%nosuchdev' })), [ [ 'endpoint_host', 'conflict' ] ]);
		// An interface exists at one time and not at another, so a stored zone that names none is no
		// error of the section, and a disabled peer does not reach wg.
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { endpoint_host: 'fe80::1%nosuchdev', disabled: true }).status, 200);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x', disabled: false }).status, 200);
		c._state.uci.network.g_existing.endpoint_host = '2001:db8::1%x';
		t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { description: 'y' })), [ [ 'endpoint_host', 'invalid_format' ] ]);
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

	// The PUT of the read sends 0 or -1, which toUci would store in place of the value that uci holds.
	// v4 (#308): the stored value blocks the PUT of the read as well.
	t.it('a PUT of the read is refused for a port or keepalive that wg cannot use', () => {
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
		t.assert_equal(p.r.status, 422);
		t.assert_deep_equal(fields_of(p.r), [ [ 'persistent_keepalive', 'out_of_range' ] ]);
		t.assert_equal(p.c._state.uci.network.g_existing.persistent_keepalive, '25x');
		for (let stored in [ UNUSABLE[1], UNUSABLE[2], { endpoint_host: '192.0.2.1', endpoint_port: ' 70000' },
		                     { endpoint_host: '192.0.2.1', endpoint_port: '  ' }, { endpoint_host: '192.0.2.1', endpoint_port: ' +00' } ]) {
			p = put_read(stored);
			t.assert_equal(p.r.status, 422, stored);
			t.assert_deep_equal(fields_of(p.r), [ [ 'endpoint_port', 'out_of_range' ] ], stored);
			t.assert_equal(p.c._state.uci.network.g_existing.endpoint_port, stored.endpoint_port, stored);
		}
	});

	// The handler matches a key as uci holds it, and skips the peer, or leaves out the preshared key,
	// for one with whitespace or a comment, or for a list.
	t.it('a stored key with whitespace, a comment or as a list blocks every write of the peer, and is not live', () => {
		let h = make_handler();
		for (let kv in [ [ 'public_key', PK + ' # b' ], [ 'preshared_key', PK + ' ' ], [ 'preshared_key', [ PK ] ] ]) {
			let k = kv[0], c = with_wg();
			c._state.uci.network.g_existing[k] = kv[1];
			t.assert_deep_equal(fields_of(h.patch(c, ctx(), 'g_existing', { description: 'x' })), [ [ k, 'invalid_format' ] ], kv);
			t.assert_deep_equal(map(h.sweep(c)[0].errors, (e) => [ e.field, e.live ]), [ [ k, false ] ], kv);
		}
	});

	t.it('refuses a key whose unused bits are not zero, which wg refuses', () => {
		let r = make_handler().create(with_wg(), ctx(), { interface: 'wg1', public_key: substr(PK, 0, 42) + '5=',
		                                                  allowed_ips: [ '10.42.0.9/32' ] });
		t.assert_equal(r.status, 422);
	});

	// The write checks a stored allowed IP, so the peer answers 422 rather than letting wg refuse it
	// with a 500.
	t.it('a stored invalid allowed IP blocks every write of the peer until one replaces it', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.allowed_ips = [ '::/0\\n[Peer]\\nPublicKey=K\\nAllowedIPs=0.0.0.0\\0570' ];
		let h = make_handler();
		t.assert_equal(length(h.sweep(c)), 1);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x' }).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: true }).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { allowed_ips: [ '10.42.0.2/32' ] }).status, 200);
	});

	// A write that swaps one injection for another is refused. A list reads as its entries joined.
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
	// leaves the default out. v4 (#308): a stored broken host blocks every PUT of the peer,
	// enabling it or not.
	t.it('a PUT of a peer that stores a broken host is refused, enabling it or not', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.endpoint_host = '[fd00::1]';
		let h = make_handler();
		let body = h.get_one(c, ctx(), 'g_existing').body;
		for (let k in [ 'id', 'managed', 'runtime', 'has_preshared_key' ]) delete body[k];
		let r = h.replace(c, ctx(), 'g_existing', { ...body, description: 'x' });
		t.assert_equal(r.status, 422);
		t.assert_deep_equal(map(r.body.errors, (e) => e.field), [ 'endpoint_host' ]);
		t.assert_equal(h.replace(c, ctx(), 'g_existing', { ...body, disabled: true }).status, 422);
		let enable = { ...body };
		delete enable.disabled;
		t.assert_equal(h.replace(c, ctx(), 'g_existing', enable).status, 422);
		c._state.uci.network.g_existing.endpoint_host = [ '[fd00::1]', 'x' ];
		t.assert_equal(h.replace(c, ctx(), 'g_existing', { ...body, disabled: true, endpoint_host: '[fd00::1] x' }).status, 422);
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

// The handler gives every enabled peer of an interface to one `wg syncconf`, so one stored peer that
// wg refuses keeps the interface down. A write of the interface that restarts it keeps its
// commit and names that peer, as LuCI saves the write and the interface stays down.
t.describe('network.interfaces answers blocked for a write that restarts an interface that a stored peer keeps down', () => {
	let ifaces = loadfile('src/resources/network.interfaces.uc')();
	let h = handler.make(ifaces, { tx: {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	} });
	const WG = { proto: 'wireguard', private_key: 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=', addresses: [ '10.42.0.1/24' ] };
	const STATIC = { proto: 'static', ipaddr: [ '192.0.2.1/24' ] };
	const BADKEY = substr(PK, 0, 42) + '5=';
	const BAD = { g_key: { public_key: BADKEY },
	              g_host: { public_key: PK2, endpoint_host: '10.0.0.256', endpoint_port: '51820' } };
	function world(iface, peers, parent) {
		let network = { [parent ?? 'wg1']: { '.type': 'interface', '.anonymous': false, ...iface } };
		for (let id, p in peers)
			network[id] = { '.type': 'wireguard_wg1', '.anonymous': false, public_key: PK, allowed_ips: [ '10.42.0.2/32' ], ...p };
		return ubus.stub({ uci: { network } });
	}
	let errs = (r) => map(r.body?.errors ?? [], (e) => [ e.field, e.code ]);
	let kernel = (r) => [ r.status, r.headers["X-Kernel-Status"], r.headers["X-Kernel-Blocked"], r.headers["X-Kernel-Applied"] ];

	t.it('a switch to wireguard keeps its commit and names each peer that wg refuses, and no value', () => {
		let c = world(STATIC, { ...BAD, g_ok: { public_key: PK2 } });
		let r = h.patch(c, ctx(), 'wg1', WG);
		t.assert_deep_equal(kernel(r), [ 200, 'blocked', 'wg1/g_key,wg1/g_host', null ]);
		t.assert_equal(c._state.uci.network.wg1.proto, 'wireguard');
		let text = sprintf('%J', r);
		t.assert_true(index(text, BADKEY) < 0 && index(text, '10.0.0.256') < 0, text);
	});

	t.it('a switch to wireguard answers no_kernel when such a peer is disabled or has no key, or when every peer is clean', () => {
		t.assert_deep_equal(kernel(h.patch(world(STATIC, { g_host: { ...BAD.g_host, disabled: '1' } }), ctx(), 'wg1', WG)),
		                    [ 200, 'no_kernel', null, null ]);
		t.assert_deep_equal(kernel(h.patch(world(STATIC, { g_host: { ...BAD.g_host, public_key: null } }), ctx(), 'wg1', WG)),
		                    [ 200, 'no_kernel', null, null ]);
		t.assert_deep_equal(kernel(h.patch(world(STATIC, { g_ok: {}, g_ok2: { public_key: PK2, persistent_keepalive: '25' } }), ctx(), 'wg1', WG)),
		                    [ 200, 'no_kernel', null, null ]);
	});

	t.it('a switch with disabled true restarts nothing, and the enable that follows answers blocked', () => {
		let c = world(STATIC, BAD);
		t.assert_deep_equal(kernel(h.patch(c, ctx(), 'wg1', { ...WG, disabled: true })), [ 200, 'no_kernel', null, null ]);
		t.assert_deep_equal(kernel(h.patch(c, ctx(), 'wg1', { disabled: false })), [ 200, 'blocked', 'wg1/g_key,wg1/g_host', null ]);
		t.assert_equal(c._state.uci.network.wg1.disabled, '0');
	});

	// wg cannot parse such an allowed IP, and a peer write refuses it on every write.
	t.it('a stored allowed IP that wg cannot parse blocks the interface, on a peer that wg reads', () => {
		t.assert_deep_equal(kernel(h.patch(world(STATIC, { g_ip: { allowed_ips: [ '10.42.0.2/32', 'foo' ] } }), ctx(), 'wg1', WG)),
		                    [ 200, 'blocked', 'wg1/g_ip', null ]);
		for (let off in [ { disabled: '1' }, { public_key: null } ])
			t.assert_equal(h.patch(world(STATIC, { g_ip: { allowed_ips: [ 'foo' ], ...off } }), ctx(), 'wg1', WG).headers["X-Kernel-Status"],
			               'no_kernel', off);
		for (let ips in [ [ '10.42.0.2/32 10.42.1.0/24' ], '#c' ])
			t.assert_equal(h.patch(world(STATIC, { g_ip: { allowed_ips: ips } }), ctx(), 'wg1', WG).headers["X-Kernel-Blocked"], 'wg1/g_ip', ips);
	});

	// wg reads an allowed IP without its whitespace, and takes a + before it as the marker of an
	// incremental update. A write refuses both forms, and the interface comes up with them.
	t.it('a stored allowed IP that wg takes in another spelling blocks nothing', () => {
		for (let ips in [ [ '10.42.0.2/32', '+10.42.3.0/24' ], '10.42.0.2/32\t' ])
			t.assert_equal(h.patch(world(STATIC, { g_ip: { allowed_ips: ips } }), ctx(), 'wg1', WG).headers["X-Kernel-Status"], 'no_kernel', ips);
		t.assert_equal(h.patch(world(STATIC, { g_ip: { allowed_ips: [ '-10.42.3.0/24' ] } }), ctx(), 'wg1', WG).headers["X-Kernel-Status"], 'blocked');
		let r = [ h.patch(world(STATIC, { g_ip: { allowed_ips: [ ' 10.42.0.2/32 ', '10.42.3.0/24' ] } }), ctx(), 'wg1', WG),
		          h.patch(world(STATIC, { g_ip: { allowed_ips: [ '10.42.0.2/32 10.42.3.0/24' ] } }), ctx(), 'wg1', WG) ];
		t.assert_deep_equal(map(r, (x) => x.headers["X-Kernel-Status"]), [ 'no_kernel', 'blocked' ]);
	});

	t.it('the way out works: fix the peer, and the next write of the interface answers no_kernel', () => {
		let ph = handler.make(wgp, { tx: {
			acquire: function() { return {}; }, release: function() {},
			reload: function() { return null; }, check_services: function() { return null; },
		} });
		let c = world(STATIC, { g_host: BAD.g_host });
		t.assert_equal(h.patch(c, ctx(), 'wg1', WG).headers["X-Kernel-Status"], 'blocked');
		t.assert_equal(ph.patch(c, ctx(), 'g_host', { endpoint_host: '10.0.0.1' }).status, 200);
		t.assert_deep_equal(kernel(h.patch(c, ctx(), 'wg1', { mtu: 1400 })), [ 200, 'no_kernel', null, null ]);
	});

	// The handler skips a peer whose key does not match its pattern, so wg reads none of its values.
	t.it('a peer that the handler skips blocks nothing', () => {
		let skipped = { g_ip: { public_key: 'not-a-key', allowed_ips: [ 'foo' ], endpoint_host: 'a#b' } };
		let r = [ h.patch(world(STATIC, skipped), ctx(), 'wg1', WG),
		          h.patch(world({ ...WG, disabled: '1' }, skipped), ctx(), 'wg1', { disabled: false }),
		          h.patch(world(STATIC, { g_ip: { allowed_ips: [ 'foo' ] } }), ctx(), 'wg1', WG) ];
		t.assert_deep_equal(map(r, (x) => x.headers["X-Kernel-Status"]), [ 'no_kernel', 'no_kernel', 'blocked' ]);
	});

	// netifd restarts the interface for any change, and the restart gives wg every peer again.
	t.it('a write of an interface already live on wireguard answers blocked too, and one that disables it does not', () => {
		t.assert_deep_equal(kernel(h.patch(world(WG, BAD), ctx(), 'wg1', { mtu: 1400 })), [ 200, 'blocked', 'wg1/g_key,wg1/g_host', null ]);
		t.assert_deep_equal(kernel(h.patch(world(WG, BAD), ctx(), 'wg1', { disabled: true })), [ 200, 'no_kernel', null, null ]);
		t.assert_deep_equal(kernel(h.patch(world(WG, BAD), ctx(), 'wg1', {})), [ 200, 'no_kernel', null, null ]);
		t.assert_equal(h.remove(world(WG, BAD), ctx(), 'wg1').headers["X-Kernel-Status"], 'no_kernel');
	});

	t.it('enabling a wireguard interface answers blocked, also a PUT that leaves disabled out', () => {
		let off = { ...WG, disabled: '1' };
		t.assert_deep_equal(kernel(h.patch(world(off, BAD), ctx(), 'wg1', { disabled: false })), [ 200, 'blocked', 'wg1/g_key,wg1/g_host', null ]);
		t.assert_deep_equal(kernel(h.replace(world(off, BAD), ctx(), 'wg1', { proto: 'wireguard', addresses: WG.addresses })),
		                    [ 200, 'blocked', 'wg1/g_key,wg1/g_host', null ]);
		t.assert_deep_equal(kernel(h.patch(world(off, BAD), ctx(), 'wg1', { mtu: 1400 })), [ 200, 'no_kernel', null, null ]);
	});

	t.it('a create under the name of stored peers answers blocked', () => {
		let c = world(STATIC, BAD, 'lan');
		let r = h.create(c, ctx(), { id: 'wg1', ...WG });
		t.assert_deep_equal(kernel(r), [ 200, 'blocked', 'wg1/g_key,wg1/g_host', null ]);
		t.assert_equal(c._state.uci.network.wg1.proto, 'wireguard');
	});

	// wg refuses a listen port outside 0 to 65535 with the whole config.
	t.it('a stored listen_port that reads -1 blocks every write of the interface', () => {
		let ports = (r) => filter(errs(r), (e) => e[0] == 'listen_port');
		for (let p in [ [ { disabled: '1' }, { disabled: false } ], [ {}, { mtu: 1400 } ], [ { disabled: '1' }, { mtu: 1400 } ] ])
			t.assert_deep_equal(ports(h.patch(world({ ...WG, listen_port: '65536', ...p[0] }), ctx(), 'wg1', p[1])),
			                    [ [ 'listen_port', 'out_of_range' ] ], p);
	});

	// The read of proto static hides listen_port, and a PATCH keeps what it leaves out, so the switch
	// kept a port outside 0 to 65535, which the read of wireguard gives as -1.
	const HAND = { proto: 'static', ipaddr: [ '10.9.0.1/24' ], listen_port: '70000' };
	const TO_WG = { proto: 'wireguard', private_key: WG.private_key, addresses: [ '10.9.0.1/24' ] };
	t.it('a PATCH that switches to wireguard is refused for a stored listen_port that the old read hides and that reads -1', () => {
		let c = world(HAND);
		let r = h.patch(c, ctx(), 'wg1', TO_WG);
		t.assert_deep_equal(errs(r), [ [ 'listen_port', 'conflict' ] ]);
		let m = r.body.errors[0].message;
		t.assert_true(index(m, 'PUT') >= 0 && index(m, '70000') < 0, m);
		t.assert_equal(c._state.uci.network.wg1.proto, 'static');
		let jp = { ...ctx(), json_patch: true };
		t.assert_deep_equal(errs(h.patch(world(HAND), jp, 'wg1', [ { op: 'replace', path: '/proto', value: 'wireguard' },
		                                                           { op: 'add', path: '/private_key', value: WG.private_key },
		                                                           { op: 'add', path: '/addresses', value: TO_WG.addresses } ])),
		                    [ [ 'listen_port', 'conflict' ] ]);
	});

	// The PATCH deletes only what the read of static shows, so a null cannot remove the hidden value.
	t.it('the switch passes with a port, and is refused with a null', () => {
		let c = world(HAND);
		t.assert_deep_equal(errs(h.patch(c, ctx(), 'wg1', { ...TO_WG, listen_port: null })), [ [ 'listen_port', 'conflict' ] ]);
		t.assert_equal(c._state.uci.network.wg1.listen_port, '70000');
		t.assert_equal(h.patch(c, ctx(), 'wg1', { ...TO_WG, listen_port: 51820 }).status, 200);
		t.assert_equal(c._state.uci.network.wg1.listen_port, '51820');
	});

	t.it('a switch with disabled true is refused too, since the interface would hold the port', () => {
		let c = world(HAND);
		t.assert_deep_equal(errs(h.patch(c, ctx(), 'wg1', { ...TO_WG, disabled: true })), [ [ 'listen_port', 'conflict' ] ]);
		t.assert_equal(c._state.uci.network.wg1.proto, 'static');
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

	// The handler gives wg no port for a service name, so wg listens on a port that the kernel picks, and
	// the read gives null. A write of the interface or a switch to wireguard takes such a name.
	t.it('a stored service name reads null and blocks no write, and a switch to wireguard keeps it', () => {
		for (let name in [ 'openvpn', 'nosuchservice' ]) {
			let c = world({ ...WG, listen_port: name });
			t.assert_equal(h.get_one(c, ctx(), 'wg1').body.listen_port, null, name);
			t.assert_equal(h.patch(c, ctx(), 'wg1', { mtu: 1400 }).status, 200, name);
			t.assert_equal(h.patch(c, ctx(), 'wg1', { disabled: true }).status, 200, name);
			t.assert_equal(c._state.uci.network.wg1.listen_port, name);
			c = world({ ...HAND, listen_port: name });
			t.assert_equal(h.patch(c, ctx(), 'wg1', TO_WG).status, 200, name);
			t.assert_deep_equal([ c._state.uci.network.wg1.proto, c._state.uci.network.wg1.listen_port ], [ 'wireguard', name ]);
		}
	});

	// The read already gives null for a name, so a PATCH, which writes only what it moves, keeps the
	// name, and a PUT, which removes every option that it does not write, removes it. A null removes
	// a number that reads -1, which the read shows.
	t.it('a PATCH keeps a stored name, a PUT of the read removes it, and a null removes a port that reads -1', () => {
		let c = world({ ...WG, listen_port: 'openvpn' });
		t.assert_equal(h.patch(c, ctx(), 'wg1', { listen_port: null }).status, 200);
		t.assert_equal(c._state.uci.network.wg1.listen_port, 'openvpn');
		c = world({ ...WG, listen_port: '70000' });
		t.assert_equal(h.patch(c, ctx(), 'wg1', { listen_port: null }).status, 200);
		t.assert_false(exists(c._state.uci.network.wg1, 'listen_port'));
		c = world({ ...WG, listen_port: 'openvpn' });
		let read = h.get_one(c, ctx(), 'wg1').body;
		for (let k in [ 'id', 'runtime', 'has_private_key' ]) delete read[k];
		t.assert_equal(h.replace(c, ctx(), 'wg1', read).status, 200);
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
		let c = world({ ...WG, disabled: '1', listen_port: '70000' });
		t.assert_equal(h.patch(c, jp, 'wg1', [ { op: 'replace', path: '/disabled', value: false },
		                                       { op: 'remove', path: '/listen_port' } ]).status, 200);
		t.assert_false(exists(c._state.uci.network.wg1, 'listen_port'));
		c = world({ proto: '6in4', listen_port: '70000' });
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

// One stored peer that wg refuses keeps its whole interface down, and a write of another peer cannot
// tell a restart that it broke from one that was broken before it. It keeps its commit and names that
// peer, as LuCI saves it. A write that fixes or deletes the peer finds none and takes the usual path.
t.describe('network.wireguard_peers answers blocked for a write to an interface that another stored peer keeps down', () => {
	let PENDING = { up: false, pending: true }, DOWN = { up: false };
	function world(a, status) {
		let c = ubus.stub({ uci: { network: {
			wg1: { '.type': 'interface', '.anonymous': false, proto: 'wireguard' },
			a: { '.type': 'wireguard_wg1', '.anonymous': false, public_key: PK, allowed_ips: [ '10.42.0.2/33' ], ...(a ?? {}) },
			b: { '.type': 'wireguard_wg1', '.anonymous': false, public_key: PK2, allowed_ips: [ '10.42.0.3/32' ] },
		} } });
		c.set_ubus_response('network.interface.wg1', 'status', status ?? PENDING);
		return c;
	}
	function on(call) {
		return call(handler.make(wgp, { tx: {
			acquire: function() { return {}; }, release: function() {},
			reload: function() { return null; }, check_services: function() { return null; },
			wg_apply: wg.apply, wg_reconcile: function() { return null; },
		} }));
	}
	let kernel = (r) => [ r.status, r.headers["X-Kernel-Status"], r.headers["X-Kernel-Blocked"], r.headers["X-Kernel-Applied"] ];
	let reads = (c) => length(filter(c._state.ubus_calls, (x) => x[1] == "status"));
	const B = { interface: 'wg1', public_key: PK2, allowed_ips: [ '10.42.0.4/32' ] };

	t.it('a create, PUT, PATCH and DELETE of another peer keep their commit and wait for nothing', () => {
		let c = world();
		let r = on((h) => [ h.create(c, ctx(), { ...B, id: 'n' }), h.replace(c, ctx(), 'b', B),
		                         h.patch(c, ctx(), 'b', { description: 'x' }), h.remove(c, ctx(), 'n') ]);
		t.assert_deep_equal(map(r, kernel), [ [ 200, 'blocked', 'wg1/a', null ], [ 200, 'blocked', 'wg1/a', null ],
		                                      [ 200, 'blocked', 'wg1/a', null ], [ 204, 'blocked', 'wg1/a', null ] ]);
		t.assert_deep_equal([ c._state.uci.network.b.allowed_ips, c._state.uci.network.b.description, exists(c._state.uci.network, 'n') ],
		                    [ [ '10.42.0.4/32' ], 'x', false ]);
		t.assert_equal(reads(c), 0);
	});

	t.it('a write that fixes the peer, or deletes it, finds none and waits for the restart', () => {
		let c = world(null, DOWN);
		t.assert_deep_equal(kernel(on((h) => h.patch(c, ctx(), 'a', { allowed_ips: [ '10.42.0.2/32' ] }))), [ 200, 'skipped', null, null ]);
		t.assert_true(reads(c) > 0);
		c = world(null, DOWN);
		t.assert_deep_equal(kernel(on((h) => h.remove(c, ctx(), 'a'))), [ 204, 'skipped', null, null ]);
		t.assert_false(exists(c._state.uci.network, 'a'));
	});

	t.it('a write that enables the peer that keeps the interface down keeps its commit and names it', () => {
		let c = world({ disabled: '1', allowed_ips: [ '10.42.0.2/32' ], endpoint_host: 'fe80::1%nosuchdev0', endpoint_port: '51820' });
		t.assert_deep_equal(kernel(on((h) => h.patch(c, ctx(), 'a', { disabled: false }))), [ 200, 'blocked', 'wg1/a', null ]);
		t.assert_equal(c._state.uci.network.a.disabled, '0');
	});
});

// The live flag of an error says whether wg reads the value, and the apply takes the live errors of
// a peer as the values that keep its interface down, so the flag decides for the writes of the
// other peers too.
t.describe('network.wireguard_peers names only the values that keep the interface down', () => {
	function world(a) {
		return ubus.stub({ uci: { network: {
			wg1: { '.type': 'interface', '.anonymous': false, proto: 'wireguard' },
			a: { '.type': 'wireguard_wg1', '.anonymous': false, public_key: PK, allowed_ips: [ '10.42.0.2/32' ], ...a },
		} } });
	}
	let on = (a) => wgp.blockers(world(a), 'wg1');
	let live = (a) => map(wgp.validate_new({ ...wgp.fromUci({ ...a, '.name': 'a' }), id: 'a' }, world(a)), (e) => [ e.field, e.live ]);

	// The handler leaves the endpoint out for a port that it cannot read, and for an empty one, which
	// only a hand edit stores, so wg never reads the host.
	t.it('a host gives wg nothing without a port that the handler reads', () => {
		for (let host in [ '10.0.0.256', 'a:b' ]) {
			t.assert_deep_equal(on({ endpoint_host: host, endpoint_port: '51820' }), [ 'a' ], host);
			t.assert_deep_equal(on({ endpoint_host: host }), [ 'a' ], host);
			for (let port in [ '', 'nosuchservice', '0' ])
				t.assert_deep_equal(on({ endpoint_host: host, endpoint_port: port }), [], [ host, port ]);
		}
		t.assert_deep_equal(live({ public_key: PK, endpoint_host: '10.0.0.256', endpoint_port: '' }), [ [ 'endpoint_host', false ] ]);
		t.assert_deep_equal(live({ public_key: PK, endpoint_host: '10.0.0.256' }), [ [ 'endpoint_host', true ] ]);
		t.assert_deep_equal(live({ public_key: PK, endpoint_host: 'a:b', endpoint_port: 'nosuchservice' }),
		                    [ [ 'endpoint_host', false ], [ 'endpoint_port', false ] ]);
	});
	t.it('an allowed IP that wg takes without its whitespace, or after a +, keeps nothing down', () => {
		for (let ips in [ [ '10.42.0.2/32', '+10.42.3.0/24' ], '10.42.0.2/32\t' ])
			t.assert_deep_equal(on({ allowed_ips: ips }), [], ips);
		t.assert_deep_equal(on({ allowed_ips: [ ' 10.42.0.2/32 ', '+ 10.42.3.0/24' ] }), []);
		for (let ips in [ [ '-10.42.3.0/24' ], [ '10.42.0.2/32 10.42.3.0/24' ], [ '+10.42.3.0/33' ] ])
			t.assert_deep_equal(on({ allowed_ips: ips }), [ 'a' ], ips);
	});
	// The handler gives wg a key with padding bits that are not zero, which wg refuses, and skips a
	// peer whose key does not match its pattern.
	t.it('a key keeps the interface down only when wg reads no key from it', () => {
		t.assert_deep_equal(on({ public_key: substr(PK, 0, 42) + '5=' }), [ 'a' ]);
		t.assert_deep_equal(on({ public_key: PK + ' # b' }), []);
	});
	// The handler routes such a length in base 10, as wg reads it, so the interface comes up.
	t.it('a prefix length with a leading zero keeps nothing down', () => {
		t.assert_deep_equal(on({ allowed_ips: [ '10.0.0.0/08' ], route_allowed_ips: '1' }), []);
	});

	// A zone that names no interface of the router is no error of the section, so only the sweep and
	// the apply see it. The errors of a write already block every write of the peer.
	t.it('the sweep lists a peer that keeps its interface down, with the fields and no value', () => {
		let h = handler.make(wgp);
		let sweep = (a, iface) => {
			let c = world(a);
			if (iface != null) c._state.uci.network.wg1 = { ...c._state.uci.network.wg1, ...iface };
			return map(h.sweep(c), (f) => map(f.errors, (e) => [ e.field, e.code, e.message ]));
		};
		let r = sweep({ allowed_ips: [ '10.42.0.2/33' ], endpoint_host: 'fe80::1%nosuchdev0', endpoint_port: '51820' });
		t.assert_equal(length(r), 1);
		t.assert_deep_equal(r[0][length(r[0]) - 1],
		                    [ '', 'conflict', 'keeps the interface wg1 down: wg refuses the config of the whole interface for allowed_ips[0], endpoint_host of this peer, so the interface does not come up at its next start. Fix or disable this peer' ]);
		t.assert_deep_equal(sweep({ endpoint_host: 'fe80::1%nosuchdev0', endpoint_port: '51820' })[0][0][2],
		                    'keeps the interface wg1 down: wg refuses the config of the whole interface for endpoint_host of this peer, so the interface does not come up at its next start. Fix or disable this peer');
		t.assert_deep_equal(sweep({ endpoint_host: 'fe80::1%nosuchdev0', endpoint_port: '51820' }, { disabled: '1' }), []);
		t.assert_deep_equal(sweep({ endpoint_host: 'fe80::1%nosuchdev0', endpoint_port: '51820', disabled: '1' }), []);
		t.assert_deep_equal(sweep({}), []);
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

	// `route_allowed_ips` routes are withdrawn only if the op says the previous config installed them,
	// so the flag is read off the raw uci section as the handler reads it, which routes only for `1`.
	t.it('leaves prev_route_allowed_ips false for an existing section spelled true', () => {
		let c = with_wg();
		c._state.uci.network.g_existing.route_allowed_ips = 'true';
		let ops = [];
		let r = op_tracking_handler(ops).remove(c, ctx(), 'g_existing');
		t.assert_equal(r.status, 204);
		t.assert_equal(length(ops), 1);
		t.assert_false(ops[0].prev_route_allowed_ips);
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

	t.it('an unchanged public key emits only the set', () => {
		let ops = [];
		op_tracking_handler(ops).replace(with_wg(), ctx(), 'g_existing', {
			interface: 'wg1', public_key: PK, allowed_ips: ['10.42.0.5/32'],
		});
		t.assert_equal(length(ops), 1);
		t.assert_equal(ops[0].action, "set");
	});

	// validate() required allowed IPs, so a stored peer without any, which LuCI writes, took no
	// write at all, not even the one that disables it. wg sets such a peer with none.
	t.it('a peer without allowed IPs takes a PATCH, a disable, a create and a PUT, and is set with none', () => {
		let c = with_wg();
		delete c._state.uci.network.g_existing.allowed_ips;
		let ops = [];
		let h = op_tracking_handler(ops);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x' }).status, 200);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: true }).status, 200);
		let r = h.create(c, ctx(), { interface: 'wg1', public_key: PK2 });
		t.assert_equal(r.status, 200, r.body);
		t.assert_false(exists(c._state.uci.network[r.body.id], 'allowed_ips'));
		t.assert_deep_equal(map(ops, (o) => [ o.action, o.allowed_ips ]), [ [ 'set', [] ], [ 'remove', null ], [ 'set', [] ] ]);
		let c2 = with_wg();
		t.assert_equal(h.replace(c2, ctx(), 'g_existing', { interface: 'wg1', public_key: PK }).status, 200);
		t.assert_false(exists(c2._state.uci.network.g_existing, 'allowed_ips'));
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

	// /uapi/batch runs handlers in bare mode, which returns before any commit, so the
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

// The handler takes `disabled` and `route_allowed_ips` as on only when they hold "1". toUci writes the
// view back, so a flag that read on for another spelling was then rewritten as `1`.
t.describe('network.wireguard_peers reads a flag as the handler does', () => {
	function peer(disabled) {
		return { '.name': 'p1', '.type': 'wireguard_wg0', '.anonymous': false,
		         public_key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=',
		         allowed_ips: ['10.0.0.2/32'], disabled: disabled };
	}
	t.it('reads disabled as on only for 1, and writes it back as 1', () => {
		let view = wgp.fromUci(peer('1'), null);
		t.assert_true(view.disabled);
		t.assert_equal(wgp.toUci(view).disabled, '1');
		for (let spelling in [ 'true', 'on', 'yes', 'enabled', [ '1' ], '0' ])
			t.assert_false(wgp.fromUci(peer(spelling), null).disabled, spelling);
	});
	t.it('reads route_allowed_ips the same way', () => {
		let sec = peer('0');
		sec.route_allowed_ips = 'yes';
		t.assert_false(wgp.fromUci(sec, null).route_allowed_ips);
		sec.route_allowed_ips = '1';
		t.assert_true(wgp.fromUci(sec, null).route_allowed_ips);
	});
});

// The handler reads an allowed_ips option as its words, so a scalar holds one prefix per word, and a
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

// The handler joins the entries of allowed_ips with commas, and wg strips the whitespace of the line
// and splits it at commas. A space is no comma, so wg gets the one entry `10.42.0.2/3210.42.1.0/24`
// from a list entry that holds two prefixes, and refuses the config.
t.describe('network.wireguard_peers reads allowed_ips as wg gets them', () => {
	let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null };
	let h = handler.make(wgp, { tx });
	let read = (aips) => wgp.fromUci({ '.name': 'p1', '.type': 'wireguard_wg1', public_key: PK, allowed_ips: aips }, null).allowed_ips;
	function stored(aips, disabled) {
		let c = with_wg();
		c._state.uci.network.g_existing.allowed_ips = aips;
		if (disabled) c._state.uci.network.g_existing.disabled = '1';
		return c;
	}
	function body_of(c) {
		let b = h.get_one(c, ctx(), 'g_existing').body;
		for (let k in [ 'id', 'managed', 'runtime', 'has_preshared_key' ]) delete b[k];
		return b;
	}

	t.it('reads an option as its words, and a list entry as one entry', () => {
		t.assert_deep_equal(read('10.42.0.2/32\t10.42.1.0/24 '), [ '10.42.0.2/32', '10.42.1.0/24' ]);
		t.assert_deep_equal(read([ '10.42.0.2/32 10.42.1.0/24' ]), [ '10.42.0.2/32 10.42.1.0/24' ]);
	});

	t.it('a PUT of the read of such a list entry answers 422 and leaves it as stored', () => {
		for (let aips in [ [ '10.42.0.2/32 10.42.1.0/24' ], [ '10.42.0.2/32\t10.42.1.0/24' ] ]) {
			let c = stored(aips);
			let r = h.replace(c, ctx(), 'g_existing', body_of(c));
			t.assert_equal(r.status, 422, aips);
			t.assert_deep_equal(c._state.uci.network.g_existing.allowed_ips, aips);
		}
	});

	// The handler writes the line for such a value, and wg refuses it once it cuts it at `#`, so the
	// interface did not come up while every write of the peer passed.
	t.it('a value that wg reads as nothing blocks every write of the peer, one that disables it too', () => {
		for (let aips in [ '#c' ]) {
			let r = h.patch(stored(aips), ctx(), 'g_existing', { description: 'x' });
			t.assert_deep_equal(map(r.body?.errors ?? [], (e) => [ e.field, e.code ]), [ [ 'allowed_ips[0]', 'invalid_format' ] ], aips);
			t.assert_equal(h.patch(stored(aips), ctx(), 'g_existing', { disabled: true }).status, 422, aips);
		}
	});

	t.it('the entry blocks every write of the peer, enabled or disabled, until a write replaces it', () => {
		let aips = [ '10.42.0.2/32 10.42.1.0/24' ];
		let c = stored(aips);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x' }).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: true }).status, 422);
		c._state.uci.network.g_existing.disabled = '1';
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { description: 'x' }).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { allowed_ips: aips }).status, 422);
		t.assert_equal(h.replace(c, ctx(), 'g_existing', body_of(c)).status, 422);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { disabled: false }).status, 422);
		t.assert_deep_equal(c._state.uci.network.g_existing.allowed_ips, aips);
		t.assert_equal(h.patch(c, ctx(), 'g_existing', { allowed_ips: [ '10.42.0.2/32', '10.42.1.0/24' ] }).status, 200);
	});
});

// The handler gives wg a port of digits as uci holds it, or the port of a service name, and leaves
// out the endpoint for any other value.
t.describe('network.wireguard_peers reads endpoint_port as the handler does', () => {
	let read = (port) => wgp.fromUci({ '.name': 'p1', '.type': 'wireguard_wg0', '.anonymous': false,
	                                   public_key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=', allowed_ips: ['10.0.0.2/32'],
	                                   endpoint_host: '198.51.100.7', endpoint_port: port }, null).endpoint_port;
	t.it('reads decimals, nothing and whitespace', () => {
		t.assert_equal(read('51820'), 51820);
		t.assert_equal(read('+443'), 0);
		t.assert_equal(read(' 443'), 0);
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

t.describe('network.wireguard_peers reads endpoint_host and persistent_keepalive', () => {
	let read = (k, v) => wgp.fromUci({ '.name': 'p1', '.type': 'wireguard_wg0', [k]: v }, null)[k];
	t.it('reads a list endpoint_host as one string', () => {
		t.assert_equal(read('endpoint_host', [ 'vpn.example.com' ]), 'vpn.example.com');
	});
	t.it('reads a keepalive that the handler leaves out as -1, and off as 0', () => {
		t.assert_equal(read('persistent_keepalive', '25x'), -1);
		t.assert_equal(read('persistent_keepalive', '65536'), -1);
		t.assert_equal(read('persistent_keepalive', ' 25 '), -1);
		t.assert_equal(read('persistent_keepalive', 'off'), 0);
		t.assert_equal(read('persistent_keepalive', '25'), 25);
	});
});

// `wg` is a stub here: `wg show <if> dump` prints the text that a test gives for the interface, and
// fails for any other. The dump carries the private key of the interface and the preshared key of
// each peer, as wg prints them.
t.describe('network.wireguard_peers runtime', () => {
	let fs = require('fs');
	let wg = require('wg');
	const PK3 = 'mDpFbfhjQlpPqYFJRSKBRRJdPjRlnQhqBSVvhoLLRWc=';
	const PRIV = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
	const PSK = 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXphYmNkZWY=';
	let dump_of = (iface) => wg.command_line([ 'wg', 'show', iface, 'dump' ]) + ' 2>&1';
	let peer_line = (key, endpoint, aips, keepalive, handshake) =>
		sprintf("%s\t%s\t%s\t%s\t%d\t1234\t5678\t%s\n", key, PSK, endpoint, aips, handshake ?? 1730000000, keepalive);
	let dump = (lines) => sprintf("%s\t%s\t51820\toff\n", PRIV, PK2) + join("", lines);
	let wgif = { '.type': 'interface', '.anonymous': false, proto: 'wireguard' };
	let peer = (iface, extra) => ({ '.type': 'wireguard_' + iface, '.anonymous': false, ...extra });
	const STORED = { public_key: PK, allowed_ips: [ '10.0.0.2/32' ], endpoint_host: '192.0.2.1',
	                 endpoint_port: '51820', persistent_keepalive: '25' };

	function kernel(network, dumps, up) {
		let k = { ran: [] };
		let real = global.modules.wg;
		global.modules.wg = t.load_with_fs({ ...fs, popen: function(cmd) {
			push(k.ran, cmd);
			let iface = match(cmd, /^'wg' 'show' '([^']*)' 'dump' 2>&1$/)?.[1];
			let out = (iface != null) ? dumps[iface] : null;
			return { read: () => out ?? "Unable to access interface: No such device\n", close: () => (out != null) ? 0 : 1 };
		} }, [ 'wg' ]);
		k.mod = loadfile('src/resources/network.wireguard_peers.uc')();
		global.modules.wg = real;
		k.conn = ubus.stub({ uci: { network } });
		for (let i in up ?? keys(dumps)) k.conn.set_ubus_response('network.interface.' + i, 'status', { up: true });
		k.read = (id) => handler.make(k.mod).get_one(k.conn, ctx(), id).body;
		return k;
	}

	t.it('reads the peer that the kernel holds, and neither key of the dump', () => {
		let k = kernel({ wg1: wgif, a: peer('wg1', STORED) },
		               { wg1: dump([ peer_line(PK, '192.0.2.1:51820', '10.0.0.2/32', '25') ]) });
		let view = k.read('a');
		t.assert_deep_equal(view.runtime, { in_kernel: true, endpoint: '192.0.2.1:51820', allowed_ips: [ '10.0.0.2/32' ],
		                                    persistent_keepalive: 25, latest_handshake: 1730000000, rx_bytes: 1234, tx_bytes: 5678 });
		let text = sprintf("%J", view);
		t.assert_true(index(text, PSK) < 0 && index(text, PRIV) < 0, text);
		t.assert_deep_equal(k.ran, [ dump_of('wg1') ]);
	});

	// The handler gives wg port 51820 for a peer with a host and no port, as the kernel apply and the
	// restore do, and the read keeps the port as uci holds it.
	t.it('reads no port for a peer with a host and no port, and the endpoint with port 51820 that the kernel holds', () => {
		let k = kernel({ wg1: wgif, a: peer('wg1', { public_key: PK, allowed_ips: [ '10.0.0.2/32' ], endpoint_host: '192.0.2.1' }) },
		               { wg1: dump([ peer_line(PK, '192.0.2.1:51820', '10.0.0.2/32', 'off') ]) });
		let view = k.read('a');
		t.assert_deep_equal([ view.endpoint_host, view.endpoint_port, view.runtime.in_kernel, view.runtime.endpoint ],
		                    [ '192.0.2.1', null, true, '192.0.2.1:51820' ]);
		t.assert_deep_equal(handler.make(k.mod).sweep(k.conn), []);
	});

	t.it('reads the endpoint, keepalive and allowed IPs of the kernel beside the ones that uci holds', () => {
		let k = kernel({ wg1: wgif, a: peer('wg1', STORED), b: peer('wg1', { public_key: PK2 }) },
		               { wg1: dump([ peer_line(PK2, '(none)', '(none)', 'off', 0),
		                             peer_line(PK, '198.51.100.9:51820', '10.0.0.2/32,10.0.0.3/32', '77') ]) });
		let view = k.read('a');
		t.assert_equal(view.runtime.endpoint, '198.51.100.9:51820');
		t.assert_deep_equal(view.runtime.allowed_ips, [ '10.0.0.2/32', '10.0.0.3/32' ]);
		t.assert_equal(view.runtime.persistent_keepalive, 77);
		t.assert_equal(view.endpoint_host, '192.0.2.1');
		t.assert_deep_equal(view.allowed_ips, [ '10.0.0.2/32' ]);
		t.assert_equal(view.persistent_keepalive, 25);
		t.assert_deep_equal(k.read('b').runtime, { in_kernel: true, endpoint: null, allowed_ips: [], persistent_keepalive: 0,
		                                           latest_handshake: 0, rx_bytes: 1234, tx_bytes: 5678 });
	});

	t.it('reads a peer that the kernel does not hold, and a stored value that is not a key, as not in the kernel', () => {
		let k = kernel({ wg1: wgif, a: peer('wg1', STORED), b: peer('wg1', { public_key: 'not-a-key' }) },
		               { wg1: dump([ peer_line(PK2, '(none)', '10.0.0.9/32', 'off') ]) });
		let absent = { in_kernel: false, endpoint: null, allowed_ips: null, persistent_keepalive: null,
		               latest_handshake: null, rx_bytes: null, tx_bytes: null };
		t.assert_deep_equal(k.read('a').runtime, absent);
		t.assert_deep_equal(k.read('b').runtime, absent);
	});

	t.it('reads nothing for an interface that is not up, and an empty runtime, not a missing peer, when wg fails', () => {
		let down = kernel({ wg1: wgif, a: peer('wg1', STORED) }, {}, []);
		t.assert_deep_equal(down.read('a').runtime, {});
		t.assert_deep_equal(down.ran, []);
		let failing = kernel({ wg1: wgif, a: peer('wg1', STORED) }, {}, [ 'wg1' ]);
		t.assert_deep_equal(failing.read('a').runtime, {});
		t.assert_deep_equal(failing.ran, [ dump_of('wg1') ]);
	});

	// The fields are read by position. A field more after the public key put the preshared key in
	// `endpoint`, and a short line was skipped, so a peer that the kernel holds read as not in it.
	t.it('reads every peer of a dump that holds a line of another shape as not read', () => {
		let fields = [ PK, PSK, '203.0.113.7:51820', '10.0.0.2/32', '1730000000', '1234', '5678', '25' ];
		let other = peer_line(PK2, '(none)', '10.0.0.9/32', 'off');
		let dumps = {
			short: dump([ other, join("\t", slice(fields, 0, 7)) + "\n" ]),
			long: dump([ other, join("\t", [ PK, 'EXTRA', ...slice(fields, 1) ]) + "\n" ]),
			interface: sprintf("%s\tEXTRA\t%s\t51820\toff\n", PRIV, PK2) + other + join("\t", fields) + "\n",
		};
		for (let shape, text in dumps) {
			let k = kernel({ wg1: wgif, a: peer('wg1', STORED), b: peer('wg1', { public_key: PK2 }) }, { wg1: text });
			let r = handler.make(k.mod).list(k.conn, ctx(), {});
			t.assert_deep_equal(map(r.body, (v) => v.runtime), [ {}, {} ], shape);
			let read = sprintf("%J", r.body);
			for (let f in [ PSK, 'EXTRA', '203.0.113.7', '10.0.0.9/32', '1730000000', '5678' ])
				t.assert_true(index(read, f) < 0, sprintf("%s: %s in %s", shape, f, read));
		}
	});

	// Read inside a write, the runtime would come from before the kernel apply, so a POST would answer
	// in_kernel false beside X-Kernel-Status ok, and every write would run `wg show` under the lock.
	t.it('a write answers an empty runtime and reads no kernel state, and a GET after it reads the kernel', () => {
		let k = kernel({ wg1: wgif, a: peer('wg1', STORED) },
		               { wg1: dump([ peer_line(PK, '198.51.100.9:51820', '10.0.0.2/32', '77'),
		                             peer_line(PK2, '(none)', '10.0.0.3/32', 'off') ]) });
		let applied = [];
		let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null,
		           wg_apply: function(c, ops) { push(applied, ...ops); return null; }, wg_reconcile: () => null };
		let h = handler.make(k.mod, { tx });
		let bare = handler.make(k.mod, { tx: { bare: true } });
		let jctx = { ...ctx(), json_patch: true };
		let writes = [
			[ 'POST', h.create(k.conn, ctx(), { id: 'b', interface: 'wg1', public_key: PK2, allowed_ips: [ '10.0.0.3/32' ] }) ],
			[ 'PATCH', h.patch(k.conn, ctx(), 'a', { persistent_keepalive: 30 }) ],
			[ 'PUT', h.replace(k.conn, ctx(), 'a', { interface: 'wg1', public_key: PK, allowed_ips: [ '10.0.0.2/32' ], persistent_keepalive: 25 }) ],
			[ 'JSON Patch', h.patch(k.conn, jctx, 'a', [ { op: 'replace', path: '/description', value: 'x' } ]) ],
			[ 'batch POST', bare.create(k.conn, { ...ctx(), kernel_sink: [] }, { id: 'c', interface: 'wg1', public_key: PK3 }) ],
			[ 'batch PATCH', bare.patch(k.conn, { ...ctx(), kernel_sink: [] }, 'a', { description: 'y' }) ],
		];
		for (let w in writes)
			t.assert_true(w[1].status == 200 && type(w[1].body.runtime) == "object" && length(w[1].body.runtime) == 0,
			              sprintf("%s answered %d %J", w[0], w[1].status, w[1].body));
		t.assert_equal(h.patch(k.conn, ctx(), 'a', { persistent_keepalive: -1 }).status, 422);
		t.assert_equal(h.remove(k.conn, ctx(), 'c').status, 204);
		t.assert_true(length(applied) > 0, 'no write reached the apply');
		t.assert_deep_equal(k.ran, []);
		t.assert_equal(length(filter(k.conn._state.ubus_calls, (c) => c[1] == 'status')), 0);
		t.assert_deep_equal(k.read('b').runtime, { in_kernel: true, endpoint: null, allowed_ips: [ '10.0.0.3/32' ], persistent_keepalive: 0,
		                                           latest_handshake: 1730000000, rx_bytes: 1234, tx_bytes: 5678 });
		t.assert_equal(k.read('a').runtime.persistent_keepalive, 77);
		t.assert_deep_equal(k.ran, [ dump_of('wg1') ]);
	});

	t.it('reads each interface once in a collection GET', () => {
		let k = kernel({ wg1: wgif, wg2: wgif, wg3: wgif,
		                 a: peer('wg1', STORED), b: peer('wg2', { public_key: PK3 }), c: peer('wg1', { public_key: PK2 }),
		                 d: peer('wg3', STORED), e: peer('wg2', { public_key: PK }) },
		               { wg1: dump([ peer_line(PK, '192.0.2.1:51820', '10.0.0.2/32', '25') ]),
		                 wg2: dump([ peer_line(PK3, '(none)', '10.0.1.2/32', 'off'), peer_line(PK, '(none)', '10.0.1.3/32', 'off') ]) },
		               [ 'wg1', 'wg2' ]);
		let r = handler.make(k.mod).list(k.conn, ctx(), {});
		t.assert_equal(r.status, 200);
		let rt = {};
		for (let v in r.body) rt[v.id] = v.runtime;
		t.assert_deep_equal(sort(k.ran), sort([ dump_of('wg1'), dump_of('wg2') ]));
		t.assert_equal(length(filter(k.conn._state.ubus_calls, (c) => c[1] == 'status')), 3);
		t.assert_true(rt.a.in_kernel && rt.b.in_kernel && rt.e.in_kernel && !rt.c.in_kernel, sprintf("%J", rt));
		t.assert_deep_equal([ rt.a.allowed_ips, rt.b.allowed_ips, rt.e.allowed_ips ], [ [ '10.0.0.2/32' ], [ '10.0.1.2/32' ], [ '10.0.1.3/32' ] ]);
		t.assert_deep_equal(rt.d, {});
	});

	// A /uapi/batch runs every sub-request before its commit and its kernel apply, so a GET in a batch that
	// writes would answer as drift what the apply of the batch then changes. A batch of reads has no apply.
	t.it('a GET in a batch that writes answers an empty runtime and reads no kernel state', () => {
		let k = kernel({ wg1: wgif, a: peer('wg1', STORED) }, { wg1: dump([ peer_line(PK, '(none)', '10.0.0.2/32', 'off') ]) });
		let bare = handler.make(k.mod, { tx: { bare: true } });
		let in_batch = (writes) => ({ ...ctx(), kernel_sink: [], batch_writes: writes });
		t.assert_deep_equal(bare.get_one(k.conn, in_batch(true), 'a').body.runtime, {});
		t.assert_deep_equal(map(bare.list(k.conn, in_batch(true), {}).body, (v) => v.runtime), [ {} ]);
		t.assert_deep_equal(k.ran, []);
		t.assert_equal(length(filter(k.conn._state.ubus_calls, (c) => c[1] == 'status')), 0);
		t.assert_true(bare.get_one(k.conn, in_batch(false), 'a').body.runtime.in_kernel);
		t.assert_deep_equal(k.ran, [ dump_of('wg1') ]);
	});

	// The handler gives wg the key as uci holds it, and skips a peer whose key is not a WireGuard key.
	t.it('matches a stored key only as uci holds it', () => {
		let network = { wg1: wgif, a: peer('wg1', { public_key: PK }) };
		for (let id, key in { b: ' ' + PK, c: [ PK ], d: substr(PK, 0, 43) + '\\075' }) network[id] = peer('wg1', { public_key: key });
		let k = kernel(network, { wg1: dump([ peer_line(PK, '(none)', '10.0.0.2/32', 'off') ]) });
		t.assert_deep_equal(k.read('a').runtime.allowed_ips, [ '10.0.0.2/32' ]);
		for (let id in [ 'b', 'c', 'd' ])
			t.assert_false(k.read(id).runtime.in_kernel, id);
	});
});
