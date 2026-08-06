let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let wgp = loadfile('src/resources/network.wireguard_peers.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
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

let handler = require('handler');

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
						public_key: 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=',
						allowed_ips: ['10.42.0.2/32'],
					},
				},
			},
		});
	}

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

// netifd only reads peer sections inside the proto setup step, so a network
// reload leaves the kernel untouched: the peer is committed and never applied,
// and a delete does not revoke it. Every write has to emit the peer operations
// the transaction then pushes to the kernel.
t.describe('network.wireguard_peers kernel apply', () => {
	const PK = 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=';
	const PK2 = 'TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=';

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
});
