let t = require('harness');

let netdev = loadfile('src/resources/network.devices.uc')();
let widev = loadfile('src/resources/wireless.devices.uc')();
let wiface = loadfile('src/resources/wireless.interfaces.uc')();

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

	t.it('validate requires ports when type is bridge', () => {
		let errs = netdev.validate({ name: 'br-lan', type: 'bridge' }, null);
		let pe = filter(errs, function(e) { return e.field == "ports"; });
		t.assert_equal(pe[0].code, 'required');
	});

	t.it('validate requires vid when type is 8021q', () => {
		let errs = netdev.validate({ name: 'lan.10', type: '8021q' }, null);
		let ve = filter(errs, function(e) { return e.field == "vid"; });
		t.assert_equal(ve[0].code, 'required');
	});

	t.it('validate rejects unknown type', () => {
		let errs = netdev.validate({ name: 'x', type: 'weirdo' }, null);
		let te = filter(errs, function(e) { return e.field == "type"; });
		t.assert_equal(te[0].code, 'not_in_enum');
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
});
