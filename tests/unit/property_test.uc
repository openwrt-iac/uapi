let t = require('harness');
let ph = loadfile('tests/property_harness.uc')();

const RESOURCES = [
	{ name: "firewall.zones",       file: "firewall.zones.uc" },
	{ name: "firewall.rules",       file: "firewall.rules.uc" },
	{ name: "firewall.redirects",   file: "firewall.redirects.uc" },
	{ name: "firewall.nat",         file: "firewall.nat.uc" },
	{ name: "firewall.forwardings", file: "firewall.forwardings.uc" },
	{ name: "firewall.defaults",    file: "firewall.defaults.uc" },
	{ name: "network.interfaces",   file: "network.interfaces.uc" },
	{ name: "network.devices",      file: "network.devices.uc" },
	{ name: "network.routes",       file: "network.routes.uc" },
	{ name: "network.rules",        file: "network.rules.uc" },
	{ name: "network.bridge_vlans", file: "network.bridge_vlans.uc" },
	{ name: "network.wireguard_peers", file: "network.wireguard_peers.uc" },
	{ name: "wireless.devices",     file: "wireless.devices.uc" },
	{ name: "wireless.interfaces",  file: "wireless.interfaces.uc" },
	{ name: "dhcp.hosts",           file: "dhcp.hosts.uc" },
	{ name: "dhcp.servers",         file: "dhcp.servers.uc" },
	{ name: "dhcp.dnsmasq",         file: "dhcp.dnsmasq.uc" },
	{ name: "dhcp.odhcpd",          file: "dhcp.odhcpd.uc" },
	{ name: "system",               file: "system.uc" },
	{ name: "system.timeservers",   file: "system.timeservers.uc" },
	{ name: "dropbear.instances",   file: "dropbear.instances.uc" },
	{ name: "uhttpd.instances",     file: "uhttpd.instances.uc" },
	{ name: "uhttpd.certs",         file: "uhttpd.certs.uc" },
	{ name: "unbound.server",       file: "unbound.server.uc" },
	{ name: "sqm.queues",           file: "sqm.queues.uc" },
	{ name: "snmpd.agents",         file: "snmpd.agents.uc" },
	{ name: "snmpd.com2secs",       file: "snmpd.com2secs.uc" },
	{ name: "snmpd.groups",         file: "snmpd.groups.uc" },
	{ name: "snmpd.accesses",       file: "snmpd.accesses.uc" },
	{ name: "snmpd.system",         file: "snmpd.system.uc" },
	{ name: "lldpd.config",         file: "lldpd.config.uc" },
	{ name: "prometheus_node_exporter_lua.config", file: "prometheus_node_exporter_lua.config.uc" },
	{ name: "vnstat.config",        file: "vnstat.config.uc" },
	{ name: "vnstat.interfaces",    file: "vnstat.interfaces.uc" },
	{ name: "mwan3.globals",        file: "mwan3.globals.uc" },
	{ name: "mwan3.interfaces",     file: "mwan3.interfaces.uc" },
	{ name: "mwan3.members",        file: "mwan3.members.uc" },
	{ name: "mwan3.policies",       file: "mwan3.policies.uc" },
	{ name: "mwan3.rules",          file: "mwan3.rules.uc" },
	{ name: "usteer.config",        file: "usteer.config.uc" },
	{ name: "openvpn.instances",    file: "openvpn.instances.uc" },
	{ name: "unbound.srv",          file: "unbound.srv.uc" },
	{ name: "unbound.ext",          file: "unbound.ext.uc" },
];

// PROPERTY_ITERS lets CI dial up coverage without slowing local `make test`.
// Local default is 200 per resource (sub-second total); CI runs at 1000+ via
// `make test-property`.
let ITERS = int(getenv("PROPERTY_ITERS") ?? "200");
if (ITERS < 1) ITERS = 200;

t.describe(sprintf("property: validate() is total across every resource (%d iter each)", ITERS), () => {
	for (let entry in RESOURCES) {
		t.it(sprintf("%s: %d random bodies -> no throws", entry.name, ITERS), () => {
			let r = loadfile('src/resources/' + entry.file)();
			let surprises = ph.check_validate_total(r, ITERS, 0x9e3779b1);
			if (length(surprises) > 0) {
				t.assert_equal(sprintf("first surprise: %J", surprises[0]),
				               "(no surprises)");
			}
			t.assert_equal(length(surprises), 0);
		});
	}
});

t.describe('property: fromUci -> toUci -> fromUci is stable', () => {
	let cases = [
		{ name: "firewall.zones", file: "firewall.zones.uc", fixtures: [
			{ '.name': 'z_lan', '.anonymous': false, '.type': 'zone',
			  name: 'lan', input: 'ACCEPT', output: 'ACCEPT', forward: 'REJECT',
			  network: ['lan'] },
		] },
		{ name: "firewall.redirects", file: "firewall.redirects.uc", fixtures: [
			{ '.name': 'r1', '.anonymous': false, '.type': 'redirect',
			  target: 'DNAT', enabled: '1', src: 'wan', dest: 'lan',
			  src_dport: '443', dest_ip: '192.168.1.10', dest_port: '443',
			  proto: ['tcp'], reflection: '1', reflection_src: 'internal' },
		] },
		{ name: "dhcp.hosts", file: "dhcp.hosts.uc", fixtures: [
			{ '.name': 'h1', '.anonymous': false, '.type': 'host',
			  name: 'laptop', mac: 'aa:bb:cc:dd:ee:ff', ip: '192.168.1.42',
			  leasetime: '12h', dns: '1' },
			{ '.name': 'h2', '.anonymous': false, '.type': 'host',
			  name: 'multi', mac: ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'],
			  ip: '192.168.1.43' },
			{ '.name': 'h3', '.anonymous': false, '.type': 'host',
			  duid: '0001000123456789aabb', ip: 'fd42::42' },
		] },
		{ name: "network.interfaces", file: "network.interfaces.uc", fixtures: [
			{ '.name': 'lan', '.anonymous': false, '.type': 'interface',
			  proto: 'static', device: 'br-lan',
			  ipaddr: '192.168.1.1', netmask: '255.255.255.0' },
			{ '.name': 'loopback', '.anonymous': false, '.type': 'interface',
			  proto: 'static', device: 'lo',
			  ipaddr: ['127.0.0.1/8'] },
			{ '.name': 'wan', '.anonymous': false, '.type': 'interface',
			  proto: 'dhcp', device: 'eth1',
			  peerdns: '0', defaultroute: '1', metric: '50', hostname: 'router' },
		] },
		{ name: "unbound.server", file: "unbound.server.uc", fixtures: [
			{ '.name': 'ub_main', '.type': 'unbound',
			  enabled: '1', listen_port: '5353', recursion: 'default',
			  resource: 'small', protocol: 'mixed', dnssec_enabled: '1',
			  manual_conf: '0', interface_auto: '1', localservice: '1' },
		] },
		{ name: "dropbear.instances", file: "dropbear.instances.uc", fixtures: [
			{ '.name': 'd1', '.anonymous': false, '.type': 'dropbear',
			  Port: '22', PasswordAuth: '1', RootPasswordAuth: '0', RootLogin: '1' },
		] },
		{ name: "sqm.queues", file: "sqm.queues.uc", fixtures: [
			{ '.name': 'q_wan', '.anonymous': false, '.type': 'queue',
			  interface: 'wan', enabled: '1', download: '90000', upload: '10000',
			  qdisc: 'cake', script: 'piece_of_cake.qos', linklayer: 'ethernet',
			  overhead: '22' },
		] },
	];

	for (let c in cases) {
		t.it(sprintf("%s: round-trip preserves shape", c.name), () => {
			let r = loadfile('src/resources/' + c.file)();
			let surprises = ph.check_round_trip(r, c.fixtures);
			if (length(surprises) > 0) {
				t.assert_equal(sprintf("first surprise: %J", surprises[0]),
				               "(round-trip stable)");
			}
			t.assert_equal(length(surprises), 0);
		});
	}
});
