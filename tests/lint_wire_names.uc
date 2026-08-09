#!/usr/bin/ucode

// An API field whose name is not the uci option it writes. Two shapes hide here and only
// one is harmless.
//
// A rename is one API name for one uci key, spelled to the wire's conventions rather than
// uci's: `resource_limits` for uci's `resource`, `sys_location` for `sysLocation`. Those are
// deliberate and stay.
//
// An alias is two API names for the same uci key, which is the shape a major removes: it
// makes a read/write round-trip ambiguous, forces merge hooks to decide which name the
// caller meant, and cannot be expressed once request and response schemas split. Every one
// of these is already announced for v3, and this exists so a new one cannot arrive quietly
// after the announcement window closes.
//
// Local and deterministic on purpose. The dead-field audit needs a device because it greps
// the daemons; this needs only the source, so it runs on every commit instead.

import * as fs from 'fs';

function read(path) {
	let f = fs.open(path, "r");
	if (!f) die(sprintf("cannot read %s", path));
	let s = f.read("all") ?? "";
	f.close();
	return s;
}

// Reason as the value, so a waiver has to say why it is one.
const EXPECTED = {
	"dhcp.hosts.uc:macs":                 "alias of mac, announced for v3",
	"dhcp.hosts.uc:mac_aliases":          "alias of mac, announced for v3",
	"network.interfaces.uc:ipaddrs":      "alias of ipaddr, announced for v3",

	"dropbear.instances.uc:port":         "rename: uci spells it Port",
	"dropbear.instances.uc:banner_file":  "rename: uci spells it BannerFile",
	"dropbear.instances.uc:gateway_ports": "rename: uci spells it GatewayPorts",
	"dropbear.instances.uc:interface":    "rename: uci spells it Interface",
	"dropbear.instances.uc:password_auth": "rename: uci spells it PasswordAuth",
	"dropbear.instances.uc:root_login":   "rename: uci spells it RootLogin",
	"dropbear.instances.uc:root_password_auth": "rename: uci spells it RootPasswordAuth",

	"snmpd.system.uc:sys_contact":        "rename: uci spells it sysContact",
	"snmpd.system.uc:sys_descr":          "rename: uci spells it sysDescr",
	"snmpd.system.uc:sys_location":       "rename: uci spells it sysLocation",
	"snmpd.system.uc:sys_name":           "rename: uci spells it sysName",
	"snmpd.system.uc:sys_object_id":      "rename: uci spells it sysObjectID",
	"snmpd.system.uc:sys_services":       "rename: uci spells it sysService",

	"vnstat.config.uc:database_dir":      "rename: uci spells it DatabaseDir",
	"vnstat.config.uc:interface_5min_hours": "rename: uci spells it Interface5MinHours",
	"vnstat.config.uc:month_rotate":      "rename: uci spells it MonthRotate",
	"vnstat.config.uc:interfaces":        "rename: the uci option is the singular `interface` list",

	"unbound.server.uc:resource_limits":  "rename: `resource` is an HCL block keyword",
	"firewall.defaults.uc:output_policy": "rename: `output` collides with the chain name",
	"firewall.zones.uc:output_policy":    "rename: `output` collides with the chain name",
	"firewall.rules.uc:match":            "structured object flattened into src_port/dest_port and friends",
	"firewall.nat.uc:match":              "structured object flattened into src_port/dest_port and friends",
	"firewall.redirects.uc:match":        "structured object flattened into src_port/dest_port and friends",
	"mwan3.interfaces.uc:probe_count":    "rename: uci spells it count",
	"mwan3.policies.uc:use_members":      "rename: uci spells it use_member",
};

let dir = fs.opendir("src/resources");
let files = [];
for (let e = dir.read(); e != null; e = dir.read())
	if (substr(e, -3) == ".uc") push(files, e);
dir.close();

let problems = [], checked = 0;

for (let name in sort(files)) {
	let src = read("src/resources/" + name);

	let props = {};
	for (let m in match(src, /\n\t\t([a-z_][a-z0-9_]*):[ \t]*\{/g))
		props[m[1]] = true;

	let start = index(src, "\nfunction toUci(");
	if (start < 0) continue;
	let end = index(substr(src, start + 1), "\n}");
	if (end < 0) continue;
	let body = substr(src, start, end + 3);

	let written = {}, consumed = {};
	for (let m in match(body, /out[.\[]['"]?([A-Za-z_][A-Za-z0-9_]*)/g))
		written[m[1]] = true;
	for (let m in match(body, /json[.\[]['"]?([A-Za-z_][A-Za-z0-9_]*)/g))
		consumed[m[1]] = true;

	for (let p in sort(keys(props))) {
		if (!consumed[p] || written[p]) continue;
		checked++;
		let key = name + ":" + p;
		if (!exists(EXPECTED, key))
			push(problems, sprintf("%s: `%s` is read by toUci but never written under its own name, so it is an alias or a rename. Add it to EXPECTED with the reason, and if it is a second name for a key another field already writes, announce it for the next major first.", name, p));
	}
}

for (let key in EXPECTED) {
	let parts = split(key, ":");
	if (!fs.stat("src/resources/" + parts[0]))
		push(problems, sprintf("EXPECTED names %s, which no longer exists", parts[0]));
}

if (length(problems) > 0) {
	for (let p in problems) print(p + "\n");
	printf("FAIL: %d wire name(s) unaccounted for\n", length(problems));
	exit(1);
}

printf("OK: %d wire names that differ from their uci key, all accounted for\n", checked);
