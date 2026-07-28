let t = require('harness');
let handler = require('handler');
let ubus = require('bus');

let instances = loadfile('src/resources/openvpn.instances.uc')();

function full_validate(r, body) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body)) push(out, e);
	return out;
}

t.describe('openvpn.instances contract', () => {
	t.it('declares package + reload service', () => {
		t.assert_equal(instances.package, "openvpn");
		t.assert_equal(instances.type, "openvpn");
		t.assert_deep_equal(instances.reload, ["openvpn"]);
	});

	t.it('fromUci masks key/tls_auth/pkcs12 and surfaces has_<field>', () => {
		let r = instances.fromUci({
			'.name': 'srv', '.anonymous': false,
			key: '/etc/openvpn/srv.key',
			tls_auth: '/etc/openvpn/ta.key',
			pkcs12: '/etc/openvpn/srv.p12',
		});
		t.assert_equal(r.has_key, true);
		t.assert_equal(r.has_tls_auth, true);
		t.assert_equal(r.has_pkcs12, true);
		// Sensitive values themselves must NOT be in the response body.
		t.assert_equal(r.key, null);
		t.assert_equal(r.tls_auth, null);
		t.assert_equal(r.pkcs12, null);
	});

	t.it('toUci passes through ca/cert/dh paths and key when set', () => {
		let u = instances.toUci({
			ca: '/etc/openvpn/ca.pem',
			cert: '/etc/openvpn/srv.pem',
			dh: '/etc/openvpn/dh.pem',
			key: '/etc/openvpn/srv.key',
		});
		t.assert_equal(u.ca, '/etc/openvpn/ca.pem');
		t.assert_equal(u.key, '/etc/openvpn/srv.key');
	});

	t.it('validate rejects shell-meta and relative paths', () => {
		let errs = instances.validate({ ca: '$(reboot)' });
		t.assert_true(length(filter(errs, e => e.field == "ca" && e.code == "invalid_format")) > 0);
		errs = instances.validate({ key: 'etc/openvpn/relative.key' });
		t.assert_true(length(filter(errs, e => e.field == "key")) > 0);
	});

	t.it('validate accepts well-shaped absolute paths', () => {
		let errs = instances.validate({
			ca:   '/etc/openvpn/ca.pem',
			cert: '/etc/openvpn/srv.pem',
			key:  '/etc/openvpn/srv.key',
			dh:   '/etc/openvpn/dh.pem',
		});
		t.assert_equal(length(errs), 0);
	});

	// The carry-forward lives in the handler, keyed on writeOnly, so these go
	// through real writes. openvpn is the resource with three masked fields at
	// once, which is what makes it worth exercising separately.
	function ovpn_handler() {
		return handler.make(instances, {
			tx: {
				acquire: function() { return {}; }, release: function() {},
				reload: function() { return null; }, check_services: function() { return null; },
			},
		});
	}
	function seeded_ovpn() {
		return ubus.stub({ uci: { openvpn: {
			srv: { '.type': 'openvpn', '.anonymous': false, enabled: '1',
			       key: '/etc/openvpn/old.key', tls_auth: '/etc/openvpn/old.ta',
			       pkcs12: '/etc/openvpn/old.p12' },
		} } });
	}

	t.it('PATCH that omits the masked secrets carries all three forward', () => {
		let c = seeded_ovpn();
		let r = ovpn_handler().patch(c, { request_id: "01hx0000000000000000000000" },
		                             'srv', { verb: 4 });
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.openvpn.srv.key, '/etc/openvpn/old.key');
		t.assert_equal(c._state.uci.openvpn.srv.tls_auth, '/etc/openvpn/old.ta');
		t.assert_equal(c._state.uci.openvpn.srv.pkcs12, '/etc/openvpn/old.p12');
	});

	t.it('PUT of the masked read view keeps all three rather than erasing them', () => {
		let c = seeded_ovpn();
		let r = ovpn_handler().replace(c, { request_id: "01hx0000000000000000000000" },
		                               'srv', { enabled: true, verb: 4 });
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.openvpn.srv.key, '/etc/openvpn/old.key');
		t.assert_equal(c._state.uci.openvpn.srv.tls_auth, '/etc/openvpn/old.ta');
		t.assert_equal(c._state.uci.openvpn.srv.pkcs12, '/etc/openvpn/old.p12');
	});

	t.it('a supplied secret still rotates', () => {
		let c = seeded_ovpn();
		let r = ovpn_handler().patch(c, { request_id: "01hx0000000000000000000000" },
		                             'srv', { key: '/etc/openvpn/new.key' });
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.openvpn.srv.key, '/etc/openvpn/new.key');
	});

	// These enums reached the spec as the string "NaN", because ucode's `+` on
	// two arrays coerces rather than concatenating. check_schema_types skips a
	// non-array enum, so neither field was validated at all. Fixing the
	// expression made the enum live, which is only safe if it lists everything
	// openvpn accepts: the tcp-client and tcp-server spellings are the ones
	// luci-app-openvpn writes, and omitting them would reject working config.
	t.it('accepts every proto spelling openvpn takes, including the LuCI ones', () => {
		for (let p in ['udp', 'tcp', 'tcp-client', 'tcp-server',
		               'udp4', 'tcp4', 'tcp4-client', 'tcp4-server',
		               'udp6', 'tcp6', 'tcp6-client', 'tcp6-server']) {
			let errs = full_validate(instances, { proto: p });
			t.assert_equal(length(filter(errs, function(e) { return e.field == "proto"; })), 0);
		}
	});

	t.it('still rejects a proto openvpn does not take', () => {
		for (let p in ['sctp', 'bogus', 'tcp-peer'])
			t.assert_equal(filter(full_validate(instances, { proto: p }),
			                      function(e) { return e.field == "proto"; })[0].code, "not_in_enum");
	});

	t.it('constrains dev_type to tun or tap', () => {
		for (let d in ['tun', 'tap'])
			t.assert_equal(length(filter(full_validate(instances, { dev_type: d }),
			                             function(e) { return e.field == "dev_type"; })), 0);
		t.assert_equal(filter(full_validate(instances, { dev_type: 'tap0' }),
		                      function(e) { return e.field == "dev_type"; })[0].code, "not_in_enum");
	});

	t.it('schema enforces port range', () => {
		let errs = full_validate(instances, { port: 99999 });
		t.assert_true(length(filter(errs, e => e.field == "port")) > 0);
	});
});
