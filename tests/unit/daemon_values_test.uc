let t = require('harness');
let handler = require('handler');

function field_errors(file, body, field, delta) {
	let r = loadfile(`src/resources/${file}`)();
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, null, null, delta)) push(out, e);
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
	[ "snmpd.accesses.uc", "group" ], [ "snmpd.accesses.uc", "context" ],
	[ "snmpd.accesses.uc", "read" ], [ "snmpd.accesses.uc", "write" ],
	[ "snmpd.accesses.uc", "notify" ],
	[ "snmpd.com2secs.uc", "secname" ], [ "snmpd.com2secs.uc", "source" ],
	[ "snmpd.com2secs.uc", "community" ],
	[ "snmpd.groups.uc", "group" ], [ "snmpd.groups.uc", "secname" ],
];

const SHELL_WORD = [
	[ "dhcp.dnsmasq.uc", "leasefile" ], [ "dhcp.dnsmasq.uc", "resolvfile" ],
	[ "mwan3.rules.uc", "src_port" ], [ "mwan3.rules.uc", "dest_port" ],
	[ "mwan3.rules.uc", "ipset" ],
];

const NARROW = [ [ "unbound.server.uc", "domain" ], [ "network.interfaces.uc", "clientid" ] ];

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

	t.it('take the unbound domain as a DNS name', () => {
		for (let v in [ "lan", "home.arpa", "my-lan_1", "" ])
			t.assert_equal(length(field_errors("unbound.server.uc", { domain: v }, "domain")), 0, v);
		for (let v in [ "lan\\n", "lan'", 'lan"', "lan.", "a..b" ])
			t.assert_equal(length(field_errors("unbound.server.uc", { domain: v }, "domain")), 1, v);
	});

	t.it('refuse a double quote in the lldpd values, which lldpd.init writes between quotes', () => {
		for (let f in [ "lldp_description", "lldp_mgmt_ip" ])
			t.assert_equal(length(field_errors("lldpd.config.uc", { [f]: 'a"b' }, f)), 1, f);
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

	t.it('leave a stored ssid alone on a write that names neither ssid nor mode', () => {
		let stored = { device: "radio0", mode: "monitor", ssid: "Bob's", disabled: true };
		t.assert_equal(length(field_errors("wireless.interfaces.uc", stored, "ssid", { disabled: true })), 0);
		t.assert_equal(length(field_errors("wireless.interfaces.uc", stored, "ssid", { mode: "monitor" })), 1);
	});
});
