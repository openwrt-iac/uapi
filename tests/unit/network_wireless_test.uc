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

	t.it('fromUci reads scalar ports as words and a hex mtu, as netifd does', () => {
		let r = netdev.fromUci({ '.name': 'br_x', '.anonymous': false, '.type': 'device',
		                         name: 'br-x', type: 'bridge', ports: 'eth0 eth1', mtu: '0x5dc' });
		t.assert_deep_equal(r.ports, ['eth0', 'eth1']);
		t.assert_equal(r.mtu, 1500);
	});

	t.it('validate refuses an mtu below 68, which netifd ignores, and reads a stored one as it is', () => {
		let mtu_codes = (mtu) => map(filter(netdev.validate({ name: 'br-x', type: 'bridge', mtu }, null),
		                                    (e) => e.field == 'mtu'), (e) => e.code);
		t.assert_deep_equal(mtu_codes(60), [ 'out_of_range' ]);
		t.assert_deep_equal(mtu_codes(68), []);
		t.assert_equal(netdev.fromUci({ '.name': 'br_x', '.anonymous': false, '.type': 'device',
		                                name: 'br-x', type: 'bridge', mtu: '60' }).mtu, 60);
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

t.describe('wireless writes on a router without a radio', () => {
	let tx = {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	};
	let ctx = { request_id: "01hx0000000000000000000000" };
	for (let c in [
		[ widev, { type: "mac80211" } ],
		[ wiface, { device: "radio0", mode: "ap", ssid: "x", network: "lan" } ],
	]) {
		t.it(sprintf("%s: a POST answers 503 config_missing and stores nothing", c[0].type), () => {
			let conn = ubus.stub({ uci: {}, missing_packages: [ "wireless" ] });
			let r = handler.make(c[0], { tx }).create(conn, ctx, c[1]);
			t.assert_equal(r.status, 503);
			t.assert_equal(r.body.code, "config_missing");
			t.assert_true(match(r.body.message, /\/etc\/config\/wireless/) != null);
			t.assert_deep_equal(conn._state.uci_ops, []);
		});
	}
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
		                               'w1', { key: 'newsecret' });
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.wireless.w1.key, 'newsecret');
	});
});

// A PUT deletes every option the resource does not model, so before 3.2.0 a PUT of the read
// deleted the radio's path, which left wifi-scripts without a phy to bring up, and the SSID's
// 802.11r options. The sections are the ones a real access point stores (#238).
t.describe('wireless PUT of the read keeps what LuCI and wifi config store', () => {
	let tx = {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	};
	function seeded() {
		return ubus.stub({ uci: { wireless: {
			radio0: { '.type': 'wifi-device', '.anonymous': false, type: 'mac80211',
			          path: '1e140000.pcie/pci0000:00/0000:00:01.0/0000:02:00.0', channel: '1',
			          band: '2g', htmode: 'HT40', cell_density: '0', legacy_rates: '1' },
			radio1: { '.type': 'wifi-device', '.anonymous': false, type: 'mac80211',
			          macaddr: '02:00:00:00:00:01', band: '5g' },
			default_radio0: { '.type': 'wifi-iface', '.anonymous': false, device: 'radio0',
			                  network: 'lan', mode: 'ap', ssid: 'home', encryption: 'psk2+ccmp',
			                  key: 'correcthorse', ieee80211r: '1', ft_over_ds: '0',
			                  ft_psk_generate_local: '1', mobility_domain: '4f57' },
			ft_kh: { '.type': 'wifi-iface', '.anonymous': false, device: 'radio0',
			          mode: 'ap', ssid: 'corp', encryption: 'psk2', key: 'correcthorse',
			          ieee80211r: '1', ft_psk_generate_local: '0', nasid: 'ap1',
			          reassociation_deadline: '20000', r0_key_lifetime: '10000',
			          r1_key_holder: '02aabbccddee', pmk_r1_push: '1',
			          r0kh: [ 'ff:ff:ff:ff:ff:ff,*,00112233445566778899aabbccddeeff' ],
			          r1kh: [ '00:00:00:00:00:00,00:00:00:00:00:00,00112233445566778899aabbccddeeff' ] },
		} } });
	}
	function put_read(mod, id, change) {
		let c = seeded();
		let h = handler.make(mod, { tx });
		let body = h.get_one(c, { request_id: "01hx0000000000000000000000" }, id).body;
		for (let k in [ 'id', 'managed', 'runtime', 'has_key' ]) delete body[k];
		for (let k, v in change) body[k] = v;
		let r = h.replace(c, { request_id: "01hx0000000000000000000000" }, id, body);
		t.assert_equal(r.status, 200);
		return c._state.uci.wireless[id];
	}

	t.it('a radio bound only by macaddr keeps it', () => {
		t.assert_equal(put_read(widev, 'radio1', { channel: 36 }).macaddr, '02:00:00:00:00:01');
	});

	// Half of the group used to be worse than none: a PUT kept 802.11r on and dropped the key
	// holders, so wifi-scripts derived ones that the other access points do not share.
	t.it('an SSID keeps the whole 802.11r group, the key holder lists included', () => {
		let s = put_read(wiface, 'ft_kh', { ssid: 'corp2' });
		for (let k, v in { nasid: 'ap1', reassociation_deadline: '20000', r0_key_lifetime: '10000',
		                   r1_key_holder: '02aabbccddee', pmk_r1_push: '1' })
			t.assert_equal(s[k], v);
		t.assert_deep_equal(s.r0kh, [ 'ff:ff:ff:ff:ff:ff,*,00112233445566778899aabbccddeeff' ]);
		t.assert_deep_equal(s.r1kh, [ '00:00:00:00:00:00,00:00:00:00:00:00,00112233445566778899aabbccddeeff' ]);
	});

	t.it('a read reports the key holder lists without their keys', () => {
		let body = handler.make(wiface, { tx }).get_one(seeded(), { request_id: "01hx0000000000000000000000" }, 'ft_kh').body;
		t.assert_equal(body.has_r0kh, true);
		t.assert_equal(body.has_r1kh, true);
		t.assert_false(exists(body, 'r0kh') || exists(body, 'r1kh'));
	});

	t.it('a radio keeps path, cell_density and legacy_rates', () => {
		let s = put_read(widev, 'radio0', { channel: 6 });
		t.assert_equal(s.channel, '6');
		t.assert_equal(s.path, '1e140000.pcie/pci0000:00/0000:00:01.0/0000:02:00.0');
		t.assert_equal(s.cell_density, '0');
		t.assert_equal(s.legacy_rates, '1');
	});

	t.it('an SSID keeps a forced cipher and its 802.11r options', () => {
		let s = put_read(wiface, 'default_radio0', { ssid: 'home2' });
		t.assert_equal(s.ssid, 'home2');
		t.assert_equal(s.encryption, 'psk2+ccmp');
		t.assert_equal(s.key, 'correcthorse');
		t.assert_equal(s.ieee80211r, '1');
		t.assert_equal(s.ft_over_ds, '0');
		t.assert_equal(s.ft_psk_generate_local, '1');
		t.assert_equal(s.mobility_domain, '4f57');
	});
});

t.describe('wireless.devices radio binding and rates', () => {
	t.it('fromUci reads phy and radio, as wifi config writes them on a multi-radio phy', () => {
		let r = widev.fromUci({ '.name': 'radio1', '.anonymous': false, '.type': 'wifi-device',
		                        type: 'mac80211', phy: 'mt7996', radio: '1', band: '5g' });
		t.assert_equal(r.phy, 'mt7996');
		t.assert_equal(r.radio, 1);
		t.assert_equal(r.path, null);
	});

	t.it('fromUci reads unset rate options as the wifi-scripts defaults', () => {
		let r = widev.fromUci({ '.name': 'radio0', '.anonymous': false, '.type': 'wifi-device',
		                        type: 'mac80211' });
		t.assert_equal(r.cell_density, 0);
		t.assert_equal(r.legacy_rates, false);
	});

	t.it('schema refuses a cell_density above 3', () => {
		let errs = full_validate(widev, { type: 'mac80211', cell_density: 4 }, null);
		t.assert_deep_equal(map(filter(errs, (e) => e.field == 'cell_density'), (e) => e.code),
		                    [ 'out_of_range' ]);
	});
});

t.describe('wireless.interfaces encryption with a forced cipher', () => {
	t.it('accepts the suffixes LuCI writes and the aes spellings wifi-scripts reads', () => {
		for (let e in [ 'psk2+ccmp', 'psk-mixed+tkip+ccmp', 'sae+gcmp256', 'wpa2+ccmp256', 'psk2+aes' ]) {
			let errs = full_validate(wiface, { device: 'radio0', encryption: e, key: 'correcthorse' }, null);
			t.assert_equal(length(errs), 0);
		}
	});

	t.it('requires a key with a forced cipher, as without one', () => {
		let errs = full_validate(wiface, { device: 'radio0', encryption: 'psk2+ccmp' }, null);
		t.assert_deep_equal(map(filter(errs, (e) => e.field == 'key'), (e) => e.code), [ 'required' ]);
	});

	t.it('refuses a cipher on a mode LuCI offers none for, and an unknown cipher', () => {
		for (let e in [ 'owe+ccmp', 'none+ccmp', 'psk2+ccmp+tkip+aes', 'psk2+des' ]) {
			let errs = full_validate(wiface, { device: 'radio0', encryption: e, key: 'correcthorse' }, null);
			t.assert_deep_equal(uniq(map(filter(errs, (e) => e.field == 'encryption'), (e) => e.code)),
			                    [ 'not_in_enum' ]);
		}
	});
});

t.describe('wireless.interfaces 802.11r', () => {
	t.it('fromUci reads an unset ft_psk_generate_local as null, since its default depends on encryption', () => {
		let r = wiface.fromUci({ '.name': 'w1', '.anonymous': false, device: 'radio0',
		                         encryption: 'psk2', key: 'x', ieee80211r: '1' }, null);
		t.assert_equal(r.ieee80211r, true);
		t.assert_equal(r.ft_over_ds, false);
		t.assert_equal(r.ft_psk_generate_local, null);
		t.assert_equal(r.mobility_domain, null);
	});

	t.it('fromUci reads the booleans as netifd parse_bool does', () => {
		let r = wiface.fromUci({ '.name': 'w1', '.anonymous': false, device: 'radio0',
		                         ieee80211r: 'yes', ft_psk_generate_local: 'on' }, null);
		t.assert_equal(r.ieee80211r, false);
		t.assert_equal(r.ft_psk_generate_local, null);
	});

	t.it('schema refuses a mobility_domain that is not 4 hex digits', () => {
		let errs = full_validate(wiface, { device: 'radio0', mobility_domain: '4f5' }, null);
		t.assert_deep_equal(map(filter(errs, (e) => e.field == 'mobility_domain'), (e) => e.code),
		                    [ 'invalid_format' ]);
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

// wifi-scripts writes these four into hostapd's config without escaping, so a newline in one
// added a hostapd directive, and hostapd refuses its whole config for one bad key holder entry.
t.describe('wireless.interfaces values that reach hostapd as config lines', () => {
	const H32 = '00112233445566778899aabbccddeeff';
	const H64 = H32 + H32;
	function bytes(n) {
		let s = '';
		for (let i = 0; i < n; i++) s += 'a';
		return s;
	}
	function field_errs(body, field) {
		return filter(full_validate(wiface, { device: 'radio0', ...body }, null),
		              (e) => e.field == field);
	}

	t.it('refuses a control character in a key, nasid or key holder entry, in any mode', () => {
		for (let enc in [ 'psk2', 'sae', 'wpa2', 'none' ]) {
			let errs = field_errs({ encryption: enc, key: 'abcdefgh\nssid2="x"' }, 'key');
			t.assert_deep_equal(map(errs, (e) => e.code), [ 'invalid_format' ]);
		}
		t.assert_deep_equal(map(field_errs({ nasid: 'ap1\nssid2="x"' }, 'nasid'), (e) => e.code),
		                    [ 'invalid_format' ]);
		t.assert_deep_equal(map(field_errs({ nasid: 'ap1\t' }, 'nasid'), (e) => e.code),
		                    [ 'invalid_format' ]);
		t.assert_deep_equal(map(field_errs({ r0kh: [ '02:00:00:00:00:01,ap1,' + H64 + '\nssid2="x"' ] }, 'r0kh[0]'),
		                        (e) => e.code), [ 'invalid_format' ]);
	});

	t.it('takes a passphrase of 8 to 63 bytes or a PSK of 64 hex digits, as wifi-scripts does', () => {
		for (let enc in [ 'psk', 'psk2', 'psk-mixed', 'sae', 'sae-mixed', 'psk2+ccmp' ]) {
			for (let k in [ bytes(8), bytes(63), H64, 'café-au-lait' ])
				t.assert_equal(length(field_errs({ encryption: enc, key: k }, 'key')), 0);
			for (let k in [ bytes(7), substr(H64, 1) + 'g', bytes(65) ])
				t.assert_deep_equal(map(field_errs({ encryption: enc, key: k }, 'key'), (e) => e.code),
				                    [ 'invalid_format' ]);
		}
	});

	t.it('leaves the length of a RADIUS secret or a WEP key alone', () => {
		for (let enc in [ 'wpa2', 'wpa3', 'wep', 'owe' ])
			t.assert_equal(length(field_errs({ encryption: enc, key: 'short' }, 'key')), 0);
	});

	t.it('caps nasid at the 48 bytes that hostapd takes for 802.11r', () => {
		t.assert_equal(length(field_errs({ nasid: bytes(48) }, 'nasid')), 0);
		t.assert_deep_equal(map(field_errs({ nasid: bytes(49) }, 'nasid'), (e) => e.code), [ 'out_of_range' ]);
	});

	t.it('takes the key holder entries that hostapd parses, wifi-scripts defaults included', () => {
		for (let e in [ 'ff:ff:ff:ff:ff:ff,*,' + H32, '02:00:00:00:00:01,ap-1.example.com,' + H64,
		                '02:00:00:00:00:01,' + bytes(47) + ',' + H64 ])
			t.assert_equal(length(field_errs({ r0kh: [ e ] }, 'r0kh[0]')), 0);
		for (let e in [ '00:00:00:00:00:00,00:00:00:00:00:00,' + H32,
		                '02:00:00:00:00:01,02:00:00:00:00:02,' + H64 ])
			t.assert_equal(length(field_errs({ r1kh: [ e ] }, 'r1kh[0]')), 0);
	});

	t.it('refuses the key holder entries that hostapd refuses, without naming the entry', () => {
		let cases = [
			[ 'r0kh', '02:00:00:00:00:01,ap1,secret' ],
			[ 'r0kh', '02:00:00:00:00:01,ap1' ],
			[ 'r0kh', '02:00:00:00:00:01,' + bytes(48) + ',' + H64 ],
			[ 'r0kh', '02:00:00:00:00:01,ap 1,' + H64 ],
			[ 'r0kh', '02:00:00:00:00:01,ap,1,' + H64 ],
			[ 'r0kh', '02:00:00:00:00:01,ap1,' + H32 + '0' ],
			[ 'r0kh', '02:00:00:00:00:01,,' + H64 ],
			[ 'r0kh', '0200.0000.0001,ap1,' + H64 ],
			[ 'r0kh', '02:00:00:00:00:01,ap1,' + H64 + H32 ],
			[ 'r1kh', '02:00:00:00:00:01,ap1,' + H64 ],
		];
		let valid = { r0kh: 'ff:ff:ff:ff:ff:ff,*,' + H32, r1kh: '00:00:00:00:00:00,00:00:00:00:00:00,' + H32 };
		for (let c in cases) {
			let errs = filter(full_validate(wiface, { device: 'radio0', [c[0]]: [ valid[c[0]], c[1] ] }, null),
			                  (e) => index(e.field, c[0]) == 0);
			t.assert_deep_equal(map(errs, (e) => [ e.field, e.code ]), [ [ c[0] + '[1]', 'invalid_format' ] ]);
			t.assert_equal(index(errs[0].message, c[1]), -1);
		}
	});

	let tx = {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	};
	function stored(extra) {
		return ubus.stub({ uci: { wireless: {
			w1: { '.type': 'wifi-iface', '.anonymous': false, device: 'radio0', mode: 'ap',
			      ssid: 'home', encryption: 'psk2', key: 'short', ...extra },
		} } });
	}

	t.it('a PATCH with an injected key answers 422 and leaves uci alone', () => {
		let c = stored({ key: 'correcthorse' });
		let r = handler.make(wiface, { tx }).patch(c, { request_id: "01hx0000000000000000000000" },
		                                         'w1', { key: 'abcdefgh\nssid2="x"' });
		t.assert_equal(r.status, 422);
		t.assert_equal(c._state.uci.wireless.w1.key, 'correcthorse');
	});

	// The key and the lists are never read back, so a PUT carries the stored ones. Checking those
	// would refuse every write of a section whose stored value LuCI or a shell wrote.
	t.it('a PUT that omits the key and the key holders keeps stored ones it would refuse', () => {
		let c = stored({ r0kh: [ '02:00:00:00:00:01,ap1,secret' ] });
		let r = handler.make(wiface, { tx }).replace(c, { request_id: "01hx0000000000000000000000" }, 'w1',
		                                           { device: 'radio0', mode: 'ap', ssid: 'home2', encryption: 'psk2' });
		t.assert_equal(r.status, 200);
		t.assert_equal(c._state.uci.wireless.w1.ssid, 'home2');
		t.assert_equal(c._state.uci.wireless.w1.key, 'short');
		t.assert_deep_equal(c._state.uci.wireless.w1.r0kh, [ '02:00:00:00:00:01,ap1,secret' ]);
	});
});
