let t = require('harness');
let handler = require('handler');
let ubus = require('bus');

let interfaces = loadfile('src/resources/network.interfaces.uc')();

const CREDENTIAL_PROTOS = [ 'pppoe', 'ppp', 'wwan', 'openvpn' ];
const ctx = { request_id: "01hx0000000000000000000000" };
let codes = (errs, field) => map(filter(errs, (e) => e.field == field), (e) => e.code);

function ifh() {
	return handler.make(interfaces, {
		tx: {
			acquire: function() { return {}; }, release: function() {},
			reload: function() { return null; }, check_services: function() { return null; },
		},
	});
}
function seeded(proto, extra) {
	return ubus.stub({ uci: { network: {
		wan: { '.type': 'interface', '.anonymous': false, proto: proto ?? 'pppoe', device: 'eth1',
		       username: 'isp-user', password: 'isp-pw', ...(extra ?? {}) },
	} } });
}
function read_back(h, c) {
	let body = { ...h.get_one(c, ctx, 'wan').body };
	delete body.runtime;
	return body;
}

t.describe('network.interfaces username and password', () => {
	t.it('reads username and has_password on each proto whose handler reads them, and masks password', () => {
		for (let proto in CREDENTIAL_PROTOS) {
			let v = interfaces.fromUci({ '.name': 'wan', proto, username: 'u', password: 'pw' }, null);
			t.assert_deep_equal([ v.username, v.has_password, exists(v, 'password') ], [ 'u', true, false ], proto);
			let empty = interfaces.fromUci({ '.name': 'wan', proto, password: '' }, null);
			t.assert_deep_equal([ empty.username, empty.has_password ], [ null, false ], proto);
		}
	});

	t.it('hides them on the other protos, and on a proto that uapi does not model', () => {
		for (let proto in [ 'static', 'dhcp', 'dhcpv6', 'none', 'wireguard', 'l2tp', 'qmi' ]) {
			let v = interfaces.fromUci({ '.name': 'wan', proto, username: 'u', password: 'pw' }, null);
			for (let k in [ 'username', 'password', 'has_password' ])
				t.assert_false(exists(v, k), proto + ' ' + k);
		}
	});

	t.it('writes them on each of these protos and drops them elsewhere', () => {
		for (let proto in CREDENTIAL_PROTOS) {
			let u = interfaces.toUci({ proto, username: 'u', password: 'pw' });
			t.assert_deep_equal([ u.username, u.password ], [ 'u', 'pw' ], proto);
		}
		let u = interfaces.toUci({ proto: 'dhcp', username: 'u', password: 'pw' });
		t.assert_false(exists(u, 'username') || exists(u, 'password'));
	});

	t.it('refuses them on another proto with conflict, and names the four protos', () => {
		for (let proto in CREDENTIAL_PROTOS)
			t.assert_deep_equal(filter(interfaces.validate({ proto, username: 'u', password: 'pw' }, null),
			                           (e) => e.code == 'conflict'), [], proto);
		let errs = interfaces.validate({ proto: 'dhcp', username: 'u', password: 'pw' }, null);
		t.assert_deep_equal([ codes(errs, 'username'), codes(errs, 'password') ], [ [ 'conflict' ], [ 'conflict' ] ]);
		t.assert_equal(errs[0].message, 'applies only when proto is one of pppoe, ppp, wwan, openvpn; send null or leave it out');
		t.assert_deep_equal(interfaces.validate({ proto: 'dhcp', has_password: true, username: null }, null), []);
	});

	t.it('a PATCH keeps the password that the read masks, and a sent one replaces it', () => {
		let h = ifh();
		let c = seeded();
		t.assert_equal(h.patch(c, ctx, 'wan', { mtu: 1480 }).status, 200);
		let s = c._state.uci.network.wan;
		t.assert_deep_equal([ s.username, s.password, s.mtu ], [ 'isp-user', 'isp-pw', '1480' ]);
		t.assert_equal(h.patch(c, ctx, 'wan', { username: 'new-user', password: 'new-pw' }).status, 200);
		s = c._state.uci.network.wan;
		t.assert_deep_equal([ s.username, s.password ], [ 'new-user', 'new-pw' ]);
	});

	t.it('a PUT keeps the password that it leaves out, removes the username that it leaves out, and removes a password sent empty', () => {
		let h = ifh();
		let c = seeded();
		let body = read_back(h, c);
		t.assert_deep_equal([ body.username, body.has_password ], [ 'isp-user', true ]);
		t.assert_equal(h.replace(c, ctx, 'wan', body).status, 200);
		t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ 'isp-user', 'isp-pw' ]);
		t.assert_equal(h.replace(c, ctx, 'wan', { proto: 'pppoe', device: 'eth1' }).status, 200);
		t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ null, 'isp-pw' ]);
		t.assert_equal(h.replace(c, ctx, 'wan', { proto: 'pppoe', device: 'eth1', password: '' }).status, 200);
		t.assert_false(read_back(h, c).has_password);
	});

	t.it('a switch to another proto removes both unless it sends them, by PATCH, JSON Patch and PUT', () => {
		let h = ifh();
		let jp = { ...ctx, json_patch: true };
		for (let w in [ [ 'pppoe', ctx, { proto: 'dhcp' }, 'patch' ],
		                [ 'pppoe', jp, [ { op: 'replace', path: '/proto', value: 'dhcp' } ], 'patch' ],
		                [ 'pppoe', ctx, { proto: 'dhcp', device: 'eth1' }, 'replace' ],
		                [ 'pppoe', ctx, { proto: 'openvpn' }, 'patch' ],
		                [ 'openvpn', ctx, { proto: 'pppoe' }, 'patch' ],
		                [ 'pppoe', jp, [ { op: 'replace', path: '/proto', value: 'wwan' } ], 'patch' ],
		                [ 'pppoe', ctx, { proto: 'ppp', device: 'eth1' }, 'replace' ] ]) {
			let c = seeded(w[0]);
			let r = h[w[3]](c, w[1], 'wan', w[2]);
			t.assert_equal(r.status, 200, w);
			t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ null, null ], w);
			t.assert_deep_equal([ r.body.username, r.body.has_password ],
			                    (r.body.proto == 'dhcp') ? [ null, null ] : [ null, false ], w);
		}
	});

	t.it('a switch that sends them stores them, and one that sends a user name alone removes the password', () => {
		let h = ifh();
		let c = seeded();
		t.assert_equal(h.patch(c, ctx, 'wan', { proto: 'openvpn', username: 'vpn-user', password: 'vpn-pw' }).status, 200);
		t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ 'vpn-user', 'vpn-pw' ]);
		let r = h.patch(c, { ...ctx, json_patch: true }, 'wan', [ { op: 'replace', path: '/proto', value: 'wwan' },
		                                                         { op: 'add', path: '/password', value: 'apn-pw' } ]);
		t.assert_equal(r.status, 200, r.body);
		t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ null, 'apn-pw' ]);
		t.assert_equal(h.replace(c, ctx, 'wan', { proto: 'ppp', device: 'eth1', username: 'isp-user' }).status, 200);
		t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ 'isp-user', null ]);
	});

	t.it('a write that sends the stored proto is no switch, and keeps both', () => {
		let h = ifh();
		let c = seeded();
		t.assert_equal(h.patch(c, ctx, 'wan', { proto: 'pppoe', mtu: 1480 }).status, 200);
		t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ 'isp-user', 'isp-pw' ]);
		t.assert_equal(h.replace(c, ctx, 'wan', read_back(h, c)).status, 200);
		t.assert_deep_equal([ c._state.uci.network.wan.username, c._state.uci.network.wan.password ], [ 'isp-user', 'isp-pw' ]);
	});

	// The read of qmi hides both, so a PATCH did not count them as options of the section.
	t.it('a switch from a proto that uapi does not model removes the login that its read hides', () => {
		let h = ifh();
		for (let to in [ 'pppoe', 'dhcp' ]) {
			let c = seeded('qmi', { apn: 'internet' });
			t.assert_equal(h.patch(c, ctx, 'wan', { proto: to }).status, 200, to);
			let s = c._state.uci.network.wan;
			t.assert_deep_equal([ s.proto, s.username, s.password, s.apn ], [ to, null, null, 'internet' ], to);
		}
	});

	t.it('a null on a proto that uapi does not model keeps the login that its handler reads', () => {
		let h = ifh();
		let c = seeded('qmi');
		t.assert_equal(h.patch(c, ctx, 'wan', { username: null, password: null, mtu: 1400 }).status, 200);
		let s = c._state.uci.network.wan;
		t.assert_deep_equal([ s.username, s.password, s.mtu ], [ 'isp-user', 'isp-pw', '1400' ]);
	});

	t.it('publishes one conditional that sets them to null on every other modelled proto', () => {
		let groups = filter(interfaces.openapi_conditional, (c) => exists(c.then?.properties ?? {}, 'username'));
		t.assert_equal(length(groups), 1);
		t.assert_deep_equal(sort(keys(groups[0].then.properties)), [ 'has_password', 'password', 'username' ]);
		t.assert_deep_equal(sort([ ...groups[0].if.properties.proto.enum ]), [ 'dhcp', 'dhcpv6', 'none', 'static', 'wireguard' ]);
	});
});
