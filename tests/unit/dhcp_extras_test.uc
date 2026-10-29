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
		let errs = full_validate(servers, { interface: 'lan', leasetime: 'forever' }, null);
		let le = filter(errs, function(e) { return e.field == "leasetime"; });
		t.assert_equal(le[0].code, "invalid_format");
	});
	t.it('rejects bad ra enum', () => {
		let errs = servers.validate({ interface: 'lan', ra: 'bogus' }, null);
		let re = filter(errs, function(e) { return e.field == "ra"; });
		t.assert_equal(re[0].code, "not_in_enum");
	});
	t.it('accepts dangling interface refs (stock OpenWrt ships dhcp.wan against absent network.wan on x86)', () => {
		let conn = ubus.stub({ uci: { network: {
			lan: { '.type': 'interface' },
		} } });
		let errs = servers.validate({ interface: 'wan' }, conn);
		let ie = filter(errs, function(e) { return e.field == "interface"; });
		t.assert_equal(length(ie), 0);
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
		let errs = full_validate(dnsmasq, { port: 99999 }, null);
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

// LuCI writes `list domain`, which the read answered as an array where the schema declares a
// string, so a PUT of the read answered 422.
t.describe('dhcp.servers domain', () => {
	let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null };
	let h = handler.make(servers, { tx });
	let ctx = { request_id: "01hx0000000000000000000000" };

	t.it('reads a list as its words joined with spaces, and a PUT of the read keeps them', () => {
		let c = ubus.stub({ uci: {
			dhcp: { lan: { '.type': 'dhcp', '.anonymous': false, interface: 'lan', domain: [ 'lan', 'home.arpa' ] } },
			network: { lan: { '.type': 'interface' } },
		} });
		let body = h.get_one(c, ctx, 'lan').body;
		t.assert_equal(body.domain, 'lan home.arpa');
		for (let k in [ 'id', 'managed', 'runtime' ]) delete body[k];
		t.assert_equal(h.replace(c, ctx, 'lan', body).status, 200);
		t.assert_equal(c._state.uci.dhcp.lan.domain, 'lan home.arpa');
	});
});

// dnsmasq.init splits an option into words and passes each entry of a list whole. A read of the
// option as one entry made a PUT store it as one list entry, and dnsmasq refuses that line.
t.describe('dhcp.servers dhcp_option', () => {
	let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null };
	let h = handler.make(servers, { tx });
	let ctx = { request_id: "01hx0000000000000000000000" };
	let stored = (v) => ubus.stub({ uci: {
		dhcp: { lan: { '.type': 'dhcp', '.anonymous': false, interface: 'lan', dhcp_option: v } },
		network: { lan: { '.type': 'interface' } },
	} });

	t.it('reads an option as its words, and a PUT of the read stores them as a list', () => {
		let c = stored('3,1.2.3.4 6,8.8.8.8');
		let body = h.get_one(c, ctx, 'lan').body;
		t.assert_deep_equal(body.dhcp_option, [ '3,1.2.3.4', '6,8.8.8.8' ]);
		for (let k in [ 'id', 'managed', 'runtime' ]) delete body[k];
		t.assert_equal(h.replace(c, ctx, 'lan', body).status, 200);
		t.assert_deep_equal(c._state.uci.dhcp.lan.dhcp_option, [ '3,1.2.3.4', '6,8.8.8.8' ]);
	});

	t.it('reads each entry of a list whole', () => {
		t.assert_deep_equal(h.get_one(stored([ '67,"a b"', '3,1.2.3.4' ]), ctx, 'lan').body.dhcp_option,
		                    [ '67,"a b"', '3,1.2.3.4' ]);
	});

	// dnsmasq read `dhcp-option=lan,3,10.99.0.1 6,10.99.0.1` as option 3, refused the address
	// `10.99.0.1 6`, and did not start, while the write answered 200.
	t.it('refuses an entry that holds a second option, and takes a text option with spaces', () => {
		let c = stored([ '3,10.99.0.1' ]);
		let r = h.patch(c, ctx, 'lan', { dhcp_option: [ '3,10.99.0.1', '3,10.99.0.1 6,10.99.0.1' ] });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, 'dhcp_option[1]');
		t.assert_equal(r.body.errors[0].code, 'invalid_format');
		t.assert_true(index(r.body.errors[0].message, 'reads each entry as one option') >= 0);
		t.assert_true(index(r.body.errors[0].message, 'its own entry') >= 0);
		t.assert_deep_equal(c._state.uci.dhcp.lan.dhcp_option, [ '3,10.99.0.1' ]);
		let opts = [ '3,10.99.0.1', '6,10.99.0.1', '15,my domain', '15,"my 6,domain"' ];
		t.assert_equal(h.patch(c, ctx, 'lan', { dhcp_option: opts }).status, 200);
		t.assert_deep_equal(c._state.uci.dhcp.lan.dhcp_option, opts);
	});

	// LuCI stores any entry, so a section can hold one that the rule refuses.
	t.it('takes a write that leaves such a stored entry as it is, and the sweep lists the entry', () => {
		let c = stored([ '15,my 6,domain' ]);
		t.assert_equal(h.patch(c, ctx, 'lan', { leasetime: '1h' }).status, 200);
		t.assert_equal(h.patch(c, ctx, 'lan', { dhcp_option: [ '15,my 6,domain', '3,1.2.3.4' ] }).status, 422);
		t.assert_deep_equal(map(h.sweep(c), (s) => [ s.id, map(s.errors, (e) => e.field) ]),
		                    [ [ 'lan', [ 'dhcp_option[0]' ] ] ]);
	});
});
