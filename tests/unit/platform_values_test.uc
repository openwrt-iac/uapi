let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let fx = require('resource_fixtures');

// A value that LuCI writes or that the daemon takes is no error of the section: it takes a PATCH of
// another field, and the sweep does not list it. Each row stores one such value in the fixture case
// of its resource: [ module, fixture id, uci option, stored value, field that the read gives, and
// the options that the case lacks ].
const ROWS = [
	[ "firewall.defaults.uc", "defaults", "input", "accept", "input" ],
	[ "firewall.defaults.uc", "defaults", "synflood_burst", "0", "synflood_burst" ],
	[ "firewall.defaults.uc", "defaults", "synflood_rate", "2000000", "synflood_rate" ],
	[ "firewall.defaults.uc", "defaults", "synflood_rate", "25/s", "synflood_rate" ],
	[ "firewall.defaults.uc", "defaults", "synflood_rate", "! 5/h", "synflood_rate" ],
	[ "firewall.zones.uc", "z1", "output", "rej", "output_policy" ],
	[ "firewall.zones.uc", "z1", "family", "inet", "family" ],
	[ "firewall.zones.uc", "z1", "name", "pro.be", "name" ],
	[ "firewall.forwardings.uc", "f1", "family", "all", "family" ],
	[ "firewall.nat.uc", "n1", "target", "snat", "target" ],
	[ "firewall.nat.uc", "n1", "target", "NPT", "target", { snat_ip: "2001:db8:1::/48", src_ip: "2001:db8:2::/48" } ],
	[ "firewall.nat.uc", "n1", "family", "*", "match.family" ],
	[ "firewall.nat.uc", "n1", "src_port", "! 1024", "match.src_port" ],
	[ "firewall.nat.uc", "n1", "mark", "! 0x10", "match.mark" ],
	[ "firewall.nat.uc", "n1", "proto", "tcp udp", "match.proto" ],
	[ "firewall.redirects.uc", "d1", "target", "snat", "target" ],
	[ "firewall.redirects.uc", "d1", "reflection_src", "ext", "reflection_src" ],
	[ "firewall.redirects.uc", "d1", "src_dport", " ! 8080", "match.src_dport" ],
	[ "firewall.rules.uc", "r1", "target", "acc", "target" ],
	[ "firewall.rules.uc", "r1", "dest_port", "22 443", "match.dest_port" ],
	[ "firewall.rules.uc", "r1", "proto", "tcp udp", "match.proto" ],
	[ "firewall.rules.uc", "r1", "dscp", "! EF", "match.dscp" ],
	[ "network.interfaces.uc", "lan", "metric", "-1", "metric" ],
	[ "network.interfaces.uc", "lan", "ip6weight", "-5", "ip6weight" ],
	[ "network.interfaces.uc", "wan6", "reqprefix", "56:1a", "reqprefix" ],
	[ "network.interfaces.uc", "wan6", "clientid", "00-03-00-01", "clientid" ],
	[ "network.devices.uc", "dev1", "vid", "0", "vid" ],
	[ "network.devices.uc", "dev1", "macaddr", "2:0:0:0:0:1", "macaddr" ],
	[ "network.devices.uc", "dev2", "type", "bonding", "type" ],
	[ "network.bridge_vlans.uc", "bv1", "ports", "lan.1:t", "ports" ],
	[ "network.routes.uc", "rt1", "type", "6", "type" ],
	[ "network.routes.uc", "rt1", "type", "010", "type" ],
	[ "network.routes.uc", "rt1", "metric", "-1", "metric" ],
	[ "network.routes.uc", "rt1", "mtu", "-1", "mtu" ],
	[ "network.rules.uc", "nr1", "priority", "40000", "priority" ],
	[ "network.rules.uc", "nr1", "ipproto", "06", "ipproto" ],
	[ "network.rules.uc", "nr1", "ipproto", "tcp", "ipproto" ],
	[ "network.rules.uc", "nr1", "uidrange", "1000-1005x", "uidrange" ],
	[ "network.rules.uc", "nr1", "suppress_prefixlength", "40", "suppress_prefixlength" ],
	[ "wireless.devices.uc", "radio0", "type", "qcawifi", "type" ],
	[ "wireless.devices.uc", "radio0", "txpower", "31", "txpower" ],
	[ "wireless.devices.uc", "radio0", "channel", "240", "channel" ],
	[ "wireless.interfaces.uc", "w1", "mode", "ahdemo", "mode" ],
	[ "wireless.interfaces.uc", "w1", "mode", "wds", "mode" ],
	[ "wireless.interfaces.uc", "w1", "encryption", "sae-compat", "encryption" ],
	[ "wireless.interfaces.uc", "w1", "encryption", "psk3", "encryption" ],
	[ "wireless.interfaces.uc", "w1", "encryption", "psk3-mixed", "encryption" ],
	[ "wireless.interfaces.uc", "w1", "encryption", "wpa-mixed", "encryption" ],
	[ "wireless.interfaces.uc", "w1", "device", [ "radio0", "radio1" ], "device" ],
	[ "wireless.interfaces.uc", "w1", "network", [ "lan", "guest" ], "network" ],
	[ "mwan3.globals.uc", "globals", "mmx_mask", "16128", "mmx_mask" ],
	[ "mwan3.globals.uc", "globals", "mmx_mask", "0x000003F00", "mmx_mask" ],
	[ "mwan3.globals.uc", "globals", "mmx_mask", "037400", "mmx_mask" ],
	[ "mwan3.globals.uc", "globals", "loglevel", "warning", "loglevel" ],
	[ "mwan3.globals.uc", "globals", "loglevel", "panic", "loglevel" ],
	[ "mwan3.globals.uc", "globals", "loglevel", "3", "loglevel" ],
	[ "mwan3.interfaces.uc", "mwan", "track_method", "nslookup", "track_method" ],
	[ "mwan3.interfaces.uc", "mwan", "count", "20", "probe_count" ],
	[ "mwan3.interfaces.uc", "mwan", "size", "0", "size" ],
	[ "mwan3.interfaces.uc", "mwan", "failure_loss", "200", "failure_loss" ],
	[ "mwan3.interfaces.uc", "mwan", "recovery_latency", "0", "recovery_latency" ],
	[ "mwan3.interfaces.uc", "mwan", "timeout", "100", "timeout" ],
	[ "mwan3.interfaces.uc", "mwan", "interval", "0", "interval" ],
	[ "mwan3.interfaces.uc", "mwan", "recovery_interval", "7200", "recovery_interval" ],
	[ "mwan3.interfaces.uc", "mwan", "flush_conntrack", [ "always" ], "flush_conntrack" ],
	[ "mwan3.members.uc", "m1", "metric", "0", "metric" ],
	[ "mwan3.members.uc", "m1", "weight", "5000", "weight" ],
	[ "mwan3.rules.uc", "mr1", "proto", "esp", "proto" ],
	[ "mwan3.rules.uc", "mr1", "proto", "0x11", "proto" ],
	[ "mwan3.rules.uc", "mr1", "proto", "0377", "proto" ],
	[ "mwan3.rules.uc", "mr1", "family", "any", "family" ],
	[ "mwan3.rules.uc", "mr1", "timeout", "2000000", "timeout" ],
	[ "openvpn.instances.uc", "vpn0", "dev_type", "null", "dev_type" ],
	[ "openvpn.instances.uc", "vpn0", "port", "0", "port" ],
	[ "openvpn.instances.uc", "vpn0", "ping", "0", "ping" ],
	[ "openvpn.instances.uc", "vpn0", "compress", "frames_only", "compress" ],
	[ "openvpn.instances.uc", "vpn0", "verb", "20", "verb" ],
	[ "prometheus_node_exporter_lua.config.uc", "main", "listen_port", "0", "listen_port" ],
	[ "sqm.queues.uc", "q1", "qdisc", "sfq", "qdisc" ],
	[ "sqm.queues.uc", "q1", "script", "simplest_tbf.qos", "script" ],
	[ "usteer.config.uc", "cfg", "debug_level", "5", "debug_level" ],
	[ "usteer.config.uc", "cfg", "max_neighbor_reports", "1000", "max_neighbor_reports" ],
	[ "dhcp.dnsmasq.uc", "main", "port", "0", "port" ],
	[ "dhcp.dnsmasq.uc", "main", "cachesize", "5000000", "cachesize" ],
	[ "dhcp.odhcpd.uc", "odhcpd", "loglevel", "8", "loglevel" ],
	[ "dhcp.servers.uc", "s1", "leasetime", "infinite", "leasetime" ],
	[ "dhcp.servers.uc", "s1", "leasetime", "deprecated", "leasetime" ],
	[ "dhcp.servers.uc", "s1", "leasetime", "12H", "leasetime" ],
	[ "dhcp.servers.uc", "s1", "limit", "1000", "limit" ],
	[ "dhcp.servers.uc", "s1", "ra_default", "5", "ra_default" ],
	[ "dhcp.servers.uc", "s1", "dhcpv4", "on", "dhcpv4" ],
	[ "dropbear.instances.uc", "db1", "Port", "0", "port" ],
	[ "system.uc", "cfg1", "hostname", "my router", "hostname" ],
	[ "uhttpd.certs.uc", "px", "days", "40000", "days" ],
	[ "uhttpd.certs.uc", "px", "days", "0", "days" ],
	[ "uhttpd.certs.uc", "px", "country", "ZZZ", "country" ],
	[ "uhttpd.instances.uc", "main", "http_keepalive", "-1", "http_keepalive" ],
	[ "unbound.server.uc", "ub", "rebind_protection", "3", "rebind_protection" ],
	[ "unbound.server.uc", "ub", "num_threads", "128", "num_threads" ],
	[ "unbound.server.uc", "ub", "add_local_fqdn", "5", "add_local_fqdn" ],
	[ "unbound.server.uc", "ub", "ttl_min", "90000", "ttl_min" ],
	[ "snmpd.accesses.uc", "ac1", "level", "authpriv", "level", { write: 'none', notify: 'none' } ],
	[ "snmpd.accesses.uc", "ac1", "prefix", "0", "prefix", { write: 'none', notify: 'none' } ],
	[ "snmpd.groups.uc", "g1", "version", "any", "version" ],
	[ "snmpd.system.uc", "sys", "sysService", "200", "sys_services" ],
];

let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null,
           wg_apply: () => null, wg_reconcile: () => null };
let ctx = { request_id: "01hx0000000000000000000000" };

// A PATCH that sends back the stored value of the first other boolean, which writes nothing and
// still runs every check over the section.
function other_field(mod, read, field) {
	for (let k, s in mod.schema_properties)
		if (k != field && type(s) == "object" && s.type == "boolean" && !s.readOnly && read[k] != null)
			return { [k]: read[k] };
	return {};
}

function seed(row) {
	let file = row[0], id = row[1], option = row[2], value = row[3], extra = row[5];
	let c = filter(fx.CASES, (k) => k.file == file && k.id == id)[0];
	let uci = fx.world();
	if (uci[c.pkg] == null) uci[c.pkg] = {};
	uci[c.pkg][c.id] = { '.anonymous': false, ...c.section, ...(extra ?? {}), [option]: value };
	let mod = loadfile('src/resources/' + file)();
	let h = c.singleton ? handler.make_singleton(mod, { tx }) : handler.make(mod, { tx });
	return { c, mod, h, conn: ubus.stub({ uci: uci }) };
}

function read_of(s) {
	return s.c.singleton ? s.h.get(s.conn, ctx).body : s.h.get_one(s.conn, ctx, s.c.id).body;
}

t.describe('property: a value that the platform takes is no error of the section', () => {
	for (let row in ROWS) {
		let option = row[2], value = row[3], field = row[4];
		t.it(sprintf("%s %s %J", row[0], option, value), () => {
			let s = seed(row);
			let mine = (e) => e.field == field || index(e.field, field + "[") == 0 || index(e.field, field + ".") == 0;
			for (let sw in s.h.sweep(s.conn))
				t.assert_deep_equal(filter(sw.errors, mine), [], sprintf("swept %J", sw.errors));
			let body = other_field(s.mod, read_of(s), field);
			let r = s.c.singleton ? s.h.patch(s.conn, ctx, body) : s.h.patch(s.conn, ctx, s.c.id, body);
			t.assert_equal(r.status, 200, sprintf("%J", r.body));
			t.assert_deep_equal(s.conn._state.uci[s.c.pkg][s.c.id][option], value);
		});
	}
});

// A client that writes back what it read, as the Terraform provider does with a PUT, sends each such
// value back, and a write refuses only a value that it changes.
t.describe('property: a write of the read passes with each value that the platform takes', () => {
	let at = (o, path) => { for (let p in split(path, ".")) o = o?.[p]; return o; };
	for (let row in ROWS) {
		t.it(sprintf("%s %s %J", row[0], row[2], row[3]), () => {
			let s = seed(row);
			let read = read_of(s);
			let body = {};
			for (let k, v in read)
				if (s.mod.schema_properties[k]?.readOnly !== true) body[k] = v;
			let r = s.c.singleton ? s.h.patch(s.conn, ctx, body) : s.h.replace(s.conn, ctx, s.c.id, body);
			t.assert_equal(r.status, 200, sprintf("%J", r.body));
			t.assert_deep_equal(at(read_of(s), row[4]), at(read, row[4]));
		});
	}
});

// libxtables reads an mwan3 protocol number with base 0, and LuCI's hostname() needs a letter or a
// digit before a trailing dot.
t.describe('a request takes what iptables and LuCI take, and refuses the rest', () => {
	let rule = (p) => { let s = seed([ "mwan3.rules.uc", "mr1", "proto", "tcp" ]); return s.h.patch(s.conn, ctx, s.c.id, { proto: p }).status; };
	let host = (n) => { let s = seed([ "system.uc", "cfg1", "hostname", "router" ]); return s.h.patch(s.conn, ctx, { hostname: n }).status; };
	t.it('an mwan3 rule protocol', () => {
		for (let p in [ "255", "010", "0377", "0300", "0x11", "0XfF", "0x00ff" ]) t.assert_equal(rule(p), 200, p);
		for (let p in [ "08", "09", "099", "0400", "0x100", "0x", "256" ]) t.assert_equal(rule(p), 422, p);
	});
	t.it('a hostname', () => {
		t.assert_equal(host("router."), 200);
		for (let n in [ "router..", "a...", ".router" ]) t.assert_equal(host(n), 422, n);
	});
});
