let t = require('harness');
let bus = require('bus');
let handler = require('handler');
let system_resource = loadfile('src/resources/system.uc')();
let system_h = handler.make_singleton(system_resource, {
	tx: { acquire: function() { return {}; }, release: function() {} },
});

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

t.describe('system resource', () => {
	t.it('contract', () => {
		t.assert_equal(system_resource.package, "system");
		t.assert_equal(system_resource.type, "system");
	});

	t.it('fromUci surfaces hostname and timezone', () => {
		let r = system_resource.fromUci({
			'.name': 'cfg01', '.anonymous': true, '.type': 'system',
			hostname: 'OpenWrt', timezone: 'UTC',
		});
		t.assert_equal(r.hostname, 'OpenWrt');
		t.assert_equal(r.timezone, 'UTC');
	});

	t.it('validate accepts simple hostnames', () => {
		t.assert_equal(length(system_resource.validate({ hostname: 'router-1' }, null)), 0);
		t.assert_equal(length(system_resource.validate({ hostname: 'router.lan' }, null)), 0);
	});

	t.it('validate rejects hostnames with spaces', () => {
		let errs = system_resource.validate({ hostname: 'router 1' }, null);
		let he = filter(errs, function(e) { return e.field == "hostname"; });
		t.assert_equal(he[0].code, 'invalid_format');
	});
});

t.describe('handler.make_singleton', () => {
	function with_system() {
		return bus.stub({
			uci: {
				system: {
					cfg01: { '.type': 'system', '.anonymous': true,
					         hostname: 'OpenWrt', timezone: 'UTC' },
				},
			},
			ubus: {},
		});
	}

	t.it('get returns the singleton', () => {
		let c = with_system();
		let r = system_h.get(c, ctx());
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.hostname, 'OpenWrt');
	});

	t.it('get returns 404 if missing', () => {
		let c = bus.stub();
		let r = system_h.get(c, ctx());
		t.assert_equal(r.status, 404);
	});

	t.it('patch updates only the supplied field', () => {
		let c = with_system();
		let r = system_h.patch(c, ctx(), { hostname: 'router1' });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.hostname, 'router1');
		t.assert_equal(r.body.timezone, 'UTC');
	});

	t.it('patch rejects invalid hostname', () => {
		let c = with_system();
		let r = system_h.patch(c, ctx(), { hostname: 'not allowed' });
		t.assert_equal(r.status, 422);
	});
});
