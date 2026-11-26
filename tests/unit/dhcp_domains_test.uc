let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let domains = loadfile('src/resources/dhcp.domains.uc')();

let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null };
let h = handler.make(domains, { tx });
let ctx = { request_id: "01hx0000000000000000000000" };

function box(extra) {
	let dhcp = { main: { '.type': 'dnsmasq', '.anonymous': false } };
	for (let k, v in extra ?? {}) dhcp[k] = v;
	return ubus.stub({ uci: { dhcp } });
}
function fields(errs) { return map(errs, (e) => e.field + ":" + e.code); }

t.describe('dhcp.domains contract', () => {
	t.it('reloads dnsmasq and unbound, which read domain sections, and not odhcpd', () => {
		t.assert_equal(domains.package, "dhcp");
		t.assert_equal(domains.type, "domain");
		t.assert_equal(domains.reload, null);
		t.assert_deep_equal(domains.reload_if_running, ["dnsmasq", "unbound"]);
	});
});

t.describe('dhcp.domains read and write', () => {
	t.it('reads a LuCI section as unmanaged and an absent option as null', () => {
		let r = domains.fromUci({ '.name': 'cfg0bf00b', '.anonymous': true, '.type': 'domain', name: 'nas' });
		t.assert_false(r.managed);
		t.assert_equal(r.name, 'nas');
		t.assert_equal(r.ip, null);
		t.assert_equal(r.instance, null);
	});

	t.it('writes only the fields that the request holds', () => {
		t.assert_deep_equal(domains.toUci({ name: 'nas', ip: '192.168.1.10', instance: null }),
		                    { name: 'nas', ip: '192.168.1.10' });
	});

	t.it('creates a section that a PUT of its read leaves as it is', () => {
		let c = box();
		let r = h.create(c, ctx, { id: 'nas', name: 'nas.lan', ip: 'fd00::10', instance: 'main' });
		t.assert_equal(r.status, 200);
		let u = c._state.uci.dhcp.nas;
		t.assert_equal(u['.type'], 'domain');
		t.assert_equal(u.name, 'nas.lan');
		t.assert_equal(u.ip, 'fd00::10');
		t.assert_equal(u.instance, 'main');
		let body = h.get_one(c, ctx, 'nas').body;
		delete body.runtime;
		t.assert_equal(h.replace(c, ctx, 'nas', body).status, 200);
		t.assert_deep_equal(c._state.uci.dhcp.nas, u);
	});
});

t.describe('dhcp.domains validate', () => {
	t.it('requires name and ip, as dnsmasq.init skips a domain without either', () => {
		t.assert_deep_equal(fields(domains.validate({}, null)), [ "name:required", "ip:required" ]);
		t.assert_deep_equal(fields(domains.validate({ name: '', ip: '' }, null)), [ "name:required", "ip:required" ]);
	});

	t.it('refuses an ip that is not one address, as dnsmasq.init writes it into the hosts line as it is', () => {
		for (let ip in [ '192.168.1.10/24', '192.168.1.10 192.168.1.11', 'nas', '192.168.1.256' ])
			t.assert_deep_equal(fields(domains.validate({ name: 'nas', ip }, null)), [ "ip:invalid_format" ], ip);
	});

	t.it('cross-refs instance against dnsmasq sections', () => {
		let c = box({ lan: { '.type': 'dhcp', '.anonymous': false, interface: 'lan' } });
		t.assert_equal(length(domains.validate({ name: 'nas', ip: '10.0.0.1', instance: 'main' }, c)), 0);
		t.assert_deep_equal(fields(domains.validate({ name: 'nas', ip: '10.0.0.1', instance: 'lan' }, c)),
		                    [ "instance:conflict" ]);
	});
});

t.describe('dhcp/domains name', () => {
	t.it('takes the names that LuCI\'s hostname datatype takes', () => {
		for (let name in [ 'nas', 'nas.lan', 'nas.lan.', '_dns', 'a', 'x-1.example.com' ]) {
			let r = h.create(box(), ctx, { id: 'd', name, ip: '10.0.0.1' });
			t.assert_equal(r.status, 200, name);
		}
	});

	t.it('refuses on a write what LuCI refuses', () => {
		for (let name in [ 'nas lan', 'nas,lan', '-nas', 'nas-', 'nas..', 'nas#x' ]) {
			let r = h.create(box(), ctx, { id: 'd', name, ip: '10.0.0.1' });
			t.assert_equal(r.status, 422, name);
			t.assert_equal(r.body.errors[0].field, 'name', name);
		}
	});

	t.it('keeps a stored single word that LuCI would refuse, and takes a write of another field', () => {
		let c = box({ d: { '.type': 'domain', '.anonymous': false, name: 'nas-', ip: '10.0.0.1' } });
		t.assert_equal(h.patch(c, ctx, 'd', { ip: '10.0.0.2' }).status, 200);
		t.assert_equal(c._state.uci.dhcp.d.name, 'nas-');
	});

	t.it('blocks a write of a section whose stored name holds a space, which dnsmasq and unbound read differently', () => {
		let c = box({ d: { '.type': 'domain', '.anonymous': false, name: 'nas nas.lan', ip: '10.0.0.1' } });
		let r = h.patch(c, ctx, 'd', { ip: '10.0.0.2' });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, 'name');
		t.assert_equal(h.patch(c, ctx, 'd', { name: 'nas', ip: '10.0.0.2' }).status, 200);
	});
});
