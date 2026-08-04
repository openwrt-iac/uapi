let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let fwd = loadfile('src/resources/firewall.forwardings.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

t.describe('firewall.forwardings contract', () => {
	t.it('declares package, type, and reload services', () => {
		t.assert_equal(fwd.package, "firewall");
		t.assert_equal(fwd.type, "forwarding");
		t.assert_deep_equal(fwd.reload, ["firewall"]);
	});
});

t.describe('firewall.forwardings.fromUci', () => {
	t.it('renders a named section as managed=true', () => {
		let r = fwd.fromUci({
			'.name': 'f_01hx', '.anonymous': false, '.type': 'forwarding',
			src: 'lan', dest: 'wan',
		});
		t.assert_equal(r.id, 'f_01hx');
		t.assert_true(r.managed);
		t.assert_equal(r.src, 'lan');
		t.assert_equal(r.dest, 'wan');
		t.assert_equal(r.family, 'any');
		t.assert_true(r.enabled);
	});

	t.it('renders an anonymous section as managed=false', () => {
		let r = fwd.fromUci({
			'.name': 'cfg0123', '.anonymous': true, '.type': 'forwarding',
			src: 'lan', dest: 'wan',
		});
		t.assert_false(r.managed);
	});

	t.it('normalizes enabled to a JSON boolean', () => {
		let on = fwd.fromUci({ '.name': 'f1', '.type': 'forwarding',
			src: 'lan', dest: 'wan', enabled: '1' });
		let off = fwd.fromUci({ '.name': 'f2', '.type': 'forwarding',
			src: 'lan', dest: 'wan', enabled: '0' });
		let dflt = fwd.fromUci({ '.name': 'f3', '.type': 'forwarding',
			src: 'lan', dest: 'wan' });
		t.assert_true(on.enabled);
		t.assert_false(off.enabled);
		t.assert_true(dflt.enabled);
	});
});

t.describe('firewall.forwardings.toUci', () => {
	t.it('converts curated JSON to uci option dict', () => {
		let u = fwd.toUci({ src: 'lan', dest: 'wan', family: 'ipv4', enabled: true });
		t.assert_equal(u.src, 'lan');
		t.assert_equal(u.dest, 'wan');
		t.assert_equal(u.family, 'ipv4');
		t.assert_equal(u.enabled, '1');
	});

	t.it('omits family when value is any', () => {
		let u = fwd.toUci({ src: 'lan', dest: 'wan', family: 'any' });
		t.assert_equal(u.family, null);
	});

	t.it('writes 0 for false enabled', () => {
		let u = fwd.toUci({ src: 'lan', dest: 'wan', enabled: false });
		t.assert_equal(u.enabled, '0');
	});
});

t.describe('firewall.forwardings.validate', () => {

	t.it('rejects missing src and dest together (all errors at once)', () => {
		let errs = fwd.validate({}, null);
		let src_errs  = filter(errs, function(e) { return e.field == "src"; });
		let dest_errs = filter(errs, function(e) { return e.field == "dest"; });
		t.assert_equal(src_errs[0].code, "required");
		t.assert_equal(dest_errs[0].code, "required");
	});

	t.it('rejects bad family enum', () => {
		let errs = full_validate(fwd, { src: 'lan', dest: 'wan', family: 'bogus' }, null);
		let fe = filter(errs, function(e) { return e.field == "family"; });
		t.assert_equal(fe[0].code, "not_in_enum");
	});

	t.it('reports conflict when src zone does not exist', () => {
		let conn = ubus.stub({
			uci: { firewall: { z_lan: { '.type': 'zone', name: 'lan' } } }
		});
		let errs = fwd.validate({ src: 'wan', dest: 'lan' }, conn);
		let se = filter(errs, function(e) { return e.field == "src" && e.code == "conflict"; });
		t.assert_equal(length(se), 1);
	});

	t.it('reports conflict when dest zone does not exist', () => {
		let conn = ubus.stub({
			uci: { firewall: { z_lan: { '.type': 'zone', name: 'lan' } } }
		});
		let errs = fwd.validate({ src: 'lan', dest: 'dmz' }, conn);
		let de = filter(errs, function(e) { return e.field == "dest" && e.code == "conflict"; });
		t.assert_equal(length(de), 1);
	});

	t.it('accepts a forwarding between two existing zones', () => {
		let conn = ubus.stub({
			uci: { firewall: {
				z_lan: { '.type': 'zone', name: 'lan' },
				z_wan: { '.type': 'zone', name: 'wan' },
			} }
		});
		let errs = fwd.validate({ src: 'lan', dest: 'wan' }, conn);
		t.assert_equal(length(errs), 0);
	});
});
