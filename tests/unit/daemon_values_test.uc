let t = require('harness');
let handler = require('handler');
let ubus = require('bus');

function field_errors(file, body, field) {
	let r = loadfile(`src/resources/${file}`)();
	let out = [];
	for (let e in handler.check_schema_types(handler.request_properties(r.schema_properties), body)) push(out, e);
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

	// v4 (#308): LuCI's model, a stored gap blocks every write of the section until a write
	// fixes it, so the writes that leave it alone answer 422 and name it.
	t.it('refuse a create without them, and refuse a write that leaves a stored gap alone', () => {
		let c = stored();
		let r = h().create(c, CTX, { id: 'a2', group: 'public' });
		t.assert_equal(r.status, 422);
		t.assert_deep_equal(sort(map(r.body.errors, (e) => e.field)), sort([ ...NEEDED ]));
		t.assert_equal(h().create(c, CTX, { ...STOCK, id: 'a3' }).status, 200);

		t.assert_equal(length(h().sweep(c)), 1);
		let w = h().patch(c, CTX, 'a1', { read: 'none' });
		t.assert_equal(w.status, 422, w.body);
		t.assert_deep_equal(map(w.body.errors, (e) => [ e.field, e.code ]), [ [ 'context', 'required' ] ]);
		let put = { ...STOCK };
		delete put.context;
		let rep = h().replace(c, CTX, 'a1', put);
		t.assert_equal(rep.status, 422, rep.body);
		t.assert_deep_equal(map(rep.body.errors, (e) => e.field), [ 'context' ]);
		t.assert_deep_equal(map(h().patch(c, CTX, 'a1', { context: '' }).body.errors, (e) => e.field), [ 'context' ]);
		t.assert_equal(h().patch(c, CTX, 'a1', { context: 'none' }).status, 200);
		t.assert_equal(length(h().sweep(c)), 0);
	});
});

// lldpd.init joins the entries of `interface` and splits them into words. A read of
// `option interface 'loopback lan'`, or of such a list entry, as one entry broke the pattern of the
// field, so a JSON Patch of any field of the singleton, and a merge PATCH of the read, answered 422.
t.describe('lldpd/config interface of several words in one value', () => {
	let lldpd = loadfile('src/resources/lldpd.config.uc')();
	let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null };
	let h = handler.make_singleton(lldpd, { tx });
	const CTX = { request_id: "01hx0000000000000000000000" };
	let stored = (v) => ubus.stub({ uci: { lldpd: {
		config: { '.type': 'lldpd', '.anonymous': false, interface: v ?? 'loopback lan' },
	} } });

	t.it('reads an option or a list entry as its words, and a JSON Patch or a merge PATCH of the read passes', () => {
		for (let v in [ 'loopback lan', [ 'loopback lan' ] ]) {
			let c = stored(v);
			let body = h.get(c, CTX).body;
			t.assert_deep_equal(body.interface, [ 'loopback', 'lan' ], sprintf("%J", v));
			t.assert_equal(h.patch(c, { ...CTX, json_patch: true },
			                       [ { op: 'replace', path: '/enable_cdp', value: true } ]).status, 200, sprintf("%J", v));
			delete body.runtime;
			t.assert_equal(h.patch(c, CTX, body).status, 200, sprintf("%J", v));
		}
	});

	t.it('stores a list when a write changes the entries', () => {
		let c = stored();
		t.assert_equal(h.patch(c, CTX, { interface: [ 'loopback', 'lan', 'wan' ] }).status, 200);
		t.assert_deep_equal(c._state.uci.lldpd.config.interface, [ 'loopback', 'lan', 'wan' ]);
	});
});

// Each row is an option that an init script reads with config_get_bool or a libvalidate `:bool:`,
// and the value that the daemon takes when the option is absent.
const SHELL_BOOLS = [
	[ "system.uc", "system", "log_remote", "log_remote", true ],
	[ "system.timeservers.uc", "timeserver", "enabled", "enabled", true ],
	[ "system.timeservers.uc", "timeserver", "enable_server", "enable_server", false ],
	[ "system.timeservers.uc", "timeserver", "use_dhcp", "use_dhcp", true ],
	[ "usteer.config.uc", "usteer", "syslog", "syslog", false ],
	[ "usteer.config.uc", "usteer", "ipv6", "ipv6", false ],
	[ "usteer.config.uc", "usteer", "assoc_steering", "assoc_steering", false ],
	[ "dropbear.instances.uc", "dropbear", "PasswordAuth", "password_auth", true ],
	[ "dropbear.instances.uc", "dropbear", "RootPasswordAuth", "root_password_auth", true ],
	[ "dropbear.instances.uc", "dropbear", "RootLogin", "root_login", true ],
	[ "dropbear.instances.uc", "dropbear", "GatewayPorts", "gateway_ports", false ],
];

// sqm-scripts 1.8.0 (77cf89e, src/run-openwrt.sh:47) runs a queue only for `-eq 1`.
t.describe('sqm/queues.enabled reads true only where sqm-scripts starts the queue', () => {
	let sqm = loadfile('src/resources/sqm.queues.uc')();
	let read = (v) => sqm.fromUci({ '.name': 'q', '.type': 'queue', enabled: v }).enabled;
	t.it('takes 1 as the shell test reads it, and reads an absent value and the other spellings as off', () => {
		t.assert_deep_equal(map([ "1", "01", [ "1" ], "+01", " 1", "\t1\n" ], read), [ true, true, true, true, true, true ]);
		t.assert_deep_equal(map([ null, "0", "yes", "on", "true", "enabled", "2", "", "-1", "+ 1", "1 1", "0x1" ], read),
		                    [ false, false, false, false, false, false, false, false, false, false, false, false ]);
		t.assert_equal(sqm.schema_properties.enabled.default, false);
	});
});

// sqm-scripts matches `interface` against the device that its hotplug reports, and the stock
// /etc/config/sqm holds `interface 'eth1'`. uapi checked it against the uci interfaces, so no write
// of the stock queue passed.
t.describe('sqm/queues.interface takes a device name', () => {
	let sqm = loadfile('src/resources/sqm.queues.uc')();
	let h = handler.make(sqm, { tx: {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	} });
	let ctx = () => ({ request_id: "01hx0000000000000000000sqm" });
	let stock = () => ubus.stub({ uci: {
		sqm: { eth1: { '.type': 'queue', '.anonymous': false, enabled: '0', interface: 'eth1', download: '85000',
		               upload: '10000', qdisc: 'cake', script: 'piece_of_cake.qos' } },
		network: { wan: { '.type': 'interface', '.anonymous': false, device: 'eth1', proto: 'dhcp' } },
	} });
	t.it('passes a write of the stock queue and a create on a device that is not up', () => {
		t.assert_equal(h.patch(stock(), ctx(), 'eth1', { upload: 10001 }).status, 200);
		t.assert_equal(h.create(stock(), ctx(), { id: 'ppp', interface: 'pppoe-wan', download: 1, upload: 1 }).status, 200);
	});
	t.it('refuses a name that the kernel cannot give a device', () => {
		for (let v in [ 'a/b', 'a:b', 'a b', '0123456789abcdef' ])
			t.assert_deep_equal(map(field_errors('sqm.queues.uc', { interface: v }, 'interface'), (e) => e.code),
			                    [ 'invalid_format' ], v);
	});
});

// LuCI's sqm form writes options that sqm/queues did not model, so a PUT of the read removed them
// (#480). sqm-scripts 1.8.0 reads them in run.sh and gives an absent one the value of defaults.sh.
t.describe('sqm/queues models the options of LuCI as sqm-scripts reads them', () => {
	let sqm = loadfile('src/resources/sqm.queues.uc')();
	let h = handler.make(sqm, { tx: {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
	} });
	let ctx = () => ({ request_id: "01hx000000000000000000sqm2" });
	const STOCK = { '.type': 'queue', '.anonymous': false, enabled: '0', interface: 'eth1', download: '85000',
	                upload: '10000', qdisc: 'cake', script: 'piece_of_cake.qos', qdisc_advanced: '0',
	                ingress_ecn: 'ECN', egress_ecn: 'ECN', qdisc_really_really_advanced: '0', itarget: 'auto',
	                etarget: 'auto', linklayer: 'none', use_mq: '0' };
	const LUCI = { ...STOCK, qdisc_advanced: '1', qdisc_really_really_advanced: '1', egress_ecn: 'NOECN',
	               squash_dscp: '0', ilimit: '1000', iqdisc_opts: 'nat dual-dsthost', linklayer: 'ethernet',
	               overhead: '34', linklayer_advanced: '1', tcMTU: '1600', tcTSIZE: '128', tcMPU: '64',
	               linklayer_adaptation_mechanism: 'tc_stab', debug_logging: '1', verbosity: '8' };
	let stored = (sec) => ubus.stub({ uci: { sqm: { eth1: { ...sec } } } });
	let read_of = (c) => { let b = h.get_one(c, ctx(), 'eth1').body; delete b.runtime; return b; };
	let options = (c) => { let o = { ...c.uci_get('sqm', 'eth1') }; delete o['.name']; return o; };

	t.it('keeps every option on a PUT of the read, and adds none', () => {
		for (let sec in [ STOCK, LUCI ]) {
			let c = stored(sec);
			t.assert_equal(h.replace(c, ctx(), 'eth1', read_of(c)).status, 200);
			t.assert_deep_equal(options(c), sec);
		}
	});

	t.it('reads an absent option as the default of sqm-scripts, and a stored one as sqm-scripts reads it', () => {
		let r = read_of(stored({ '.type': 'queue', '.anonymous': false, interface: 'eth1', script: 'simple.qos' }));
		t.assert_deep_equal([ r.download, r.upload, r.qdisc, r.linklayer, r.overhead, r.egress_ecn, r.tc_tsize,
		                      r.verbosity, r.squash_dscp, r.itarget ],
		                    [ 14698, 2302, "fq_codel", "none", 0, "ECN", 512, 5, true, null ]);
		r = read_of(stored(LUCI));
		t.assert_deep_equal([ r.tc_mtu, r.tc_tsize, r.tc_mpu, r.squash_dscp, r.egress_ecn, r.ilimit ],
		                    [ 1600, 128, 64, false, "NOECN", 1000 ]);
		t.assert_equal(read_of(stored({ ...STOCK, verbosity: '3' })).verbosity, 3);
	});

	t.it('reads squash_dscp as the stored script tests it', () => {
		t.assert_equal(read_of(stored({ ...STOCK, squash_dscp: '01' })).squash_dscp, true);
		t.assert_equal(read_of(stored({ ...STOCK, script: 'simple.qos', squash_dscp: '01' })).squash_dscp, false);
	});

	t.it('removes a caller-owned option for a null, and refuses a value outside what LuCI writes', () => {
		let c = stored(LUCI);
		t.assert_equal(h.patch(c, ctx(), 'eth1', { ilimit: null, iqdisc_opts: null }).status, 200);
		t.assert_deep_equal([ options(c).ilimit, options(c).iqdisc_opts ], [ null, null ]);
		for (let body in [ { egress_ecn: 'ecn' }, { verbosity: 3 }, { ilimit: -1 }, { tc_mtu: -1 },
		                   { linklayer_adaptation_mechanism: 'stab' } ])
			t.assert_equal(h.patch(stored(STOCK), ctx(), 'eth1', body).status, 422, sprintf('%J', body));
	});
});

t.describe('booleans read as the init script of the daemon reads them', () => {
	for (let row in SHELL_BOOLS) {
		let file = row[0], type = row[1], option = row[2], field = row[3], absent = row[4];
		t.it(sprintf("%s %s", file, field), () => {
			let r = loadfile(`src/resources/${file}`)();
			let read = (v) => {
				let s = { '.name': 'x', '.type': type };
				s[option] = v;
				return r.fromUci(s)[field];
			};
			for (let v in [ "1", "on", "true", "yes", "enabled" ])
				t.assert_equal(read(v), true, v);
			for (let v in [ "0", "off", "false", "no", "disabled" ])
				t.assert_equal(read(v), false, v);
			t.assert_equal(read(null), absent, "absent");
			t.assert_equal(r.schema_properties[field].default, absent, "schema default");
		});
	}
});
