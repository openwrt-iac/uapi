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
