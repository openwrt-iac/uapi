let t = require('harness');
let fs = require('fs');
let ph = loadfile('tests/property_harness.uc')();

// Walked rather than listed: the hand-kept list left unbound.srv and unbound.ext unfuzzed,
// though both are writable. A read-only collection, which main.uc tells by the same test when
// it leaves one out of /batch, has no validate() to fuzz. Any other module without one fails
// below, so the skip cannot widen in silence.
let RESOURCES = [];
let unfuzzable = [];
for (let file in sort(fs.lsdir('src/resources', '*.uc'))) {
	let r = loadfile('src/resources/' + file)();
	if (type(r.validate) == "function")
		push(RESOURCES, { name: substr(file, 0, -3), r });
	else if (r.toUci != null || r.list_fn == null)
		push(unfuzzable, file);
}

// PROPERTY_ITERS lets CI dial up coverage without slowing local `make test`.
// Local default is 200 per resource (sub-second total); CI runs at 1000+ via
// `make test-property`.
let ITERS = int(getenv("PROPERTY_ITERS") ?? "200");
if (ITERS < 1) ITERS = 200;

t.describe(sprintf("property: validate() is total across every resource (%d iter each)", ITERS), () => {
	t.it("every module but a read-only collection has a validate() to fuzz", () => {
		t.assert_deep_equal(unfuzzable, [], "modules with no validate() that are not read-only collections");
	});
	for (let entry in RESOURCES) {
		t.it(sprintf("%s: %d random bodies -> no throws", entry.name, ITERS), () => {
			let surprises = ph.check_validate_total(entry.r, ITERS, 0x9e3779b1);
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
			{ '.name': 'wan_bcast', '.anonymous': false, '.type': 'interface',
			  proto: 'dhcp', device: 'eth1', broadcast: '1', clientid: '01aabbccddeeff' },
			{ '.name': 'wan_ppp', '.anonymous': false, '.type': 'interface',
			  proto: 'pppoe', device: 'eth8', peerdns: '0', reqprefix: '56', sourcefilter: '0' },
			{ '.name': 'lan_core', '.anonymous': false, '.type': 'interface',
			  proto: 'static', device: 'br-core', ipaddr: ['10.0.7.1/24'], metric: '7',
			  defaultroute: '0', delegate: '0', ip4table: '4207' },
			{ '.name': 'lan_pfx', '.anonymous': false, '.type': 'interface',
			  proto: 'static', device: 'br-pfx', ip6addr: ['fd00:94::1/64'], ip6prefix: 'fd00:95::/48 fd00:96::/48' },
			{ '.name': 'wg_pfx1', '.anonymous': false, '.type': 'interface',
			  proto: 'wireguard', addresses: ['10.9.1.1/24'], ip6prefix: ['fd00:91::/48'] },
			{ '.name': 'wg_pfx2', '.anonymous': false, '.type': 'interface',
			  proto: 'wireguard', addresses: ['10.9.2.1/24'], ip6prefix: ['fd00:92::/48', 'fd00:93::/48'] },
			{ '.name': 'six_rd', '.anonymous': false, '.type': 'interface',
			  proto: '6rd', ip6prefix: '2001:db8::', ip6prefixlen: '32' },
			{ '.name': 'lan_hex', '.anonymous': false, '.type': 'interface',
			  proto: 'static', device: 'br-hex', ipaddr: '10.0.8.1/24 10.0.8.2/24', metric: '0x10',
			  mtu: '0x578', ip6weight: '010', dns: '192.0.2.1 192.0.2.2' },
		] },
		{ name: "network.routes", file: "network.routes.uc", fixtures: [
			{ '.name': 'r_hex', '.anonymous': false, '.type': 'route', interface: 'lan',
			  target: '10.8.0.0/24', table: 'local', metric: '0x10', mtu: '0x5dc' },
		] },
		{ name: "network.rules", file: "network.rules.uc", fixtures: [
			{ '.name': 'n_hex', '.anonymous': false, '.type': 'rule', src: '10.1.0.0/16',
			  lookup: 'main', priority: '0x7531' },
			{ '.name': 'n_goto', '.anonymous': false, '.type': 'rule', src: '10.2.0.0/16',
			  priority: '30040', 'goto': '30050' },
		] },
		{ name: "network.devices", file: "network.devices.uc", fixtures: [
			{ '.name': 'br_hex', '.anonymous': false, '.type': 'device', name: 'br-hex',
			  type: 'bridge', ports: 'lan3 lan4', mtu: '0x5dc' },
		] },
		{ name: "network.bridge_vlans", file: "network.bridge_vlans.uc", fixtures: [
			{ '.name': 'bv_hex', '.anonymous': false, '.type': 'bridge-vlan', device: 'br-hex',
			  vlan: '0x0a', ports: 'lan3:u* lan4:t' },
		] },
		{ name: "network.wireguard_peers", file: "network.wireguard_peers.uc", fixtures: [
			{ '.name': 'p_words', '.anonymous': false, '.type': 'wireguard_wg0',
			  public_key: 'TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=', allowed_ips: '10.9.0.4/32 10.9.1.0/24' },
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
