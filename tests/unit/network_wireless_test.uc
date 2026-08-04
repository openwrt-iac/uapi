let t = require('harness');
let handler = require('handler');
let ubus = require('bus');

let netdev = loadfile('src/resources/network.devices.uc')();
let widev = loadfile('src/resources/wireless.devices.uc')();
let wiface = loadfile('src/resources/wireless.interfaces.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

t.describe('network.devices', () => {
	t.it('contract', () => {
		t.assert_equal(netdev.package, "network");
		t.assert_equal(netdev.type, "device");
	});

	t.it('fromUci surfaces bridge ports as a list', () => {
		let r = netdev.fromUci({ '.name': 'br_lan', '.anonymous': false, '.type': 'device',
		                         name: 'br-lan', type: 'bridge', ports: ['eth0', 'eth1'] });
		t.assert_deep_equal(r.ports, ['eth0', 'eth1']);
	});

	t.it('validate accepts a portless bridge (members added later)', () => {
		let errs = netdev.validate({ name: 'br-tf', type: 'bridge' }, null);
		let pe = filter(errs, function(e) { return e.field == "ports"; });
		t.assert_equal(length(pe), 0);
	});

	t.it('validate accepts a bridge with an explicit empty ports list', () => {
		let errs = netdev.validate({ name: 'br-tf', type: 'bridge', ports: [] }, null);
		let pe = filter(errs, function(e) { return e.field == "ports"; });
		t.assert_equal(length(pe), 0);
	});

	t.it('validate requires vid when type is 8021q', () => {
		let errs = netdev.validate({ name: 'lan.10', type: '8021q' }, null);
		let ve = filter(errs, function(e) { return e.field == "vid"; });
		t.assert_equal(ve[0].code, 'required');
	});

	t.it('validate rejects unknown type', () => {
		let errs = full_validate(netdev, { name: 'x', type: 'weirdo' }, null);
		let te = filter(errs, function(e) { return e.field == "type"; });
		t.assert_equal(te[0].code, 'not_in_enum');
	});

	t.it('validate accepts a type-less options-override section (stock macaddr override)', () => {
		// config_generate emits anonymous `config device` sections with only
		// name + macaddr on some targets; requiring type would be stricter
		// than the platform.
		let errs = full_validate(netdev, { name: 'wan', macaddr: '00:11:22:33:44:55' }, null);
		let te = filter(errs, function(e) { return e.field == "type"; });
		t.assert_equal(length(te), 0);
	});
});

t.describe('wireless.devices', () => {
	t.it('contract', () => {
		t.assert_equal(widev.package, "wireless");
		t.assert_equal(widev.type, "wifi-device");
	});

	t.it('validate requires type', () => {
		let errs = widev.validate({}, null);
		let te = filter(errs, function(e) { return e.field == "type"; });
		t.assert_equal(te[0].code, 'required');
	});

	t.it('validate rejects unknown band', () => {
		let errs = widev.validate({ type: 'mac80211', band: 'fictional' }, null);
		let be = filter(errs, function(e) { return e.field == "band"; });
		t.assert_equal(be[0].code, 'not_in_enum');
	});

	t.it('fromUci coerces empty country to null (stock x86 ships country="")', () => {
		let r = widev.fromUci({ '.name': 'radio0', '.anonymous': false, '.type': 'wifi-device',
		                        type: 'mac80211', band: '2g', country: '' });
		t.assert_equal(r.country, null);
	});

	t.it('schema accepts "00" world regulatory domain (stock 6g default)', () => {
		let errs = full_validate(widev, { type: 'mac80211', band: '6g', country: '00' }, null);
		let ce = filter(errs, function(e) { return e.field == "country"; });
		t.assert_equal(length(ce), 0);
	});
});

t.describe('wireless.interfaces', () => {
	t.it('contract', () => {
		t.assert_equal(wiface.package, "wireless");
		t.assert_equal(wiface.type, "wifi-iface");
	});

	t.it('fromUci masks the key but reports has_key', () => {
		let r = wiface.fromUci({ '.name': 'cfg9', '.anonymous': true, '.type': 'wifi-iface',
		                         device: 'radio0', ssid: 'home', encryption: 'psk2', key: 'secretpw' });
		t.assert_equal(r.key, null);
		t.assert_true(r.has_key);
	});

	t.it('toUci writes the key when supplied', () => {
		let u = wiface.toUci({ device: 'radio0', ssid: 'home', encryption: 'psk2', key: 'secretpw' });
		t.assert_equal(u.key, 'secretpw');
	});

	t.it('validate requires device', () => {
		let errs = wiface.validate({}, null);
		let de = filter(errs, function(e) { return e.field == "device"; });
		t.assert_equal(de[0].code, 'required');
	});

	t.it('validate requires key for psk2 encryption', () => {
		let errs = wiface.validate({ device: 'radio0', encryption: 'psk2' }, null);
		let ke = filter(errs, function(e) { return e.field == "key"; });
		t.assert_equal(ke[0].code, 'required');
	});

	t.it('validate accepts open encryption without a key', () => {
		let errs = wiface.validate({ device: 'radio0', ssid: 'open', encryption: 'none' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('validate accepts owe encryption without a key (keyless; stock 6g default)', () => {
		let errs = full_validate(wiface, { device: 'radio0', ssid: 'mesh6', encryption: 'owe' }, null);
		let ke = filter(errs, function(e) { return e.field == "key"; });
		let ee = filter(errs, function(e) { return e.field == "encryption"; });
		t.assert_equal(length(ke), 0);
		t.assert_equal(length(ee), 0);
	});

	// The carry-forward lives in the handler, keyed on writeOnly, so it is
	// asserted through a real PATCH rather than against a resource hook.
	function wiface_handler() {
		return handler.make(wiface, {
			tx: {
				acquire: function() { return {}; }, release: function() {},
				reload: function() { return null; }, check_services: function() { return null; },
			},
		});
	}
	function seeded_wiface() {
		return ubus.stub({ uci: { wireless: {
			w1: { '.type': 'wifi-iface', '.anonymous': false,
			      device: 'radio0', ssid: 'home', encryption: 'psk2', key: 'secretpw' },
		} } });
	}

	t.it('PATCH that omits the masked key carries the stored one forward', () => {
		let c = seeded_wiface();
		let r = wiface_handler().patch(c, { request_id: "01hx0000000000000000000000" },
		                               'w1', { ssid: 'newssid' });
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.wireless.w1.ssid, 'newssid');
		t.assert_equal(c._state.uci.wireless.w1.key, 'secretpw');
	});

	t.it('PATCH that supplies a key overrides the stored one', () => {
		let c = seeded_wiface();
		let r = wiface_handler().patch(c, { request_id: "01hx0000000000000000000000" },
		                               'w1', { key: 'new' });
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.wireless.w1.key, 'new');
	});
});

// has_key was set only when a key existed, so the member was absent rather than false
// while the published schema declares a non-nullable boolean: a keyless section violated
// the spec the server ships. An empty key also reported true, claiming a key that is not
// there.
t.describe('wireless.interfaces has_key is always present and honest', () => {
	let wiface = loadfile('src/resources/wireless.interfaces.uc')();
	function has_key_of(key) {
		let s = { '.name': 'w1', '.anonymous': false, device: 'radio0', ssid: 'x' };
		if (key != null) s.key = key;
		return wiface.fromUci(s, null).has_key;
	}

	t.it('reports false rather than absent when no key is set', () => {
		t.assert_equal(has_key_of(null), false);
	});

	// uci does not store an empty option value, so this is unreachable through uci
	// (verified on a device, by `uci set key=""` and by hand-editing the config file:
	// the section arrives with no key member at all). Kept because every sibling flag
	// spells the check this way, and a reader comparing the five should not find one
	// subtly different.
	t.it('treats an empty key as no key', () => {
		t.assert_equal(has_key_of(""), false);
	});

	t.it('still reports true for a real key', () => {
		t.assert_equal(has_key_of("correcthorse"), true);
	});

	// The spec promises a boolean, so the read must satisfy its own published schema.
	t.it('satisfies the published non-nullable boolean schema', () => {
		let handler = require('handler');
		for (let k in [null, "", "pw"]) {
			let s = { '.name': 'w1', '.anonymous': false, device: 'radio0', ssid: 'x' };
			if (k != null) s.key = k;
			let view = wiface.fromUci(s, null);
			t.assert_equal(type(view.has_key), "bool");
			t.assert_equal(length(handler.check_schema_types(wiface.schema_properties,
			                                                 { has_key: view.has_key })), 0);
		}
	});
});
