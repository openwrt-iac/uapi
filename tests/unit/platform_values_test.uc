let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let fs = require('fs');
let fx = require('resource_fixtures');

const SPEC = json(fs.readfile("build/openapi.json")).components.schemas;

// A value that LuCI writes or that the daemon takes. Its read conforms to the Response, a PATCH of
// another field passes, and so does a write that sends the read back: a merge PATCH and a JSON
// Patch of the field, and a PUT of the whole read. A PATCH that sets the value on the section as the
// fixture stores it answers `set`: 200 where a write takes the value, 422 where only a read gives
// it. Each row stores one value in the fixture case of its resource: [ module, fixture id, uci
// option, stored value, field that the read gives, set, and the options that the case needs beside
// it ].
const ROWS = [
	[ "firewall.defaults.uc", "defaults", "synflood_burst", "0", "synflood_burst", 200 ],
	[ "firewall.defaults.uc", "defaults", "synflood_rate", "2000000", "synflood_rate", 200 ],
	[ "firewall.nat.uc", "n1", "target", "NPT", "target", 422, { snat_ip: null } ],
	[ "firewall.nat.uc", "n1", "target", "NPT", "target", 422 ],
	[ "firewall.nat.uc", "n1", "src_port", "! 1024", "match.src_port", 200 ],
	[ "firewall.nat.uc", "n1", "mark", "! 0x10", "match.mark", 200 ],
	[ "firewall.redirects.uc", "d1", "src_dport", " ! 8080", "match.src_dport", 200 ],
	[ "firewall.redirects.uc", "d1", "mark", "! 0x10", "match.mark", 200 ],
	[ "firewall.rules.uc", "r1", "dest_port", [ "! 22" ], "match.dest_port", 200 ],
	[ "firewall.rules.uc", "r1", "dscp", "! EF", "match.dscp", 200 ],
	[ "firewall.rules.uc", "r1", "mark", "! 0x10", "match.mark", 200 ],
	[ "network.interfaces.uc", "lan", "metric", "-1", "metric", 422 ],
	[ "network.interfaces.uc", "lan", "ip6weight", "-5", "ip6weight", 422 ],
	[ "network.interfaces.uc", "wan6", "reqprefix", "56:1a", "reqprefix", 200 ],
	[ "network.interfaces.uc", "wan6", "reqprefix", "2001:db8::/56:1", "reqprefix", 200 ],
	[ "network.devices.uc", "dev1", "vid", "0", "vid", 422 ],
	[ "network.devices.uc", "dev2", "type", "bonding", "type", 422 ],
	[ "network.bridge_vlans.uc", "bv1", "ports", [ "lan1:u*", "wlan0+1:t" ], "ports", 200 ],
	[ "network.routes.uc", "rt1", "metric", "-1", "metric", 422 ],
	[ "network.routes.uc", "rt1", "mtu", "-1", "mtu", 422 ],
	[ "network.rules.uc", "nr1", "priority", "40000", "priority", 200 ],
	[ "wireless.devices.uc", "radio0", "type", "qcawifi", "type", 422 ],
	[ "wireless.interfaces.uc", "w1", "mode", "ahdemo", "mode", 422 ],
	[ "wireless.interfaces.uc", "w1", "encryption", "sae-compat", "encryption", 200 ],
	[ "wireless.interfaces.uc", "w1", "encryption", "wpa3-192", "encryption", 200 ],
	[ "wireless.interfaces.uc", "w1", "encryption", "psk3", "encryption", 200 ],
	[ "wireless.interfaces.uc", "w1", "encryption", "psk3-mixed", "encryption", 200 ],
	[ "wireless.interfaces.uc", "w1", "encryption", "wpa-mixed+ccmp", "encryption", 200 ],
	[ "mwan3.globals.uc", "globals", "mmx_mask", "16128", "mmx_mask", 200 ],
	[ "mwan3.globals.uc", "globals", "mmx_mask", "037400", "mmx_mask", 200 ],
	[ "mwan3.globals.uc", "globals", "loglevel", "warning", "loglevel", 200 ],
	[ "mwan3.interfaces.uc", "mwan", "track_method", "nping-icmp", "track_method", 200 ],
	[ "mwan3.interfaces.uc", "mwan", "track_method", "nslookup", "track_method", 422 ],
	[ "mwan3.interfaces.uc", "mwan", "count", "20", "probe_count", 422 ],
	[ "mwan3.interfaces.uc", "mwan", "size", "0", "size", 422 ],
	[ "mwan3.interfaces.uc", "mwan", "failure_loss", "200", "failure_loss", 200 ],
	[ "mwan3.interfaces.uc", "mwan", "recovery_loss", "200", "recovery_loss", 200 ],
	[ "mwan3.interfaces.uc", "mwan", "recovery_latency", "0", "recovery_latency", 200 ],
	[ "mwan3.interfaces.uc", "mwan", "timeout", "100", "timeout", 422 ],
	[ "mwan3.interfaces.uc", "mwan", "interval", "0", "interval", 422 ],
	[ "mwan3.interfaces.uc", "mwan", "failure_interval", "7200", "failure_interval", 200 ],
	[ "mwan3.interfaces.uc", "mwan", "recovery_interval", "0", "recovery_interval", 200 ],
	[ "mwan3.interfaces.uc", "mwan", "flush_conntrack", [ "always" ], "flush_conntrack", 422 ],
	[ "mwan3.members.uc", "m1", "metric", "0", "metric", 422 ],
	[ "mwan3.members.uc", "m1", "weight", "5000", "weight", 422 ],
	[ "mwan3.rules.uc", "mr1", "proto", "esp", "proto", 200 ],
	[ "mwan3.rules.uc", "mr1", "proto", "47", "proto", 200 ],
	[ "mwan3.rules.uc", "mr1", "family", "any", "family", 200 ],
	[ "mwan3.rules.uc", "mr1", "timeout", "500000", "timeout", 200 ],
	[ "mwan3.rules.uc", "mr1", "timeout", "2000000", "timeout", 422 ],
	[ "openvpn.instances.uc", "vpn0", "dev_type", "null", "dev_type", 422 ],
	[ "openvpn.instances.uc", "vpn0", "port", "0", "port", 422 ],
	[ "openvpn.instances.uc", "vpn0", "rport", "0", "rport", 422 ],
	[ "openvpn.instances.uc", "vpn0", "ping", "0", "ping", 200 ],
	[ "openvpn.instances.uc", "vpn0", "ping_restart", "100000", "ping_restart", 200 ],
	[ "openvpn.instances.uc", "vpn0", "compress", "frames_only", "compress", 200 ],
	[ "openvpn.instances.uc", "vpn0", "compress", "migrate", "compress", 200 ],
	[ "openvpn.instances.uc", "vpn0", "verb", "20", "verb", 422 ],
	[ "prometheus_node_exporter_lua.config.uc", "main", "listen_port", "0", "listen_port", 422 ],
	[ "sqm.queues.uc", "q1", "qdisc", "sfq", "qdisc", 200 ],
	[ "sqm.queues.uc", "q1", "script", "simplest_tbf.qos", "script", 200 ],
	[ "usteer.config.uc", "cfg", "debug_level", "5", "debug_level", 200 ],
	[ "usteer.config.uc", "cfg", "debug_level", "9", "debug_level", 422 ],
	[ "usteer.config.uc", "cfg", "max_neighbor_reports", "1000", "max_neighbor_reports", 200 ],
	[ "usteer.config.uc", "cfg", "load_balancing_threshold", "1000", "load_balancing_threshold", 200 ],
	[ "usteer.config.uc", "cfg", "band_steering_threshold", "1000", "band_steering_threshold", 200 ],
	[ "dhcp.dnsmasq.uc", "main", "port", "0", "port", 200 ],
	[ "dhcp.dnsmasq.uc", "main", "cachesize", "5000000", "cachesize", 422 ],
	[ "dhcp.odhcpd.uc", "odhcpd", "loglevel", "8", "loglevel", 200 ],
	[ "dhcp.servers.uc", "s1", "start", "300", "start", 200 ],
	[ "dhcp.servers.uc", "s1", "limit", "1000", "limit", 200 ],
	[ "dhcp.servers.uc", "s1", "leasetime", "infinite", "leasetime", 200 ],
	[ "dhcp.servers.uc", "s1", "leasetime", "deprecated", "leasetime", 200 ],
	[ "dhcp.servers.uc", "s1", "ra_default", "5", "ra_default", 422 ],
	[ "dhcp.servers.uc", "s1", "dhcpv4", "on", "dhcpv4", 422 ],
	[ "dropbear.instances.uc", "db1", "Port", "0", "port", 200 ],
	[ "system.uc", "cfg1", "hostname", "router.", "hostname", 200 ],
	[ "uhttpd.certs.uc", "px", "days", "40000", "days", 200 ],
	[ "uhttpd.certs.uc", "px", "days", "0", "days", 422 ],
	[ "uhttpd.instances.uc", "main", "http_keepalive", "-1", "http_keepalive", 422 ],
	[ "uhttpd.instances.uc", "main", "tcp_keepalive", "-1", "tcp_keepalive", 422 ],
	[ "uhttpd.instances.uc", "main", "listen_http", [ "[::ffff:192.0.2.1]:80" ], "listen_http", 200 ],
	[ "unbound.server.uc", "ub", "rebind_protection", "3", "rebind_protection", 422 ],
	[ "unbound.server.uc", "ub", "num_threads", "128", "num_threads", 422 ],
	[ "unbound.server.uc", "ub", "add_local_fqdn", "5", "add_local_fqdn", 422 ],
	[ "unbound.server.uc", "ub", "add_wan_fqdn", "5", "add_wan_fqdn", 422 ],
	[ "unbound.server.uc", "ub", "ttl_min", "-1", "ttl_min", 422 ],
	[ "unbound.server.uc", "ub", "ttl_min", "90000", "ttl_min", 422 ],
	[ "snmpd.accesses.uc", "ac1", "level", "authpriv", "level", 422, { write: 'none', notify: 'none' } ],
	[ "snmpd.accesses.uc", "ac1", "prefix", "0", "prefix", 422, { write: 'none', notify: 'none' } ],
	[ "snmpd.accesses.uc", "ac1", "version", "V1", "version", 422, { write: 'none', notify: 'none' } ],
	[ "snmpd.groups.uc", "g1", "version", "any", "version", 422 ],
	[ "snmpd.system.uc", "sys", "sysService", "200", "sys_services", 422 ],
];

let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null,
           wg_apply: () => null, wg_reconcile: () => null };
let ctx = { request_id: "01hx0000000000000000000000" };

function schema_name(file) {
	let name = "";
	for (let w in split(replace(file, /\.uc$/, ""), /[._]/)) name += uc(substr(w, 0, 1)) + substr(w, 1);
	return name;
}

function nested(parts, v) {
	return (length(parts) == 1) ? { [parts[0]]: v } : { [parts[0]]: nested(slice(parts, 1), v) };
}

// A PATCH that sends back the stored value of another boolean, which writes nothing and still runs
// every check over the section.
function other_field(mod, read, field) {
	for (let k, s in mod.schema_properties)
		if (k != field && type(s) == "object" && s.type == "boolean" && !s.readOnly && read[k] != null)
			return { [k]: read[k] };
	return {};
}

function strip(body) {
	let out = { ...body };
	delete out.runtime;
	return out;
}

function status(r) {
	return (r.status == 200) ? 200 : sprintf("%d %J", r.status, r.body.errors ?? r.body);
}

function seeded(c, section) {
	let uci = fx.world();
	if (uci[c.pkg] == null) uci[c.pkg] = {};
	uci[c.pkg][c.id] = { '.anonymous': false, ...section };
	return ubus.stub({ uci: uci });
}

t.describe('property: a value that the platform takes reads within the Response and blocks no write', () => {
	for (let row in ROWS) {
		let file = row[0], id = row[1], option = row[2], value = row[3], field = row[4], set = row[5];
		t.it(sprintf("%s %s %J", file, option, value), () => {
			let c = filter(fx.CASES, (k) => k.file == file && k.id == id)[0];
			let mod = loadfile('src/resources/' + file)();
			let h = c.singleton ? handler.make_singleton(mod, { tx }) : handler.make(mod, { tx });
			let stored = () => seeded(c, { ...c.section, ...(row[6] ?? {}), [option]: value });
			let patch = (conn, body, x) => c.singleton ? h.patch(conn, x ?? ctx, body) : h.patch(conn, x ?? ctx, c.id, body);
			let parts = split(field, ".");

			let read = (c.singleton ? h.get(stored(), ctx) : h.get_one(stored(), ctx, c.id)).body;
			let mine = (e) => e.field == field || index(e.field, field + "[") == 0;
			t.assert_deep_equal(filter(handler.check_schema_types(SPEC[schema_name(file) + "Response"].properties, read), mine), []);

			t.assert_equal(status(patch(stored(), other_field(mod, read, parts[0]))), 200);

			let v = read;
			for (let p in parts) v = v[p];
			t.assert_equal(status(patch(stored(), { [parts[0]]: read[parts[0]] })), 200);
			t.assert_equal(status(patch(stored(), [ { op: "replace", path: "/" + join("/", parts), value: v } ],
			                            { ...ctx, json_patch: true })), 200);
			if (!c.singleton)
				t.assert_equal(status(h.replace(stored(), ctx, c.id, strip(read))), 200);

			let r = patch(seeded(c, { ...c.section, ...(row[6] ?? {}) }), nested(parts, v));
			t.assert_equal(r.status, set, sprintf("%J", r.body));
		});
	}
});

function resource(file) {
	let c = filter(fx.CASES, (k) => k.file == file)[0];
	let mod = loadfile('src/resources/' + file)();
	return { c, h: c.singleton ? handler.make_singleton(mod, { tx }) : handler.make(mod, { tx }) };
}

t.describe('network/interfaces: the id of a section that LuCI named', () => {
	t.it('takes a PUT that echoes an id that a create refuses, such as 4g', () => {
		let uci = fx.world();
		uci.network['4g'] = { '.type': 'interface', '.anonymous': false, proto: 'static', device: 'wwan0',
		                      ipaddr: '10.64.0.2/24' };
		let conn = ubus.stub({ uci: uci });
		let h = handler.make(loadfile('src/resources/network.interfaces.uc')(), { tx });
		let r = h.replace(conn, ctx, '4g', strip(h.get_one(conn, ctx, '4g').body));
		t.assert_equal(r.status, 200, sprintf("%J", r.body));
		t.assert_deep_equal(filter(h.sweep(conn), (s) => s.id == '4g'), []);
	});
});

t.describe('a write refuses the values that stop the daemon', () => {
	let refused = (file, id, extra, body) => {
		let c = filter(fx.CASES, (k) => k.file == file && k.id == id)[0];
		let mod = loadfile('src/resources/' + file)();
		let h = c.singleton ? handler.make_singleton(mod, { tx }) : handler.make(mod, { tx });
		let conn = seeded(c, { ...c.section, ...extra });
		let r = c.singleton ? h.patch(conn, ctx, body) : h.patch(conn, ctx, c.id, body);
		return map(r.body.errors ?? [], (e) => e.field + ":" + e.code);
	};
	t.it('a reqprefix with a / and no address, on which odhcp6c exits', () => {
		t.assert_deep_equal(refused("network.interfaces.uc", "wan6", {}, { reqprefix: "/56" }), [ "reqprefix:invalid_format" ]);
		t.assert_deep_equal(refused("network.interfaces.uc", "wan6", { reqprefix: "/56" }, { sourcefilter: true }), [ "reqprefix:invalid_format" ]);
	});
	t.it('an mwan3 rule protocol that iptables cannot parse, which fails the batch of the family', () => {
		for (let p in [ "999", "256", "foo", "08", "09", "099", "0400", "0x100", "0x" ])
			t.assert_deep_equal(refused("mwan3.rules.uc", "mr1", {}, { proto: p }), [ "proto:invalid_format" ]);
		for (let p in [ "TCP", "ipv6-icmp", "gre", "255", "010", "0377", "0300", "0x11", "0XfF" ])
			t.assert_deep_equal(refused("mwan3.rules.uc", "mr1", {}, { proto: p }), []);
	});
	t.it('an mmx_mask past 32 bits, or a decimal with a leading 0 that the shell reads as octal', () => {
		for (let m in [ "4294967296", "040000000000" ])
			t.assert_deep_equal(refused("mwan3.globals.uc", "globals", {}, { mmx_mask: m }), [ "mmx_mask:out_of_range" ]);
		t.assert_deep_equal(refused("mwan3.globals.uc", "globals", {}, { mmx_mask: "016128" }), [ "mmx_mask:invalid_format" ]);
		for (let m in [ "4294967295", "037777777777", "0x000003F00" ])
			t.assert_deep_equal(refused("mwan3.globals.uc", "globals", {}, { mmx_mask: m }), []);
	});
});

t.describe('a refusal keeps the message that 3.x gave', () => {
	const MAIN = [
		[ "network.devices.uc", "dev1", { vid: -1 }, "vid", "must be >= 1" ],
		[ "network.devices.uc", "dev1", { type: "foo" }, "type", 'must be one of [ "bridge", "8021q", "8021ad", "macvlan", "veth", "tun", "tap" ]' ],
		[ "mwan3.interfaces.uc", "mwan", { size: -1 }, "size", "must be >= 1" ],
		[ "mwan3.interfaces.uc", "mwan", { interval: 5000 }, "interval", "must be <= 3600" ],
		[ "mwan3.interfaces.uc", "mwan", { flush_conntrack: [ "foo" ] }, "flush_conntrack[0]", 'must be one of [ "ifup", "ifdown", "connected", "disconnected", "never" ]' ],
		[ "openvpn.instances.uc", "vpn0", { port: -1 }, "port", "must be >= 1" ],
		[ "openvpn.instances.uc", "vpn0", { dev_type: "foo" }, "dev_type", 'must be one of [ "tun", "tap", null ]' ],
		[ "uhttpd.certs.uc", "px", { days: 0 }, "days", "must be >= 1" ],
		[ "prometheus_node_exporter_lua.config.uc", "main", { listen_port: -1 }, "listen_port", "must be >= 1" ],
		[ "firewall.nat.uc", "n1", { target: "FOO" }, "target", 'must be one of [ "SNAT", "MASQUERADE", "ACCEPT" ]' ],
		[ "firewall.rules.uc", "r1", { target: "FOO" }, "target", 'must be one of [ "ACCEPT", "REJECT", "DROP", "NOTRACK", "MARK", "DSCP" ]' ],
		[ "wireless.interfaces.uc", "w1", { mode: "foo" }, "mode", 'must be one of [ "ap", "sta", "adhoc", "wds", "monitor", "mesh" ]' ],
		[ "wireless.interfaces.uc", "w1", { mode: "ahdemo" }, "mode", 'must be one of [ "ap", "sta", "adhoc", "wds", "monitor", "mesh" ]' ],
		[ "wireless.devices.uc", "radio0", { type: "foo" }, "type", 'must be one of [ "mac80211", "broadcom" ]' ],
		[ "unbound.server.uc", "ub", { rebind_protection: "5" }, "rebind_protection", 'must be one of [ "0", "1", "2" ]' ],
		[ "dhcp.servers.uc", "s1", { dhcpv4: "foo" }, "dhcpv4", 'must be one of [ "disabled", "server", "relay", "hybrid" ]' ],
	];
	for (let row in MAIN)
		t.it(sprintf("%s %J", row[0], row[2]), () => {
			let c = filter(fx.CASES, (k) => k.file == row[0] && k.id == row[1])[0];
			let mod = loadfile('src/resources/' + row[0])();
			let h = c.singleton ? handler.make_singleton(mod, { tx }) : handler.make(mod, { tx });
			let conn = seeded(c, c.section);
			let r = c.singleton ? h.patch(conn, ctx, row[2]) : h.patch(conn, ctx, c.id, row[2]);
			t.assert_deep_equal(map(filter(r.body.errors ?? [], (e) => e.field == row[3]), (e) => e.message), [ row[4] ]);
		});
});

t.describe('system.hostname', () => {
	t.it('takes one trailing dot after a label, as LuCI does, and no empty label', () => {
		let r0 = resource("system.uc"), c = r0.c, h = r0.h;
		for (let name in [ "router.", "router.lan." ])
			t.assert_equal(status(h.patch(seeded(c, c.section), ctx, { hostname: name })), 200);
		for (let name in [ "router..", "a...", "a..b", ".a" ])
			t.assert_equal(h.patch(seeded(c, c.section), ctx, { hostname: name }).status, 422, name);
	});
});

t.describe('firewall/nat: an NPT rule', () => {
	t.it('keeps its snat_ip through a PATCH, a JSON Patch and a PUT of the read', () => {
		let r0 = resource("firewall.nat.uc"), c = r0.c, h = r0.h;
		let stored = () => seeded(c, { ...c.section, target: 'NPT', src_ip: 'fd00:1::/48', snat_ip: '2001:db8:1::/48' });
		let read = h.get_one(stored(), ctx, c.id).body;
		t.assert_equal(read.snat_ip, '2001:db8:1::/48');
		t.assert_equal(status(h.patch(stored(), ctx, c.id, { name: 'npt' })), 200);
		t.assert_equal(status(h.patch(stored(), { ...ctx, json_patch: true }, c.id,
		                              [ { op: "replace", path: "/name", value: "npt" } ])), 200);
		t.assert_equal(status(h.replace(stored(), ctx, c.id, strip(read))), 200);
	});
});

t.describe('firewall/rules: a stored HELPER target', () => {
	t.it('passes a PATCH that sends it back, and refuses a PUT, which drops its set_helper', () => {
		let r0 = resource("firewall.rules.uc"), c = r0.c, h = r0.h;
		let stored = () => seeded(c, { ...c.section, target: 'HELPER', set_helper: 'ftp' });
		let read = h.get_one(stored(), ctx, c.id).body;
		t.assert_equal(status(h.patch(stored(), ctx, c.id, { target: 'HELPER' })), 200);
		let r = h.replace(stored(), ctx, c.id, strip(read));
		t.assert_deep_equal(map(r.body.errors ?? [], (e) => e.field + ":" + e.code), [ "target:not_in_enum" ]);
	});
});

t.describe('wireless/interfaces: an EAP SSID without a key, as LuCI writes it', () => {
	t.it('takes a write that sends its encryption back, and needs a key to change it', () => {
		let r0 = resource("wireless.interfaces.uc"), c = r0.c, h = r0.h;
		let section = { ...c.section, mode: 'ap', encryption: 'wpa2', auth_server: '192.0.2.2' };
		delete section.key;
		let stored = () => seeded(c, section);
		let read = h.get_one(stored(), ctx, c.id).body;
		t.assert_equal(status(h.replace(stored(), ctx, c.id, strip(read))), 200);
		t.assert_equal(status(h.patch(stored(), ctx, c.id, { encryption: 'wpa2' })), 200);
		t.assert_equal(status(h.patch(stored(), ctx, c.id, { disabled: true })), 200);
		let r = h.patch(stored(), ctx, c.id, { encryption: 'wpa3' });
		t.assert_deep_equal(map(r.body.errors ?? [], (e) => e.field + ":" + e.code), [ "key:required" ]);
	});
});
