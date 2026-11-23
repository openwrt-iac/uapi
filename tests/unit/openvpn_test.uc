let t = require('harness');
let handler = require('handler');
let ubus = require('bus');

let interfaces = loadfile('src/resources/network.interfaces.uc')();

function full_validate(body) {
	let out = [];
	for (let e in handler.check_schema_types(handler.request_properties(interfaces.schema_properties), body)) push(out, e);
	for (let e in interfaces.validate(body, null)) push(out, e);
	return out;
}
let codes = (errs, field) => map(filter(errs, (e) => e.field == field), (e) => e.code);

function ifh() {
	return handler.make(interfaces, {
		tx: {
			acquire: function() { return {}; }, release: function() {},
			reload: function() { return null; }, check_services: function() { return null; },
		},
	});
}
const ctx = { request_id: "01hx0000000000000000000000" };
function seeded(extra) {
	return ubus.stub({ uci: { network: {
		vpn0: { '.type': 'interface', '.anonymous': false, proto: 'openvpn', dev: 'tun0', client: '1',
		        key: '/etc/openvpn/old.key', tls_auth: '/etc/openvpn/old.ta', pkcs12: '/etc/openvpn/old.p12',
		        password: 'old-pw', cert_password: 'old-cpw', ...(extra ?? {}) },
	} } });
}

t.describe('network.interfaces proto openvpn', () => {
	t.it('reads each option as netifd hands it to the handler', () => {
		let v = interfaces.fromUci({ '.name': 'vpn0', proto: 'openvpn', client: 'true', nobind: 'yes', float: 'on',
			persist_key: '1', port: '0x4aa', verb: '010', cipher: [ 'AES-256-CBC' ], remote: 'a.example 1194',
			push: [ 'route 10.0.0.0 255.255.255.0' ], data_ciphers: 'AES-256-GCM', ovpnproto: 'tcp-client' }, null);
		t.assert_deep_equal([ v.client, v.nobind, v.float, v.persist_key, v.tls_server ], [ true, false, false, true, false ]);
		t.assert_deep_equal([ v.port, v.verb, v.cipher, v.ovpnproto ], [ 1194, 8, null, 'tcp-client' ]);
		t.assert_deep_equal(v.remote, [ 'a.example', '1194' ]);
		t.assert_deep_equal(v.push, [ 'route 10.0.0.0 255.255.255.0' ]);
		t.assert_deep_equal(v.data_ciphers, [ 'AES-256-GCM' ]);
		t.assert_deep_equal([ v.route, v.dev ], [ null, null ]);
	});

	t.it('masks each secret and reads its has_ twin', () => {
		let v = interfaces.fromUci({ '.name': 'vpn0', proto: 'openvpn', key: '/k', tls_auth: '/t', pkcs12: '',
			password: 'pw' }, null);
		for (let k in [ 'key', 'tls_auth', 'pkcs12', 'password', 'cert_password' ])
			t.assert_false(exists(v, k), k);
		t.assert_deep_equal([ v.has_key, v.has_tls_auth, v.has_pkcs12, v.has_password, v.has_cert_password ],
		                    [ true, true, false, true, false ]);
	});

	t.it('writes booleans as 1 or 0, integers as decimals and lists as uci lists', () => {
		let u = interfaces.toUci({ proto: 'openvpn', client: false, tls_client: true, port: 1194, verb: 3,
			remote: [ 'a.example 1194' ], data_ciphers: [ 'AES-256-GCM' ], ovpnproto: 'udp', key: '/k', password: 'pw' });
		t.assert_deep_equal([ u.client, u.tls_client, u.port, u.verb ], [ '0', '1', '1194', '3' ]);
		t.assert_deep_equal([ u.remote, u.data_ciphers ], [ [ 'a.example 1194' ], [ 'AES-256-GCM' ] ]);
		t.assert_deep_equal([ u.ovpnproto, u.key, u.password ], [ 'udp', '/k', 'pw' ]);
		t.assert_false(exists(u, 'enabled'));
	});

	t.it('hides the openvpn options on another proto, also on one that uapi does not model', () => {
		for (let proto in [ 'static', 'wireguard', 'l2tp' ]) {
			let v = interfaces.fromUci({ '.name': 'x', proto, server: 'lns.example', password: 'pw', client: '1',
				port: '1701', remote: 'a' }, null);
			for (let k in [ 'server', 'has_password', 'client', 'port', 'remote' ])
				t.assert_false(exists(v, k), proto + ' ' + k);
			let u = interfaces.toUci({ proto, server: 'x', client: true, remote: [ 'a' ] });
			t.assert_false(exists(u, 'server') || exists(u, 'client') || exists(u, 'remote'), proto);
		}
		let l2tp = interfaces.fromUci({ '.name': 'x', proto: 'l2tp', private_key: 'k' }, null);
		t.assert_false(exists(l2tp, 'has_private_key'));
	});

	t.it('reads and writes peerdns and nohostroute, which openvpn-hotplug and netifd honour for it', () => {
		let v = interfaces.fromUci({ '.name': 'vpn0', proto: 'openvpn', peerdns: '0', nohostroute: '1', metric: '5',
			defaultroute: '0' }, null);
		t.assert_deep_equal([ v.peerdns, v.nohostroute, v.metric, v.defaultroute ], [ false, true, 5, false ]);
		t.assert_deep_equal(filter(interfaces.validate({ proto: 'openvpn', peerdns: false, nohostroute: true }, null),
		                           (e) => e.code == 'conflict'), []);
		let u = interfaces.toUci({ proto: 'openvpn', peerdns: false, nohostroute: true });
		t.assert_deep_equal([ u.peerdns, u.nohostroute ], [ '0', '1' ]);
	});

	t.it('refuses an openvpn field on another proto, and lets a has_ twin through on every proto', () => {
		t.assert_deep_equal(codes(interfaces.validate({ proto: 'dhcp', client: true }, null), 'client'), [ 'conflict' ]);
		t.assert_deep_equal(codes(interfaces.validate({ proto: 'wireguard', ovpnproto: 'udp' }, null), 'ovpnproto'), [ 'conflict' ]);
		t.assert_equal(interfaces.validate({ proto: 'dhcp', key: '/k' }, null)[0].message,
		               'applies only when proto is openvpn; send null or leave it out');
		t.assert_deep_equal(interfaces.validate({ proto: 'dhcp', has_key: true, has_password: false, has_private_key: true }, null), []);
		t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', has_private_key: true }, null), 'has_private_key'), []);
	});

	t.it('takes every transport spelling that openvpn takes, and tun or tap on write', () => {
		for (let p in [ 'udp', 'tcp', 'tcp-client', 'tcp-server', 'udp4', 'tcp4-server', 'udp6', 'tcp6-client' ])
			t.assert_deep_equal(codes(full_validate({ proto: 'openvpn', ovpnproto: p }), 'ovpnproto'), [], p);
		t.assert_deep_equal(codes(full_validate({ proto: 'openvpn', ovpnproto: 'sctp' }), 'ovpnproto'), [ 'not_in_enum' ]);
		t.assert_deep_equal(codes(full_validate({ proto: 'openvpn', dev_type: 'tap' }), 'dev_type'), []);
		t.assert_deep_equal(codes(full_validate({ proto: 'openvpn', dev_type: 'null' }), 'dev_type'), [ 'not_in_enum' ]);
		t.assert_deep_equal(codes(full_validate({ proto: 'openvpn', verb: 12 }), 'verb'), [ 'out_of_range' ]);
	});

	t.it('refuses a path that is relative or holds shell meta, on each file field and secret', () => {
		for (let k in [ 'ca', 'cert', 'dh', 'crl_verify', 'tls_crypt', 'config', 'log', 'log_append', 'key', 'tls_auth', 'pkcs12' ]) {
			t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', [k]: '$(reboot)' }, null), k), [ 'invalid_format' ], k);
			t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', [k]: 'etc/openvpn/x' }, null), k), [ 'invalid_format' ], k);
			t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', [k]: '/etc/openvpn/x.pem' }, null), k), [], k);
		}
		t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', password: 'not a path' }, null), 'password'), []);
	});

	t.it('takes an address or a host name for local, as LuCI does', () => {
		for (let v in [ '192.0.2.1', '2001:db8::1', 'vpn.example.com', 'host_1' ])
			t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', local: v }, null), 'local'), [], v);
		for (let v in [ '999.1.1.1', 'bad host', '-x.example', '$(reboot)' ])
			t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', local: v }, null), 'local'), [ 'invalid_format' ], v);
	});

	// openvpn 2.7 options.c assigns options->ncp_ciphers for each --data-ciphers.
	t.it('refuses several data_ciphers entries, a stored list too, and takes one entry of joined names', () => {
		t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', data_ciphers: [ 'AES-256-GCM:CHACHA20-POLY1305' ] }, null), 'data_ciphers'), []);
		t.assert_deep_equal(codes(interfaces.validate({ proto: 'openvpn', data_ciphers: [ 'AES-256-GCM', 'AES-128-GCM' ] }, null), 'data_ciphers'), [ 'conflict' ]);
		let h = ifh();
		let c = seeded({ data_ciphers: [ 'AES-256-GCM', 'AES-128-GCM' ] });
		t.assert_deep_equal(map(filter(h.sweep(c), (s) => s.id == 'vpn0')[0].errors, (e) => e.field + ':' + e.code),
		                    [ 'data_ciphers:conflict' ]);
		t.assert_equal(h.patch(c, ctx, 'vpn0', { verb: 3 }).status, 422);
		t.assert_equal(h.patch(c, ctx, 'vpn0', { data_ciphers: [ 'AES-256-GCM:AES-128-GCM' ] }).status, 200);
		t.assert_deep_equal(c._state.uci.network.vpn0.data_ciphers, [ 'AES-256-GCM:AES-128-GCM' ]);
	});

	t.it('a PATCH and a PUT keep the secrets that the read masks, and a sent one replaces its value', () => {
		let h = ifh();
		let c = seeded();
		t.assert_equal(h.patch(c, ctx, 'vpn0', { verb: 4 }).status, 200);
		let body = { ...h.get_one(c, ctx, 'vpn0').body };
		delete body.runtime;
		t.assert_equal(h.replace(c, ctx, 'vpn0', body).status, 200);
		let s = c._state.uci.network.vpn0;
		t.assert_deep_equal([ s.key, s.tls_auth, s.pkcs12, s.password, s.cert_password, s.verb ],
		                    [ '/etc/openvpn/old.key', '/etc/openvpn/old.ta', '/etc/openvpn/old.p12', 'old-pw', 'old-cpw', '4' ]);
		t.assert_equal(h.patch(c, ctx, 'vpn0', { key: '/etc/openvpn/new.key', password: 'new-pw' }).status, 200);
		t.assert_deep_equal([ c._state.uci.network.vpn0.key, c._state.uci.network.vpn0.password ], [ '/etc/openvpn/new.key', 'new-pw' ]);
	});

	t.it('a switch to another proto removes the openvpn options, secrets included, by PATCH as by PUT', () => {
		let h = ifh();
		let to_dhcp = { proto: 'dhcp' };
		for (let w in [ [ ctx, to_dhcp, 'patch' ], [ { ...ctx, json_patch: true }, [ { op: 'replace', path: '/proto', value: 'dhcp' } ], 'patch' ],
		                [ ctx, to_dhcp, 'replace' ] ]) {
			let c = seeded({ mtu: '1400' });
			t.assert_equal(h[w[2]](c, w[0], 'vpn0', w[1]).status, 200, w);
			let s = c._state.uci.network.vpn0;
			t.assert_deep_equal([ s.proto, s.dev, s.client, s.key, s.password, s.cert_password ], [ 'dhcp', null, null, null, null, null ], w);
		}
	});

	t.it('a PUT removes an option that uapi does not model, and a PATCH keeps it', () => {
		let h = ifh();
		let c = seeded({ mode: 'server', enabled: '0' });
		t.assert_equal(h.patch(c, ctx, 'vpn0', { verb: 3 }).status, 200);
		t.assert_deep_equal([ c._state.uci.network.vpn0.mode, c._state.uci.network.vpn0.enabled ], [ 'server', '0' ]);
		t.assert_equal(h.replace(c, ctx, 'vpn0', { proto: 'openvpn', dev: 'tun0' }).status, 200);
		t.assert_deep_equal([ c._state.uci.network.vpn0.mode, c._state.uci.network.vpn0.enabled ], [ null, null ]);
	});

	// uapi-mcp drops the allOf conditionals, so an agent learns the scope of a field only from its
	// description.
	t.it('starts the description of each field that the conditionals scope to openvpn with that scope', () => {
		let all = interfaces.schema_properties.proto["x-uapi-write"].enum;
		let scoped = filter(interfaces.openapi_conditional, (c) => {
			let others = c.if?.properties?.proto?.enum;
			return type(others) == "array" && length(others) == length(all) - 1 && index(others, 'openvpn') == -1;
		});
		t.assert_equal(length(scoped), 1);
		let fields = keys(scoped[0].then.properties);
		t.assert_true(length(fields) > 50, fields);
		for (let f in fields)
			t.assert_equal(substr(interfaces.schema_properties[f].description, 0, 19), 'proto openvpn only.', f);
	});

	t.it('names a new tunnel vpn_<rand>, within the 15 chars of an interface name', () => {
		let id = interfaces.id_for_create({ proto: 'openvpn' });
		t.assert_match(id, /^vpn_[0-9a-hjkmnp-tv-z]{11}$/);
		let c = ubus.stub({ uci: { network: {} } });
		let r = ifh().create(c, ctx, { proto: 'openvpn', dev: 'tun0', remote: [ 'a.example' ] });
		t.assert_equal(r.status, 200, r.body);
		t.assert_match(r.body.id, /^vpn_/);
		t.assert_deep_equal(c._state.uci.network[r.body.id].remote, [ 'a.example' ]);
	});
});
