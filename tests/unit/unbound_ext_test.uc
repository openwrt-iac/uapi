let t = require('harness');
let bus = require('bus');
let handler = require('handler');
let ext_resource = loadfile('src/resources/unbound.ext.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

let ext_h = handler.make_singleton(ext_resource, {
	tx: { acquire: function() { return {}; }, release: function() {},
	      reload: function() { return null; },
	      check_services: function() { return null; } },
});

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

t.describe('unbound.ext resource', () => {
	t.it('contract', () => {
		t.assert_equal(ext_resource.package, 'unbound_ext');
		t.assert_equal(ext_resource.type, 'unbound_ext');
		t.assert_deep_equal(ext_resource.reload, ['unbound-uci-ext']);
	});

	t.it('fromUci stamps id, managed, defaults enabled false, ext_line []', () => {
		let r = ext_resource.fromUci({
			'.name': 'main', '.type': 'unbound_ext',
		});
		t.assert_equal(r.id, 'main');
		t.assert_true(r.managed);
		t.assert_false(r.enabled);
		t.assert_deep_equal(r.ext_line, []);
	});

	t.it('fromUci promotes a scalar ext_line option to a one-element array', () => {
		let r = ext_resource.fromUci({
			'.name': 'main', '.type': 'unbound_ext',
			ext_line: 'forward-zone:',
		});
		t.assert_deep_equal(r.ext_line, ['forward-zone:']);
	});

	t.it('toUci emits enabled as 1/0 and only emits ext_line when non-empty', () => {
		let on = ext_resource.toUci({ enabled: true, ext_line: ['forward-zone:'] });
		t.assert_equal(on.enabled, '1');
		t.assert_deep_equal(on.ext_line, ['forward-zone:']);
		let off = ext_resource.toUci({ enabled: false, ext_line: [] });
		t.assert_equal(off.enabled, '0');
		t.assert_equal(off.ext_line, null);
	});

	t.it('validate accepts an empty body and well-formed ext_line', () => {
		t.assert_equal(length(full_validate(ext_resource, {}, null)), 0);
		t.assert_equal(length(full_validate(ext_resource, {
			enabled: true,
			ext_line: ['forward-zone:', '  name: "example.org"', '  forward-addr: 1.1.1.1'],
		}, null)), 0);
	});

	t.it('validate rejects an ext_line entry with embedded newline', () => {
		let errs = full_validate(ext_resource, { ext_line: ["foo\nbar"] }, null);
		let e = filter(errs, function(x) { return x.field == 'ext_line[0]'; });
		t.assert_equal(e[0].code, 'invalid_format');
	});

	t.it('validate rejects an empty ext_line entry', () => {
		let errs = full_validate(ext_resource, { ext_line: [''] }, null);
		let e = filter(errs, function(x) { return x.field == 'ext_line[0]'; });
		t.assert_equal(e[0].code, 'invalid_format');
	});

	t.it('validate rejects a non-string ext_line entry', () => {
		let errs = full_validate(ext_resource, { ext_line: [42] }, null);
		let e = filter(errs, function(x) { return x.field == 'ext_line[0]'; });
		t.assert_equal(e[0].code, 'invalid_type');
	});
});

t.describe('handler.make_singleton(unbound.ext)', () => {
	function with_ext() {
		return bus.stub({
			uci: {
				unbound_ext: {
					main: { '.type': 'unbound_ext', '.anonymous': false,
					        enabled: '0' },
				},
			},
			ubus: {},
		});
	}

	t.it('get returns the singleton with empty defaults', () => {
		let c = with_ext();
		let r = ext_h.get(c, ctx());
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'main');
		t.assert_false(r.body.enabled);
		t.assert_deep_equal(r.body.ext_line, []);
	});

	t.it('patch updates enabled and ext_line', () => {
		let c = with_ext();
		let r = ext_h.patch(c, ctx(), {
			enabled: true,
			ext_line: ['forward-zone:', '  name: "example.org"'],
		});
		t.assert_equal(r.status, 200);
		t.assert_true(r.body.enabled);
		t.assert_deep_equal(r.body.ext_line, ['forward-zone:', '  name: "example.org"']);
	});

	t.it('patch rejects ext_line entry with newline', () => {
		let c = with_ext();
		let r = ext_h.patch(c, ctx(), { ext_line: ["one\ntwo"] });
		t.assert_equal(r.status, 422);
	});

	// 2.2.0: create_if_missing parity with unbound/srv.
	t.it('patch creates the section if absent (create_if_missing)', () => {
		let c = bus.stub({ uci: {}, ubus: {} });
		let r = ext_h.patch(c, ctx(), { enabled: true });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'main');
		t.assert_true(r.body.enabled);
	});

	t.it('declares create_if_missing in the resource contract', () => {
		t.assert_true(!!ext_resource.create_if_missing);
	});
});
