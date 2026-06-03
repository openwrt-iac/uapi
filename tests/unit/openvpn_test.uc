let t = require('harness');
let handler = require('handler');

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

	t.it('merge_for_patch carries forward key when PATCH omits it', () => {
		let existing_section = {
			'.name': 'srv', '.type': 'openvpn',
			key: '/etc/openvpn/old.key',
			tls_auth: '/etc/openvpn/old.ta',
		};
		let existing_view = instances.fromUci(existing_section);
		// PATCH only changes verb; key/tls_auth not in body.
		let merged = instances.merge_for_patch(existing_section, existing_view, { verb: 4 });
		t.assert_equal(merged.key, '/etc/openvpn/old.key');
		t.assert_equal(merged.tls_auth, '/etc/openvpn/old.ta');
		t.assert_equal(merged.verb, 4);
	});

	t.it('merge_for_patch lets PATCH rotate a key explicitly', () => {
		let existing_section = { '.name': 'srv', '.type': 'openvpn', key: '/etc/openvpn/old.key' };
		let existing_view = instances.fromUci(existing_section);
		let merged = instances.merge_for_patch(existing_section, existing_view,
		                                       { key: '/etc/openvpn/new.key' });
		t.assert_equal(merged.key, '/etc/openvpn/new.key');
	});

	t.it('schema enforces port range', () => {
		let errs = full_validate(instances, { port: 99999 });
		t.assert_true(length(filter(errs, e => e.field == "port")) > 0);
	});
});
