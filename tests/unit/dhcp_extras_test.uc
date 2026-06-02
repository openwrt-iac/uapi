let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let servers = loadfile('src/resources/dhcp.servers.uc')();
let dnsmasq = loadfile('src/resources/dhcp.dnsmasq.uc')();
let odhcpd = loadfile('src/resources/dhcp.odhcpd.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

t.describe('dhcp.servers contract', () => {
	t.it('declares package, type, reload', () => {
		t.assert_equal(servers.package, "dhcp");
		t.assert_equal(servers.type, "dhcp");
		t.assert_deep_equal(servers.reload, ["dnsmasq"]);
	});
});

t.describe('dhcp.servers.validate', () => {
	t.it('rejects missing interface', () => {
		let errs = servers.validate({ start: 100, limit: 50 }, null);
		t.assert_equal(errs[0].field, "interface");
		t.assert_equal(errs[0].code, "required");
	});
	t.it('rejects bad leasetime', () => {
		let errs = servers.validate({ interface: 'lan', leasetime: 'forever' }, null);
		let le = filter(errs, function(e) { return e.field == "leasetime"; });
		t.assert_equal(le[0].code, "invalid_format");
	});
	t.it('rejects bad ra enum', () => {
		let errs = servers.validate({ interface: 'lan', ra: 'bogus' }, null);
		let re = filter(errs, function(e) { return e.field == "ra"; });
		t.assert_equal(re[0].code, "not_in_enum");
	});
	t.it('reports conflict when interface does not exist', () => {
		let conn = ubus.stub({ uci: { network: {
			lan: { '.type': 'interface' },
		} } });
		let errs = servers.validate({ interface: 'wan' }, conn);
		let ie = filter(errs, function(e) { return e.field == "interface"; });
		t.assert_equal(ie[0].code, "conflict");
	});
});

t.describe('dhcp.dnsmasq contract', () => {
	t.it('declares package, type, reload', () => {
		t.assert_equal(dnsmasq.package, "dhcp");
		t.assert_equal(dnsmasq.type, "dnsmasq");
		t.assert_deep_equal(dnsmasq.reload, ["dnsmasq"]);
	});
});

t.describe('dhcp.dnsmasq.fromUci', () => {
	t.it('normalizes booleans + surfaces server/address lists', () => {
		let r = dnsmasq.fromUci({
			'.name': 'cfg01', '.type': 'dnsmasq',
			noresolv: '1', server: ['127.0.0.1#5353'],
			address: ['/int.example/192.168.1.1'],
		});
		t.assert_true(r.noresolv);
		t.assert_deep_equal(r.server, ['127.0.0.1#5353']);
		t.assert_deep_equal(r.address, ['/int.example/192.168.1.1']);
	});
});

t.describe('dhcp.dnsmasq.validate', () => {
	t.it('rejects port out of range', () => {
		let errs = dnsmasq.validate({ port: 99999 });
		let pe = filter(errs, function(e) { return e.field == "port"; });
		t.assert_equal(pe[0].code, "out_of_range");
	});
	t.it('accepts a minimal recursive setup', () => {
		let errs = dnsmasq.validate({
			domain: 'home.arpa', local: '/home.arpa/',
			noresolv: true, server: ['127.0.0.1#5353'],
		});
		t.assert_equal(length(errs), 0);
	});
});

t.describe('dhcp.odhcpd contract', () => {
	t.it('declares package, type, reload', () => {
		t.assert_equal(odhcpd.package, "dhcp");
		t.assert_equal(odhcpd.type, "odhcpd");
		t.assert_deep_equal(odhcpd.reload, ["odhcpd"]);
	});
	t.it('rejects loglevel out of range', () => {
		let errs = full_validate(odhcpd, { loglevel: 10 }, null);
		let le = filter(errs, function(e) { return e.field == "loglevel"; });
		t.assert_equal(le[0].code, "out_of_range");
	});
});
