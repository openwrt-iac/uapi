// The seeded uci state every resource-level property runs against: one case per writable
// resource, plus the sections those cases cross-reference. Shared because two properties
// need the identical corpus and a second copy would drift from the first.
//
// A seed must not set a field to the value fromUci would synthesize for it. Dropping that
// field then becomes invisible, since the re-read fills the default back in; the
// read-honesty suite enforces this with a test of its own.

const WG_KEY = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const WG_PUB = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';

function world() {
	return {
		network: {
			lan: { '.type': 'interface', '.anonymous': false, proto: 'static',
			       device: 'br-lan', ipaddr: ['192.168.1.1/24', '10.0.0.1/24'] },
			wan: { '.type': 'interface', '.anonymous': false, proto: 'dhcp', device: 'eth1' },
			wg0: { '.type': 'interface', '.anonymous': false, proto: 'wireguard',
			       private_key: WG_KEY, addresses: ['10.9.0.1/24'] },
			brprobe: { '.type': 'device', '.anonymous': false, name: 'br-probe',
			           type: 'bridge', ports: ['lan1'] },
		},
		firewall: {
			zlan: { '.type': 'zone', '.anonymous': false, name: 'lan',
			        input: 'ACCEPT', output: 'ACCEPT', forward: 'ACCEPT' },
			zwan: { '.type': 'zone', '.anonymous': false, name: 'wan',
			        input: 'REJECT', output: 'ACCEPT', forward: 'REJECT' },
		},
		wireless: {
			radio0: { '.type': 'wifi-device', '.anonymous': false, type: 'mac80211',
			          channel: '6', band: '2g' },
		},
		mwan3: {
			mwan: { '.type': 'interface', '.anonymous': false, family: 'ipv4',
			        enabled: '1', track_method: 'ping', reliability: '1' },
			m1: { '.type': 'member', '.anonymous': false, interface: 'mwan',
			      metric: '1', weight: '3' },
			pol1: { '.type': 'policy', '.anonymous': false, use_member: ['m1'],
			        last_resort: 'unreachable' },
		},
		snmpd: {
			g1: { '.type': 'group', '.anonymous': false, group: 'grp',
			      version: 'v2c', secname: 'ro' },
		},
		dhcp: {
			main: { '.type': 'dnsmasq', '.anonymous': false, domain: 'lan',
			        local: '/lan/', leasefile: '/tmp/dhcp.leases' },
		},
	};
}

const CASES = [
	{
		file: "firewall.zones.uc", id: "z1", pkg: "firewall",
		modify: { key: "input", value: "REJECT" },
		section: { '.type': 'zone', name: 'probez', input: 'DROP', output: 'DROP', forward: 'DROP' },
	},
	{
		file: "firewall.rules.uc", id: "r1", pkg: "firewall",
		modify: { key: "target", value: "REJECT" },
		section: { '.type': 'rule', target: 'ACCEPT', src: 'wan', proto: ['tcp'], dest_port: ['22'] },
	},
	{
		file: "firewall.redirects.uc", id: "d1", pkg: "firewall",
		section: { '.type': 'redirect', target: 'SNAT', src: 'wan', dest: 'lan',
		           src_dip: '10.0.0.5', src_dport: '8080' },
	},
	{
		file: "firewall.nat.uc", id: "n1", pkg: "firewall",
		section: { '.type': 'nat', target: 'SNAT', src: 'wan', snat_ip: '10.0.0.1' },
	},
	{
		file: "firewall.forwardings.uc", id: "f1", pkg: "firewall",
		section: { '.type': 'forwarding', src: 'lan', dest: 'wan' },
	},
	{
		file: "firewall.defaults.uc", id: "defaults", pkg: "firewall",
		singleton: true,
		modify: { key: "forward", value: "DROP" },
		section: { '.type': 'defaults', input: 'ACCEPT', output: 'ACCEPT', forward: 'REJECT' },
	},
	{
		file: "network.interfaces.uc", id: "lan", pkg: "network",
		modify: { key: "ipaddrs", value: ["192.168.78.1/24"] },
		section: { '.type': 'interface', proto: 'static', device: 'br-lan', ipaddr: ['192.168.1.1/24', '10.0.0.1/24'] },
	},
	{
		// A second network.interfaces case: the masked private_key is a different shape
		// from the mirrored ipaddr pair above, and only this one exercises it.
		file: "network.interfaces.uc", id: "wg0", pkg: "network",
		section: { '.type': 'interface', proto: 'wireguard', private_key: WG_KEY,
		           addresses: ['10.9.0.1/24', 'fd00:9::1/64'], listen_port: '51820' },
	},
	{
		file: "network.devices.uc", id: "dev1", pkg: "network",
		section: { '.type': 'device', name: 'eth9', type: '8021q', ifname: 'eth0', vid: '9' },
	},
	{
		file: "network.routes.uc", id: "rt1", pkg: "network",
		section: { '.type': 'route', interface: 'lan', target: '10.9.0.0/24', gateway: '192.168.1.254' },
	},
	{
		file: "network.rules.uc", id: "nr1", pkg: "network",
		section: { '.type': 'rule', src: '10.0.0.0/8', lookup: '42', priority: '100' },
	},
	{
		file: "network.bridge_vlans.uc", id: "bv1", pkg: "network",
		section: { '.type': 'bridge-vlan', device: 'br-probe', vlan: '7',
		           ports: ['lan1', 'lan2'] },
	},
	{
		file: "network.wireguard_peers.uc", id: "p1", pkg: "network",
		modify: { key: "allowed_ips", value: ["10.9.0.3/32"] },
		section: { '.type': 'wireguard_wg0', public_key: WG_PUB, allowed_ips: ['10.9.0.2/32', 'fd00:9::2/128'],
		           preshared_key: WG_KEY, endpoint_host: '198.51.100.7', endpoint_port: '51820' },
	},
	{
		file: "wireless.devices.uc", id: "radio0", pkg: "wireless",
		section: { '.type': 'wifi-device', type: 'mac80211', channel: '6', band: '2g' },
	},
	{
		file: "wireless.interfaces.uc", id: "w1", pkg: "wireless",
		modify: { key: "ssid", value: "home2" },
		section: { '.type': 'wifi-iface', device: 'radio0', ssid: 'home', encryption: 'psk2',
		           key: 'correcthorse', mode: 'sta' },
	},
	{
		file: "dhcp.hosts.uc", id: "h1", pkg: "dhcp",
		section: { '.type': 'host', mac: '00:11:22:33:44:55', ip: '192.168.1.50', tag: 'guest iot' },
	},
	{
		file: "dhcp.hosts.uc", id: "h2", pkg: "dhcp",
		modify: { key: "tag", value: ["guest", "iot", "lab"] },
		section: { '.type': 'host', mac: '00:11:22:33:44:66', ip: '192.168.1.51', tag: ['guest', 'iot'] },
	},
	{
		// A `list mac`, the shape no fixture carried: `mac` is its head and `mac_aliases`
		// the tail, so a single-valued seed cannot exercise the split at all.
		file: "dhcp.hosts.uc", id: "h3", pkg: "dhcp",
		section: { '.type': 'host', mac: ['00:11:22:33:44:77', 'aa:bb:cc:dd:ee:77'],
		           ip: '192.168.1.52' },
		// Two entries, so the modified list stays a list: a one-entry `macs` writes a
		// scalar uci option, which would exercise a different toUci branch than intended.
		modify: { key: "macs", value: ['00:11:22:33:44:78', 'aa:bb:cc:dd:ee:78'] },
	},
	{
		file: "dhcp.servers.uc", id: "s1", pkg: "dhcp",
		section: { '.type': 'dhcp', interface: 'lan', start: '100', limit: '150', leasetime: '12h' },
	},
	{
		file: "dhcp.dnsmasq.uc", id: "main", pkg: "dhcp",
		singleton: true,
		modify: { key: "domain", value: "probe" },
		section: { '.type': 'dnsmasq', domain: 'lan', local: '/lan/', leasefile: '/tmp/dhcp.leases' },
	},
	{
		file: "dhcp.odhcpd.uc", id: "odh", pkg: "dhcp",
		singleton: true,
		section: { '.type': 'odhcpd', maindhcp: '1', leasefile: '/tmp/hosts/odhcpd' },
	},
	{
		file: "system.uc", id: "cfg1", pkg: "system",
		singleton: true,
		modify: { key: "hostname", value: "router2" },
		section: { '.type': 'system', hostname: 'router', timezone: 'UTC', description: 'probe' },
	},
	{
		file: "system.timeservers.uc", id: "ntp", pkg: "system",
		section: { '.type': 'timeserver', server: ['0.pool.ntp.org', '1.pool.ntp.org'] },
	},
	{
		file: "dropbear.instances.uc", id: "db1", pkg: "dropbear",
		section: { '.type': 'dropbear', Port: '22', PasswordAuth: '1', RootLogin: '1' },
	},
	{
		file: "uhttpd.instances.uc", id: "main", pkg: "uhttpd",
		section: { '.type': 'uhttpd', listen_http: ['0.0.0.0:80', '[::]:80'], home: '/www',
		           ucode_prefix: ['/api/v2=/usr/share/uapi/main.uc',
		                          '/probe=/usr/share/uapi/main.uc'] },
	},
	{
		file: "uhttpd.certs.uc", id: "px", pkg: "uhttpd",
		section: { '.type': 'cert', commonname: 'router.lan', days: '730', bits: '2048' },
	},
	{
		file: "unbound.server.uc", id: "ub", pkg: "unbound",
		singleton: true,
		section: { '.type': 'unbound', enabled: '0', listen_port: '5353', recursion: 'default', resource: 'small', protocol: 'mixed' },
	},
	{
		file: "unbound.srv.uc", id: "srv", pkg: "unbound_srv",
		singleton: true,
		section: { '.type': 'unbound_srv', num_threads: '1' },
	},
	{
		file: "unbound.ext.uc", id: "ext", pkg: "unbound_ext",
		singleton: true,
		section: { '.type': 'unbound_ext', dnsmasq_gate_name: '0' },
	},
	{
		file: "sqm.queues.uc", id: "q1", pkg: "sqm",
		section: { '.type': 'queue', interface: 'lan', enabled: '0', download: '90000', upload: '10000', qdisc: 'cake', script: 'piece_of_cake.qos' },
	},
	{
		file: "snmpd.agents.uc", id: "ag1", pkg: "snmpd",
		section: { '.type': 'agent', agentaddress: 'UDP:161' },
	},
	{
		file: "snmpd.com2secs.uc", id: "c2s1", pkg: "snmpd",
		section: { '.type': 'com2sec', secname: 'ro', source: 'default', community: 'public' },
	},
	{
		file: "snmpd.groups.uc", id: "g1", pkg: "snmpd",
		section: { '.type': 'group', group: 'grp', version: 'v2c', secname: 'ro' },
	},
	{
		file: "snmpd.accesses.uc", id: "ac1", pkg: "snmpd",
		section: { '.type': 'access', group: 'grp', context: 'none', version: 'any', level: 'noauth', prefix: 'exact', read: 'all' },
	},
	{
		file: "snmpd.system.uc", id: "sys", pkg: "snmpd",
		singleton: true,
		section: { '.type': 'system', sysLocation: 'rack', sysContact: 'ops' },
	},
	{
		file: "lldpd.config.uc", id: "cfg", pkg: "lldpd",
		singleton: true,
		section: { '.type': 'lldpd', enable_lldp: '1', lldp_class: '4' },
	},
	{
		file: "prometheus_node_exporter_lua.config.uc", id: "main", pkg: "prometheus-node-exporter-lua",
		singleton: true,
		section: { '.type': 'prometheus-node-exporter-lua', listen_interface: 'lan', listen_port: '9100' },
	},
	{
		file: "vnstat.config.uc", id: "cfg", pkg: "vnstat",
		singleton: true,
		section: { '.type': 'vnstat', DatabaseDir: '/var/lib/vnstat' },
	},
	{
		file: "vnstat.interfaces.uc", id: "vi1", pkg: "vnstat",
		section: { '.type': 'interface', interface: 'lan' },
	},
	{
		file: "mwan3.globals.uc", id: "globals", pkg: "mwan3",
		singleton: true,
		section: { '.type': 'globals', mmx_mask: '0x3F00', rtmon_interval: '5' },
	},
	{
		file: "mwan3.interfaces.uc", id: "mwan", pkg: "mwan3",
		section: { '.type': 'interface', family: 'ipv4', enabled: '1', track_method: 'ping', reliability: '1' },
	},
	{
		file: "mwan3.members.uc", id: "m1", pkg: "mwan3",
		section: { '.type': 'member', interface: 'mwan', metric: '1', weight: '3' },
	},
	{
		file: "mwan3.policies.uc", id: "pol1", pkg: "mwan3",
		section: { '.type': 'policy', use_member: ['m1'], last_resort: 'unreachable' },
	},
	{
		file: "mwan3.rules.uc", id: "mr1", pkg: "mwan3",
		section: { '.type': 'rule', use_policy: 'pol1', proto: 'all', sticky: '1' },
	},
	{
		file: "usteer.config.uc", id: "cfg", pkg: "usteer",
		singleton: true,
		section: { '.type': 'usteer', network: 'default', syslog: '0' },
	},
	{
		file: "openvpn.instances.uc", id: "vpn0", pkg: "openvpn",
		modify: { key: "port", value: 1195 },
		section: { '.type': 'openvpn', enabled: '1', dev_type: 'tun', proto: 'udp', port: '1194', key: '/etc/openvpn/k.pem', tls_auth: '/etc/openvpn/ta.key' },
	},
];

return { WG_KEY, WG_PUB, world, CASES };
