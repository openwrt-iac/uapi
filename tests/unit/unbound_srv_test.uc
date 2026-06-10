let t = require('harness');
let bus = require('bus');
let handler = require('handler');
let srv_resource = loadfile('src/resources/unbound.srv.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

let srv_h = handler.make_singleton(srv_resource, {
	tx: { acquire: function() { return {}; }, release: function() {},
	      reload: function() { return null; },
	      check_services: function() { return null; } },
});

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

t.describe('unbound.srv resource', () => {
	t.it('contract', () => {
		t.assert_equal(srv_resource.package, 'unbound_srv');
		t.assert_equal(srv_resource.type, 'unbound_srv');
		t.assert_deep_equal(srv_resource.reload, ['unbound-uci-ext']);
	});

	t.it('fromUci stamps id, managed, and empty lists by default', () => {
		let r = srv_resource.fromUci({
			'.name': 'main', '.type': 'unbound_srv',
		});
		t.assert_equal(r.id, 'main');
		t.assert_true(r.managed);
		t.assert_false(r.enabled);
		t.assert_equal(r.ip_transparent, null);
		t.assert_deep_equal(r.interface_bind, []);
		t.assert_deep_equal(r.interface_outgoing, []);
		t.assert_deep_equal(r.srv_line, []);
	});

	t.it('fromUci normalises enabled and tri-states ip_transparent', () => {
		let on = srv_resource.fromUci({
			'.name': 'main', '.type': 'unbound_srv',
			enabled: '1', ip_transparent: 'yes',
		});
		t.assert_true(on.enabled);
		t.assert_true(on.ip_transparent);
		let off = srv_resource.fromUci({
			'.name': 'main', '.type': 'unbound_srv',
			enabled: '0', ip_transparent: '0',
		});
		t.assert_false(off.enabled);
		t.assert_false(off.ip_transparent);
		let absent = srv_resource.fromUci({
			'.name': 'main', '.type': 'unbound_srv',
		});
		t.assert_equal(absent.ip_transparent, null);
	});

	t.it('fromUci promotes a scalar list option to a one-element array', () => {
		let r = srv_resource.fromUci({
			'.name': 'main', '.type': 'unbound_srv',
			interface_bind: '127.0.0.1@5353',
		});
		t.assert_deep_equal(r.interface_bind, ['127.0.0.1@5353']);
	});

	t.it('toUci emits booleans as 1/0 and only emits lists when non-empty', () => {
		let full = srv_resource.toUci({
			enabled: true, ip_transparent: false,
			interface_bind: ['127.0.0.1@5353'],
			interface_outgoing: [],
			srv_line: ['harden-below-nxdomain: yes'],
		});
		t.assert_equal(full.enabled, '1');
		t.assert_equal(full.ip_transparent, '0');
		t.assert_deep_equal(full.interface_bind, ['127.0.0.1@5353']);
		t.assert_equal(full.interface_outgoing, null);
		t.assert_deep_equal(full.srv_line, ['harden-below-nxdomain: yes']);
	});

	t.it('toUci skips ip_transparent when null', () => {
		let r = srv_resource.toUci({ enabled: true });
		t.assert_equal(r.ip_transparent, null);
	});

	t.it('validate accepts an empty body and well-formed lists', () => {
		t.assert_equal(length(full_validate(srv_resource, {}, null)), 0);
		t.assert_equal(length(full_validate(srv_resource, {
			enabled: true,
			interface_bind: ['127.0.0.1@5353', '::1@5353'],
			srv_line: ['harden-below-nxdomain: yes'],
		}, null)), 0);
	});

	t.it('validate rejects a non-string list entry', () => {
		let errs = full_validate(srv_resource, { srv_line: [42] }, null);
		let e = filter(errs, function(x) { return x.field == 'srv_line[0]'; });
		t.assert_equal(e[0].code, 'invalid_type');
	});

	t.it('validate rejects a list entry with an embedded newline', () => {
		let errs = full_validate(srv_resource, {
			srv_line: ["harden\nbelow-nxdomain: yes"],
		}, null);
		let e = filter(errs, function(x) { return x.field == 'srv_line[0]'; });
		t.assert_equal(e[0].code, 'invalid_format');
	});

	t.it('validate rejects an empty list entry', () => {
		let errs = full_validate(srv_resource, { srv_line: [''] }, null);
		let e = filter(errs, function(x) { return x.field == 'srv_line[0]'; });
		t.assert_equal(e[0].code, 'invalid_format');
	});

	t.it('validate rejects an over-length list entry', () => {
		// 260 chars, just over the 256-char MAX_LINE_LEN ceiling.
		let big = '';
		for (let i = 0; i < 26; i++) big += '0123456789';
		let errs = full_validate(srv_resource, { srv_line: [big] }, null);
		let e = filter(errs, function(x) { return x.field == 'srv_line[0]'; });
		t.assert_equal(e[0].code, 'invalid_format');
	});
});

t.describe('handler.make_singleton(unbound.srv)', () => {
	function with_srv() {
		return bus.stub({
			uci: {
				unbound_srv: {
					main: { '.type': 'unbound_srv', '.anonymous': false,
					        enabled: '0' },
				},
			},
			ubus: {},
		});
	}

	t.it('get returns the singleton with defaulted fields', () => {
		let c = with_srv();
		let r = srv_h.get(c, ctx());
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'main');
		t.assert_false(r.body.enabled);
		t.assert_deep_equal(r.body.interface_bind, []);
	});

	t.it('get returns 404 if the section is absent', () => {
		let c = bus.stub();
		let r = srv_h.get(c, ctx());
		t.assert_equal(r.status, 404);
	});

	t.it('patch updates only the supplied fields', () => {
		let c = with_srv();
		let r = srv_h.patch(c, ctx(), {
			enabled: true,
			interface_bind: ['127.0.0.1@5353'],
		});
		t.assert_equal(r.status, 200);
		t.assert_true(r.body.enabled);
		t.assert_deep_equal(r.body.interface_bind, ['127.0.0.1@5353']);
	});

	t.it('patch rejects a srv_line entry with newline', () => {
		let c = with_srv();
		let r = srv_h.patch(c, ctx(), { srv_line: ["one\ntwo"] });
		t.assert_equal(r.status, 422);
	});

	// 2.2.0: create_if_missing makes the PATCH idempotent against a missing
	// underlying section (e.g. operator wiped /etc/config/unbound_srv but the
	// init script is still present). Without the flag the resource would 404.
	t.it('patch creates the section if absent (create_if_missing)', () => {
		// No unbound_srv fixture; uci_foreach finds nothing.
		let c = bus.stub({ uci: {}, ubus: {} });
		let r = srv_h.patch(c, ctx(), { enabled: true });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.id, 'main');
		t.assert_true(r.body.enabled);
	});

	t.it('declares create_if_missing in the resource contract', () => {
		t.assert_true(!!srv_resource.create_if_missing);
	});
});
