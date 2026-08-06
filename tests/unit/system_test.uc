let t = require('harness');
let bus = require('bus');
let handler = require('handler');
let system_resource = loadfile('src/resources/system.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}
let system_h = handler.make_singleton(system_resource, {
	tx: { acquire: function() { return {}; }, release: function() {},
	      reload: function() { return null; },
	      check_services: function() { return null; } },
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

	t.it('fromUci stamps id and managed at the top level', () => {
		let r = system_resource.fromUci({
			'.name': 'cfg01', '.anonymous': true, '.type': 'system', hostname: 'OpenWrt',
		});
		t.assert_equal(r.id, 'cfg01');
		t.assert_true(r.managed);
	});

	t.it('fromUci normalizes log_remote to a JSON boolean', () => {
		let on = system_resource.fromUci({
			'.name': 'cfg01', '.type': 'system', log_remote: '1',
		});
		t.assert_true(on.log_remote);
		let off = system_resource.fromUci({
			'.name': 'cfg01', '.type': 'system', log_remote: '0',
		});
		t.assert_false(off.log_remote);
	});

	t.it('toUci writes log_remote as a uci 1/0 string', () => {
		t.assert_equal(system_resource.toUci({ log_remote: true }).log_remote, '1');
		t.assert_equal(system_resource.toUci({ log_remote: false }).log_remote, '0');
	});

	// urandom_seed is the path the seed is saved to, not a flag. It was typed boolean,
	// so `option urandom_seed '/mnt/seed'` read back false and any write replaced the
	// path with "0", turning the feature off and losing where the operator put it.
	t.it('urandom_seed carries the operator path through a round trip', () => {
		let v = system_resource.fromUci({
			'.name': 'cfg01', '.type': 'system', urandom_seed: '/mnt/persist/seed',
		});
		t.assert_equal(v.urandom_seed, '/mnt/persist/seed');
		t.assert_equal(system_resource.toUci(v).urandom_seed, '/mnt/persist/seed');
	});
	t.it('an absent urandom_seed reads null and writes nothing', () => {
		let v = system_resource.fromUci({ '.name': 'cfg01', '.type': 'system' });
		t.assert_equal(v.urandom_seed, null);
		t.assert_true(!exists(system_resource.toUci(v), 'urandom_seed'));
	});

	t.it('declares system and log reload services', () => {
		t.assert_deep_equal(system_resource.reload, ['system', 'log']);
	});

	t.it('validate accepts simple hostnames', () => {
		t.assert_equal(length(system_resource.validate({ hostname: 'router-1' }, null)), 0);
		t.assert_equal(length(system_resource.validate({ hostname: 'router.lan' }, null)), 0);
	});

	t.it('validate rejects hostnames with spaces', () => {
		let errs = full_validate(system_resource, { hostname: 'router 1' }, null);
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
