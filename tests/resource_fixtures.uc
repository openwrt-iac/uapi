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
		section: { family: 'ipv4', masq: '1', mtu_fix: '1', '.type': 'zone', name: 'probez', input: 'DROP', output: 'DROP', forward: 'DROP' },
	},
	{
		file: "firewall.rules.uc", id: "r1", pkg: "firewall",
		modify: { key: "target", value: "REJECT" },
		section: { enabled: '0', '.type': 'rule', target: 'ACCEPT', src: 'wan', proto: ['tcp'], dest_port: ['22'] },
	},
	{
		file: "firewall.redirects.uc", id: "d1", pkg: "firewall",
		section: { enabled: '0', '.type': 'redirect', target: 'SNAT', src: 'wan', dest: 'lan',
		           src_dip: '10.0.0.5', src_dport: '8080' },
	},
	{
		file: "firewall.nat.uc", id: "n1", pkg: "firewall",
		section: { enabled: '0', '.type': 'nat', target: 'SNAT', src: 'wan', snat_ip: '10.0.0.1' },
	},
	{
		file: "firewall.forwardings.uc", id: "f1", pkg: "firewall",
		section: { family: 'ipv4', enabled: '0', '.type': 'forwarding', src: 'lan', dest: 'wan' },
	},
	{
		file: "firewall.defaults.uc", id: "defaults", pkg: "firewall",
		singleton: true,
		modify: { key: "forward", value: "DROP" },
		section: { syn_flood: '1', drop_invalid: '1', tcp_syncookies: '1', flow_offloading: '1', flow_offloading_hw: '1', '.type': 'defaults', input: 'ACCEPT', output: 'ACCEPT', forward: 'REJECT' },
	},
	{
		file: "network.interfaces.uc", id: "lan", pkg: "network",
		modify: { key: "ipaddrs", value: ["192.168.78.1/24"] },
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'static', device: 'br-lan', ipaddr: ['192.168.1.1/24', '10.0.0.1/24'], broadcast: '192.168.1.255',
		           ip6assign: '64', ip6hint: '5', ip6ifaceid: '::5', ip6class: ['local'], ip6weight: '10' },
	},
	{
		// A routed ip6prefix on a dhcpv6 uplink needs sourcefilter '0', or its downstream /64s
		// get no default route.
		file: "network.interfaces.uc", id: "wan6", pkg: "network",
		modify: { key: "sourcefilter", value: true },
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'dhcpv6', device: 'eth8',
		           reqprefix: 'auto', ip6prefix: 'fd00:cafe::/61', sourcefilter: '0' },
	},
	{
		// A static interface addressed only over IPv6, which uci and LuCI both accept and
		// which nothing here covered: modelling only the v4 list made it read back with no
		// addresses and refused its own body on write.
		file: "network.interfaces.uc", id: "v6only", pkg: "network",
		modify: { key: "ip6addrs", value: ["fd00:db8::2/64"] },
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'static', device: 'eth7',
		           ip6addr: ['fd00:db8::1/64'], ip6gw: 'fd00:db8::ffff', ip6prefix: 'fd00:beef::/48' },
	},
	{
		// A second network.interfaces case: the masked private_key is a different shape
		// from the mirrored ipaddr pair above, and only this one exercises it.
		file: "network.interfaces.uc", id: "wg0", pkg: "network",
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'wireguard', private_key: WG_KEY,
		           addresses: ['10.9.0.1/24', 'fd00:9::1/64'], listen_port: '51820' },
	},
	{
		// LuCI's wireguard form writes ip6prefix as a list, even with one prefix.
		file: "network.interfaces.uc", id: "wg_pfx1", pkg: "network",
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'wireguard', private_key: WG_KEY,
		           addresses: ['10.9.1.1/24'], ip6prefix: ['fd00:91::/48'] },
	},
	{
		file: "network.interfaces.uc", id: "wg_pfx2", pkg: "network",
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'wireguard', private_key: WG_KEY,
		           addresses: ['10.9.2.1/24'], ip6prefix: ['fd00:92::/48', 'fd00:93::/48'] },
	},
	{
		// The core options netifd reads for every proto, which uapi once read only on dhcp,
		// dhcpv6 or wireguard.
		file: "network.interfaces.uc", id: "lan_core", pkg: "network",
		modify: { key: "metric", value: 9 },
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'static', device: 'br-core',
		           ipaddr: ['10.0.7.1/24'], metric: '7', defaultroute: '0', delegate: '0',
		           ip4table: '4207', dns: ['192.0.2.53', '192.0.2.54'] },
	},
	{
		// LuCI writes uci `broadcast` as a flag on proto dhcp.
		file: "network.interfaces.uc", id: "wan_bcast", pkg: "network",
		modify: { key: "broadcast_flag", value: false },
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'dhcp', device: 'eth8',
		           broadcast: '1', clientid: '01aabbccddeeff' },
	},
	{
		file: "network.interfaces.uc", id: "wan_ppp", pkg: "network",
		modify: { key: "reqprefix", value: "auto" },
		section: { auto: '0', disabled: '1', '.type': 'interface', proto: 'pppoe', device: 'eth8',
		           peerdns: '0', reqprefix: '56', sourcefilter: '0', mtu: '1492' },
	},
	{
		file: "network.devices.uc", id: "dev1", pkg: "network",
		section: { ipv6: '0', '.type': 'device', name: 'eth9', type: '8021q', ifname: 'eth0', vid: '9' },
	},
	{
		file: "network.routes.uc", id: "rt1", pkg: "network",
		section: { type: 'blackhole', '.type': 'route', interface: 'lan', target: '10.9.0.0/24', gateway: '192.168.1.254',
		           disabled: '1' },
	},
	{
		file: "network.rules.uc", id: "nr1", pkg: "network",
		section: { action: 'unreachable', invert: '1', '.type': 'rule', src: '10.0.0.0/8', lookup: '42', priority: '100',
		           disabled: '1' },
	},
	{
		file: "network.bridge_vlans.uc", id: "bv1", pkg: "network",
		section: { '.type': 'bridge-vlan', device: 'br-probe', vlan: '7',
		           ports: ['lan1', 'lan2'] },
	},
	{
		file: "network.wireguard_peers.uc", id: "p1", pkg: "network",
		modify: { key: "allowed_ips", value: ["10.9.0.3/32"] },
		section: { route_allowed_ips: '1', disabled: '1', '.type': 'wireguard_wg0', public_key: WG_PUB, allowed_ips: ['10.9.0.2/32', 'fd00:9::2/128'],
		           preshared_key: WG_KEY, endpoint_host: '198.51.100.7', endpoint_port: '51820' },
	},
	{
		// The forms netifd and wireguard.sh read beyond plain decimals and lists: a table alias,
		// hex integers, and scalars holding several words.
		file: "network.routes.uc", id: "rt2", pkg: "network",
		section: { type: 'blackhole', '.type': 'route', interface: 'lan', target: '10.8.0.0/24', table: 'local',
		           metric: '0x10', mtu: '0x5dc', disabled: '1' },
	},
	{
		file: "network.rules.uc", id: "nr2", pkg: "network",
		section: { action: 'goto', invert: '1', '.type': 'rule', src: '10.1.0.0/16', lookup: 'main',
		           priority: '0x7531', 'goto': '0x7532', disabled: '1' },
	},
	{
		// The goto rule LuCI writes: a goto and no action.
		file: "network.rules.uc", id: "nr3", pkg: "network",
		section: { invert: '1', '.type': 'rule', src: '10.2.0.0/16', priority: '30040', 'goto': '30050', disabled: '1' },
	},
	{
		// Without a priority, any goto from 1 up passes validate(), which the request bound needs.
		file: "network.rules.uc", id: "nr4", pkg: "network",
		section: { invert: '1', '.type': 'rule', src: '10.3.0.0/16', 'goto': '7', disabled: '1' },
	},
	{
		file: "network.devices.uc", id: "dev2", pkg: "network",
		section: { ipv6: '0', '.type': 'device', name: 'br-hex', type: 'bridge', ports: 'lan3 lan4', mtu: '0x5dc' },
	},
	{
		file: "network.bridge_vlans.uc", id: "bv2", pkg: "network",
		section: { '.type': 'bridge-vlan', device: 'br-probe', vlan: '0x0a', ports: 'lan1:u* lan2:t' },
	},
	{
		file: "network.wireguard_peers.uc", id: "p2", pkg: "network",
		section: { route_allowed_ips: '1', disabled: '1', '.type': 'wireguard_wg0',
		           public_key: 'TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=', allowed_ips: '10.9.0.4/32 10.9.1.0/24' },
	},
	{
		file: "wireless.devices.uc", id: "radio0", pkg: "wireless",
		section: { disabled: '1', '.type': 'wifi-device', type: 'mac80211', channel: '6', band: '2g' },
	},
	{
		file: "wireless.interfaces.uc", id: "w1", pkg: "wireless",
		modify: { key: "ssid", value: "home2" },
		section: { disabled: '1', hidden: '1', isolate: '1', '.type': 'wifi-iface', device: 'radio0', ssid: 'home', encryption: 'psk2',
		           key: 'correcthorse', mode: 'sta' },
	},
	{
		file: "dhcp.hosts.uc", id: "h1", pkg: "dhcp",
		// A scalar match_tag, which dnsmasq's config_list_foreach skips: it reads as null and
		// a write-back must leave it as it is.
		section: { dns: '1', '.type': 'host', mac: '00:11:22:33:44:55', ip: '192.168.1.50', tag: 'guest iot',
		           match_tag: 'ipxe' },
	},
	{
		file: "dhcp.hosts.uc", id: "h2", pkg: "dhcp",
		modify: { key: "tag", value: ["guest", "iot", "lab"] },
		section: { dns: '1', '.type': 'host', mac: '00:11:22:33:44:66', ip: '192.168.1.51', tag: ['guest', 'iot'] },
	},
	{
		// A `list mac`: more than one MAC on one reservation, which a single-valued
		// seed cannot exercise.
		file: "dhcp.hosts.uc", id: "h3", pkg: "dhcp",
		section: { dns: '1', '.type': 'host', mac: ['00:11:22:33:44:77', 'aa:bb:cc:dd:ee:77'],
		           ip: '192.168.1.52' },
		// Two entries, so the modified list stays a list: a one-entry `macs` writes a
		// scalar uci option, which would exercise a different toUci branch than intended.
		modify: { key: "macs", value: ['00:11:22:33:44:78', 'aa:bb:cc:dd:ee:78'] },
	},
	{
		// A `list match_tag`, modified down to one tag, which still has to stay a list: a
		// scalar would stop dnsmasq applying it.
		file: "dhcp.hosts.uc", id: "h4", pkg: "dhcp",
		section: { dns: '1', '.type': 'host', mac: '00:11:22:33:44:88', ip: '192.168.1.53', match_tag: ['ipxe', '!guest'] },
		modify: { key: "match_tag", value: ['ipxe'] },
	},
	{
		file: "dhcp.servers.uc", id: "s1", pkg: "dhcp",
		section: { ignore: '1', force: '1', dynamicdhcp: '0', '.type': 'dhcp', interface: 'lan', start: '100', limit: '150', leasetime: '12h' },
	},
	{
		file: "dhcp.dnsmasq.uc", id: "main", pkg: "dhcp",
		singleton: true,
		modify: { key: "domain", value: "probe" },
		section: { noresolv: '1', rebind_protection: '0', expandhosts: '1', domainneeded: '0', boguspriv: '0', filterwin2k: '1', authoritative: '0', readethers: '0', nonwildcard: '0', '.type': 'dnsmasq', domain: 'lan', local: '/lan/', leasefile: '/tmp/dhcp.leases' },
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
		section: { log_remote: '1', urandom_seed: '1', '.type': 'system', hostname: 'router', timezone: 'UTC', description: 'probe' },
	},
	{
		file: "system.timeservers.uc", id: "ntp", pkg: "system",
		section: { enabled: '0', enable_server: '1', use_dhcp: '0', '.type': 'timeserver', server: ['0.pool.ntp.org', '1.pool.ntp.org'] },
	},
	{
		file: "dropbear.instances.uc", id: "db1", pkg: "dropbear",
		section: { enable: '0', RootPasswordAuth: '0', GatewayPorts: '1', '.type': 'dropbear', Port: '22', PasswordAuth: '0', RootLogin: '0' },
	},
	{
		file: "uhttpd.instances.uc", id: "main", pkg: "uhttpd",
		section: { no_dirlists: '1', no_symlinks: '1', rfc1918_filter: '1', '.type': 'uhttpd', listen_http: ['0.0.0.0:80', '[::]:80'], home: '/www',
		           ucode_prefix: ['/api/v3=/usr/share/uapi/main.uc',
		                          '/probe=/usr/share/uapi/main.uc'] },
	},
	{
		file: "uhttpd.certs.uc", id: "px", pkg: "uhttpd",
		section: { '.type': 'cert', commonname: 'router.lan', days: '730', bits: '2048' },
	},
	{
		file: "unbound.server.uc", id: "ub", pkg: "unbound",
		singleton: true,
		section: { dnssec_enabled: '1', query_minimize: '1', '.type': 'unbound', listen_port: '5353', recursion: 'default', resource: 'small', protocol: 'mixed' },
	},
	{
		file: "unbound.srv.uc", id: "srv", pkg: "unbound_srv",
		singleton: true,
		section: { enabled: '1', '.type': 'unbound_srv', num_threads: '1' },
	},
	{
		file: "unbound.ext.uc", id: "ext", pkg: "unbound_ext",
		singleton: true,
		section: { enabled: '1', '.type': 'unbound_ext', dnsmasq_gate_name: '0' },
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
		section: { enable_cdp: '1', enable_fdp: '1', enable_sonmp: '1', enable_edp: '1', lldp_description: '0', lldp_capabilities: '0', '.type': 'lldpd', enable_lldp: '1', lldp_class: '4' },
	},
	{
		file: "prometheus_node_exporter_lua.config.uc", id: "main", pkg: "prometheus-node-exporter-lua",
		singleton: true,
		section: { '.type': 'prometheus-node-exporter-lua', listen_interface: 'lan', listen_port: '9100' },
	},
	{
		file: "vnstat.config.uc", id: "cfg", pkg: "vnstat",
		singleton: true,
		section: { '.type': 'vnstat', interface: ['br-lan'] },
	},
	{
		file: "mwan3.globals.uc", id: "globals", pkg: "mwan3",
		singleton: true,
		section: { logging: '1', '.type': 'globals', mmx_mask: '0x3F00' },
	},
	{
		file: "mwan3.interfaces.uc", id: "mwan", pkg: "mwan3",
		section: { check_quality: '1', keep_failure_interval: '1', '.type': 'interface', family: 'ipv4', enabled: '1', track_method: 'ping', reliability: '1' },
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
		section: { logging: '1', '.type': 'rule', use_policy: 'pol1', proto: 'all', sticky: '1' },
	},
	{
		file: "usteer.config.uc", id: "cfg", pkg: "usteer",
		singleton: true,
		section: { enabled: '0', ipv6: '1', assoc_steering: '1', '.type': 'usteer', network: 'default', syslog: '0' },
	},
	{
		file: "openvpn.instances.uc", id: "vpn0", pkg: "openvpn",
		modify: { key: "port", value: 1195 },
		section: { client: '1', nobind: '1', float: '1', client_to_client: '1', duplicate_cn: '1', persist_key: '1', persist_tun: '1', ncp_disable: '1', tls_server: '1', tls_client: '1', '.type': 'openvpn', enabled: '1', dev_type: 'tun', proto: 'udp', port: '1194', key: '/etc/openvpn/k.pem', tls_auth: '/etc/openvpn/ta.key' },
	},
];

return { WG_KEY, WG_PUB, world, CASES };
