let t = require('harness');
let handler = require('handler');
let ubus = require('bus');

function field_errors(file, body, field) {
	let r = loadfile(`src/resources/${file}`)();
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, null)) push(out, e);
	for (let e in (r.validate_new != null) ? r.validate_new(body) : []) push(out, e);
	return filter(out, (e) => e.field == field);
}

const ONE_LINE = [
	[ "snmpd.agents.uc", "agentaddress", true ],
	[ "snmpd.system.uc", "sys_location" ], [ "snmpd.system.uc", "sys_contact" ],
	[ "snmpd.system.uc", "sys_name" ], [ "snmpd.system.uc", "sys_descr" ],
	[ "snmpd.system.uc", "sys_object_id" ],
	[ "dhcp.dnsmasq.uc", "domain" ], [ "dhcp.dnsmasq.uc", "local" ],
	[ "dhcp.dnsmasq.uc", "server", true ], [ "dhcp.dnsmasq.uc", "address", true ],
	[ "dhcp.servers.uc", "domain" ], [ "dhcp.servers.uc", "dhcp_option", true ],
	[ "lldpd.config.uc", "lldp_description" ], [ "lldpd.config.uc", "lldp_mgmt_ip" ],
];

const ONE_WORD = [
	[ "snmpd.accesses.uc", "group" ],
	[ "snmpd.accesses.uc", "read" ], [ "snmpd.accesses.uc", "write" ],
	[ "snmpd.accesses.uc", "notify" ],
	[ "snmpd.com2secs.uc", "secname" ], [ "snmpd.com2secs.uc", "source" ],
	[ "snmpd.com2secs.uc", "community" ],
	[ "snmpd.groups.uc", "group" ], [ "snmpd.groups.uc", "secname" ],
];

const SHELL_WORD = [
	[ "snmpd.accesses.uc", "context" ],
	[ "dhcp.dnsmasq.uc", "leasefile" ], [ "dhcp.dnsmasq.uc", "resolvfile" ],
	[ "mwan3.rules.uc", "src_port" ], [ "mwan3.rules.uc", "dest_port" ],
	[ "mwan3.rules.uc", "ipset" ],
];

const NARROW = [ [ "unbound.server.uc", "domain" ], [ "network.interfaces.uc", "clientid" ] ];

const DNSMASQ_TEXT = [
	[ "dhcp.dnsmasq.uc", "domain" ], [ "dhcp.dnsmasq.uc", "local" ],
	[ "dhcp.dnsmasq.uc", "server", true ], [ "dhcp.dnsmasq.uc", "address", true ],
	[ "dhcp.servers.uc", "domain" ],
];

function probe(c, v) {
	let path = c[2] ? `${c[1]}[0]` : c[1];
	return field_errors(c[0], { [c[1]]: c[2] ? [ v ] : v }, path);
}

t.describe('values that an init script copies onto a daemon config line', () => {
	t.it('refuse a newline or a carriage return', () => {
		for (let c in [ ...ONE_LINE, ...ONE_WORD, ...SHELL_WORD, ...NARROW ])
			for (let v in [ "a\nb", "a\rb" ]) {
				let e = probe(c, v);
				t.assert_equal(length(e), 1, sprintf("%s %s %J", c[0], c[1], v));
				t.assert_equal(e[0].code, "invalid_format", sprintf("%s %s", c[0], c[1]));
			}
	});

	t.it('keep a space where the daemon reads the value to the end of the line', () => {
		for (let c in ONE_LINE)
			t.assert_equal(length(probe(c, "a b")), 0, sprintf("%s %s", c[0], c[1]));
	});

	t.it('refuse a space or a tab where the value is one word of a line or a command', () => {
		for (let c in [ ...ONE_WORD, ...SHELL_WORD ])
			for (let v in [ "a b", "a\tb" ])
				t.assert_equal(length(probe(c, v)), 1, sprintf("%s %s %J", c[0], c[1], v));
	});

	t.it('refuse *, ? and [ only where a script expands the value unquoted', () => {
		for (let v in [ "/*", "a?", "a[b" ]) {
			for (let c in SHELL_WORD)
				t.assert_equal(length(probe(c, v)), 1, sprintf("%s %s %J", c[0], c[1], v));
			for (let c in ONE_WORD)
				t.assert_equal(length(probe(c, v)), 0, sprintf("%s %s %J", c[0], c[1], v));
		}
	});

	t.it('refuse *, ? and [ in the domain of a dhcp section, which dnsmasq.init splits into words unquoted', () => {
		let c = [ "dhcp.servers.uc", "domain" ];
		for (let v in [ "*", "lan a?", "a[b" ])
			t.assert_equal(length(probe(c, v)), 1, v);
		t.assert_equal(length(probe(c, "lan home.arpa")), 0);
		t.assert_equal(length(probe([ "dhcp.dnsmasq.uc", "domain" ], "a*")), 0);
	});

	t.it('take the unbound domain as a DNS name', () => {
		for (let v in [ "lan", "home.arpa", "my-lan_1", "" ])
			t.assert_equal(length(field_errors("unbound.server.uc", { domain: v }, "domain")), 0, v);
		for (let v in [ "lan\\n", "lan'", 'lan"', "lan.", "a..b" ])
			t.assert_equal(length(field_errors("unbound.server.uc", { domain: v }, "domain")), 1, v);
	});

	t.it('refuse a double quote or a backslash in the lldpd values, which lldpd.init writes between quotes', () => {
		for (let f in [ "lldp_description", "lldp_mgmt_ip" ]) {
			for (let v in [ 'a"b', "a\\b", "a\\" ])
				t.assert_equal(length(field_errors("lldpd.config.uc", { [f]: v }, f)), 1, sprintf("%s %J", f, v));
			for (let v in [ "OpenWrt 'lab' #1", "!192.168.1.1,eth0" ])
				t.assert_equal(length(field_errors("lldpd.config.uc", { [f]: v }, f)), 0, sprintf("%s %J", f, v));
		}
	});

	t.it('take an lldpd interface only as a word that lldpcli reads as it is', () => {
		let c = [ "lldpd.config.uc", "interface", true ];
		for (let v in [ "lan", "loopback", "br-lan.10", "eth*", "*", "!eth1", "!!eth2" ])
			t.assert_equal(length(probe(c, v)), 0, v);
		for (let v in [ 'lan"', "lan'", "eth\\0", "eth#0", "lan wan", "lan\twan", "lan\r" ])
			t.assert_equal(length(probe(c, v)), 1, v);
	});

	t.it('refuse a double quote, and a # after whitespace, where dnsmasq reads the value', () => {
		for (let c in DNSMASQ_TEXT) {
			t.assert_equal(length(probe(c, "/#/")), 0, sprintf("%s %s", c[0], c[1]));
			for (let v in [ 'a"b', "a #b" ])
				t.assert_equal(length(probe(c, v)), 1, sprintf("%s %s %J", c[0], c[1], v));
		}
		for (let f in [ "leasefile", "resolvfile" ])
			t.assert_equal(length(field_errors("dhcp.dnsmasq.uc", { [f]: '/tmp/a"b' }, f)), 1, f);
		let c = [ "dhcp.servers.uc", "dhcp_option", true ];
		t.assert_equal(length(probe(c, '66,"1.2.3.4"')), 0);
		t.assert_equal(length(probe(c, '66,"1.2.3.4')), 1);
	});

t.it('take a clientid as hex digits with optional colons', () => {
		for (let v in [ "01aabbccddeeff", "01:aa:bb:cc:dd:ee:ff" ])
			t.assert_equal(length(field_errors("network.interfaces.uc", { clientid: v }, "clientid")), 0, v);
		t.assert_equal(length(field_errors("network.interfaces.uc", { clientid: "01aa-x" }, "clientid")), 1);
	});

	t.it('refuse a single quote in the ssid only in the modes that reach a shell command', () => {
		for (let mode in [ "monitor", "adhoc", "mesh" ]) {
			let e = field_errors("wireless.interfaces.uc", { device: "radio0", mode: mode, ssid: "Bob's" }, "ssid");
			t.assert_equal(length(e), 1, mode);
			t.assert_equal(e[0].code, "invalid_format", mode);
			t.assert_equal(length(field_errors("wireless.interfaces.uc", { device: "radio0", mode: mode, ssid: "Bob" }, "ssid")), 0, mode);
		}
		for (let mode in [ "ap", "sta", "wds" ])
			t.assert_equal(length(field_errors("wireless.interfaces.uc", { device: "radio0", mode: mode, ssid: "Bob's" }, "ssid")), 0, mode);
	});
});

t.describe('snmpd/accesses fields that snmpd.init needs', () => {
	let acc = loadfile('src/resources/snmpd.accesses.uc')();
	const STOCK = { group: 'public', context: 'none', version: 'any', level: 'noauth', prefix: 'exact',
	                read: 'all', write: 'none', notify: 'none' };
	const NEEDED = [ "context", "version", "level", "prefix", "read", "write", "notify" ];
	let tx = {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	};
	const CTX = { request_id: "01hx0000000000000000000000" };
	function h() { return handler.make(acc, { tx }); }
	// LuCI writes no context unless the operator types one.
	function stored() {
		let a = { '.type': 'access', '.anonymous': false, ...STOCK };
		delete a.context;
		return ubus.stub({ uci: { snmpd: {
			g1: { '.type': 'group', '.anonymous': false, group: 'public', version: 'v2c', secname: 'ro' },
			a1: a,
		} } });
	}

	t.it('refuse an access without one of them, and point an empty context to none', () => {
		t.assert_deep_equal(acc.validate_new(STOCK), []);
		for (let f in NEEDED)
			for (let v in [ null, "" ])
				t.assert_deep_equal(map(acc.validate_new({ ...STOCK, [f]: v }), (e) => [ e.field, e.code ]),
				                    [ [ f, "required" ] ], sprintf("%s %J", f, v));
		t.assert_true(index(acc.validate_new({ ...STOCK, context: "" })[0].message, '"none"') >= 0);
	});

	t.it('refuse a create without them, and take a write that leaves a stored gap alone', () => {
		let c = stored();
		let r = h().create(c, CTX, { id: 'a2', group: 'public' });
		t.assert_equal(r.status, 422);
		t.assert_deep_equal(sort(map(r.body.errors, (e) => e.field)), sort([ ...NEEDED ]));
		t.assert_equal(h().create(c, CTX, { ...STOCK, id: 'a3' }).status, 200);

		t.assert_equal(length(h().sweep(c)), 1);
		t.assert_equal(h().patch(c, CTX, 'a1', { read: 'none' }).status, 200);
		let put = { ...STOCK };
		delete put.context;
		t.assert_equal(h().replace(c, CTX, 'a1', put).status, 200);
		t.assert_deep_equal(map(h().patch(c, CTX, 'a1', { context: '' }).body.errors, (e) => e.field), [ 'context' ]);
		t.assert_equal(h().patch(c, CTX, 'a1', { context: 'none' }).status, 200);
		t.assert_equal(length(h().sweep(c)), 0);
	});
});
