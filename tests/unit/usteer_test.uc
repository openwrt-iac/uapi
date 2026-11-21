let t = require('harness');
let handler = require('handler');

let config = loadfile('src/resources/usteer.config.uc')();

function full_validate(r, body) {
	let out = [];
	for (let e in handler.check_schema_types(handler.request_properties(r.schema_properties), body)) push(out, e);
	for (let e in r.validate(body)) push(out, e);
	return out;
}

t.describe('usteer.config contract', () => {
	t.it('declares package + reload service', () => {
		t.assert_equal(config.package, "usteer");
		t.assert_equal(config.type, "usteer");
		t.assert_deep_equal(config.reload, ["usteer"]);
	});

	t.it('fromUci normalises uci booleans and surfaces ssid_list as an array', () => {
		let r = config.fromUci({ '.name': 'usteer',
			enabled: '1', assoc_steering: '0', ipv6: 'off',
			ssid_list: ['guest', 'corp'] });
		t.assert_true(r.enabled);
		t.assert_false(r.assoc_steering);
		t.assert_false(r.ipv6);
		t.assert_deep_equal(r.ssid_list, ['guest', 'corp']);
	});

	t.it('toUci writes integers as strings and lists as lists', () => {
		let u = config.toUci({ enabled: true, min_snr: -75, ssid_list: ['guest'] });
		t.assert_equal(u.enabled, "1");
		t.assert_equal(u.min_snr, "-75");
		t.assert_deep_equal(u.ssid_list, ['guest']);
	});

	// usteerd reads any level, and LuCI offers 0 to 5.
	t.it('a request takes debug_level 0 to 5, and a stored higher level is no error', () => {
		t.assert_deep_equal(full_validate(config, { debug_level: 5 }), []);
		t.assert_deep_equal(map(full_validate(config, { debug_level: 9 }), (e) => e.code), [ 'out_of_range' ]);
		t.assert_deep_equal(handler.check_schema_types(config.schema_properties, { debug_level: 9 }), []);
	});

	t.it('schema accepts negative dBm values for signal thresholds', () => {
		// min_snr / roam_trigger_snr are dBm and naturally negative; schema
		// must not floor them at 0.
		let errs = full_validate(config, { min_snr: -75, roam_trigger_snr: -72 });
		t.assert_equal(length(errs), 0);
	});

	// usteer's init compares `enabled` numerically rather than parsing a bool, so the
	// word spellings a bool helper accepts leave the daemon down. Reading them as true
	// reported a running usteer that was not running.
	t.it('enabled follows the init\'s numeric comparison, not a bool parse', () => {
		let sec = t => ({ '.name': 'cfg', enabled: t });
		t.assert_true(config.fromUci({ '.name': 'cfg' }).enabled);
		t.assert_true(config.fromUci(sec('1')).enabled);
		t.assert_true(config.fromUci(sec('2')).enabled);
		t.assert_false(config.fromUci(sec('0')).enabled);
		for (let word in ['true', 'on', 'yes'])
			t.assert_false(config.fromUci(sec(word)).enabled);
	});

	});
