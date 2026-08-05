let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let fs = require('fs');
let ph = require('property_harness');

// Read a resource, write the body straight back, read again: nothing may change and
// nothing may be rejected. That is the mechanical statement of an honest read, and it is
// the property an IaC client depends on, since every apply is a read-modify-write.
//
// Every full-replace defect this project has hit is a counterexample to it: `src_dip`
// dropped on a redirect round-trip (2.4.0), write-only secrets destroyed by a PUT that
// could not send them back (2.4.0), `ipaddr` discarded when `ipaddrs` travelled beside it
// and then the pair refused outright (2.4.1), `dns` written as the inverse of the request
// and `tag` typed as a string while returning arrays (2.5.0). Each was found by hand, one
// release at a time.
//
// It takes two forms, because they catch different defects. Writing the body back
// unmodified catches a read the write path cannot reproduce, which is how masked
// credentials were destroyed. Changing one field first catches a read whose fields are not
// independently writable, which is how the `ipaddr` / `ipaddrs` pair became unwritable:
// an unmodified body has the scalar agreeing with the list, so the contradiction only
// appears once the list moves and the previously-read scalar travels beside it. Verified
// by re-introducing both bugs: each form catches its own and not the other's.
//
// Every writable resource carries a case. The earlier version demanded them only from
// resources with a masked field or a merge hook, four of forty-three, which would not have
// demanded `dhcp/hosts` and so would not have caught the `tag` bug that shipped in the
// same release as the property itself.
//
// What none of it can cover: a uci option no resource models at all. PUT deliberately
// drops unmodelled options (uapi owns the section), so a view-level comparison cannot see
// the loss. That gap is curation completeness, checked against real configuration by
// tests/integration/44_stock_config_test.sh, and the read-honesty equivalent on hardware
// is tests/integration/47_read_honesty_test.sh.

function tx_stub() {
	return {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
		wg_apply: function() { return null; }, wg_reconcile: function() { return null; },
	};
}

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

const WG_KEY = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const WG_PUB = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';

// The sections cases cross-reference: a rule needs its zone to exist, a peer its parent
// interface, a member its mwan3 interface. Built fresh per case so one case cannot leave
// state behind for the next. A case whose own id collides with a world section replaces
// it, which is intended for the resources that ARE the referenced thing.
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
		           addresses: ['10.9.0.1/24'], listen_port: '51820' },
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
		section: { '.type': 'bridge-vlan', device: 'br-probe', vlan: '7', ports: ['lan1'] },
	},
	{
		file: "network.wireguard_peers.uc", id: "p1", pkg: "network",
		modify: { key: "allowed_ips", value: ["10.9.0.3/32"] },
		section: { '.type': 'wireguard_wg0', public_key: WG_PUB, allowed_ips: ['10.9.0.2/32'], preshared_key: WG_KEY, endpoint_host: '198.51.100.7', endpoint_port: '51820' },
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
		section: { '.type': 'timeserver', server: ['0.pool.ntp.org'] },
	},
	{
		file: "dropbear.instances.uc", id: "db1", pkg: "dropbear",
		section: { '.type': 'dropbear', Port: '22', PasswordAuth: '1', RootLogin: '1' },
	},
	{
		file: "uhttpd.instances.uc", id: "main", pkg: "uhttpd",
		section: { '.type': 'uhttpd', listen_http: ['0.0.0.0:80'], home: '/www', ucode_prefix: ['/api/v2=/usr/share/uapi/main.uc'] },
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
		section: { '.type': 'interface', family: 'ipv4', enabled: '0', track_method: 'ping', reliability: '1' },
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
		section: { '.type': 'openvpn', enabled: '0', dev_type: 'tun', proto: 'udp', port: '1194', key: '/etc/openvpn/k.pem', tls_auth: '/etc/openvpn/ta.key' },
	},
];

function seeded(c) {
	let uci = world();
	if (uci[c.pkg] == null) uci[c.pkg] = {};
	let sec = { '.anonymous': false, ...c.section };
	uci[c.pkg][c.id] = sec;
	return ubus.stub({ uci: uci });
}

function read(h, c, conn) {
	return c.singleton ? h.get(conn, ctx()) : h.get_one(conn, ctx(), c.id);
}

// A singleton has no PUT (see handler.make_singleton), so its round trip is PATCH with the
// body it just served, which is the same shape 44_stock_config_test.sh uses.
function write(h, c, conn, body) {
	return c.singleton ? h.patch(conn, ctx(), body) : h.replace(conn, ctx(), c.id, body);
}

t.describe('property: a read written straight back changes nothing', () => {
	for (let c in CASES) {
		t.it(sprintf("%s/%s", c.file, c.id), () => {
			let mod = loadfile('src/resources/' + c.file)();
			let h = c.singleton ? handler.make_singleton(mod, { tx: tx_stub() })
			                    : handler.make(mod, { tx: tx_stub() });
			let conn = seeded(c);

			let first = read(h, c, conn);
			if (first.status != 200) {
				t.assert_equal(sprintf("GET failed, so the seed is wrong rather than the "
				                       + "resource: %J", first.body), "GET 200");
				return;
			}

			// The body a client would send back verbatim, runtime excluded because it is
			// live state rather than configuration and no client echoes it.
			let sent = { ...first.body };
			delete sent.runtime;

			let put = write(h, c, conn, sent);
			if (put.status != 200) {
				// Surface the reason rather than just the code: a bare 422 here costs
				// the next reader a debugging session.
				t.assert_equal(sprintf("write rejected the body it just served: %J", put.body),
				               "write accepted");
				return;
			}

			let second = read(h, c, conn);
			t.assert_equal(second.status, 200);
			for (let k in first.body) {
				if (k == "runtime") continue;
				if (!ph.json_eq(first.body[k], second.body[k]))
					t.assert_equal(sprintf("%s changed across a round trip: %J -> %J",
					                       k, first.body[k], second.body[k]),
					               "unchanged");
			}

			// The apply shape: change one field, leave the rest as read. A field that is
			// not independently writable shows up here and nowhere else.
			if (c.modify != null) {
				let changed = { ...second.body };
				delete changed.runtime;
				changed[c.modify.key] = c.modify.value;
				let put2 = write(h, c, conn, changed);
				if (put2.status != 200) {
					t.assert_equal(sprintf("write rejected a one-field change to %s: %J",
					                       c.modify.key, put2.body), "write accepted");
					return;
				}
				let third = read(h, c, conn);
				if (!ph.json_eq(third.body[c.modify.key], c.modify.value))
					t.assert_equal(sprintf("%s did not take: %J", c.modify.key,
					                       third.body[c.modify.key]),
					               sprintf("%J", c.modify.value));
			}
		});
	}
});

// A seed must not set a field to the same value fromUci would synthesize for it, or the
// property goes blind to that field: drop it from toUci and the re-read fills the default
// back in, so before and after match and nothing is reported. Measured, not theorised:
// deleting `out.forward` from firewall.zones was invisible while the seed said `REJECT`,
// which is the documented default, and caught immediately once the seed said `DROP`.
t.describe('property: no case hides a field behind its own default', () => {
	t.it('every seeded value differs from the schema default for that field', () => {
		let offenders = [];
		for (let c in CASES) {
			let mod = loadfile('src/resources/' + c.file)();
			let props = mod.schema_properties ?? {};
			for (let k in c.section) {
				let spec = props[k];
				if (spec == null || !exists(spec, "default")) continue;
				// uci holds strings, so compare as strings: `disabled: '0'` against a
				// declared default of false is the same claim.
				let seeded = "" + c.section[k];
				let dflt = "" + spec.default;
				if (dflt == "false") dflt = "0";
				if (dflt == "true") dflt = "1";
				if (seeded == dflt)
					push(offenders, sprintf("%s/%s: %s=%s is the default",
					                        c.file, c.id, k, seeded));
			}
		}
		if (length(offenders) > 0)
			t.assert_equal(join("; ", offenders), "no field seeded at its default");
		t.assert_equal(length(offenders), 0);
	});
});

// The case list must not fall behind the resource tree. Every resource with a validate()
// is writable and therefore has to round-trip; there is no exempt category any more.
t.describe('property: every writable resource has a round-trip case', () => {
	t.it('covers all of them', () => {
		let covered = {};
		for (let c in CASES) covered[c.file] = true;

		let missing = [];
		for (let name in fs.lsdir('src/resources')) {
			if (substr(name, length(name) - 3) != ".uc") continue;
			let src = fs.open('src/resources/' + name, 'r');
			let text = src.read('all');
			src.close();
			// No validate means a read-only collection (the lease views), nothing to write.
			if (index(text, "validate:") < 0) continue;
			if (!covered[name]) push(missing, name);
		}
		if (length(missing) > 0)
			t.assert_equal("resources with no round-trip case: " + join(", ", missing),
			               "all covered");
		t.assert_equal(length(missing), 0);
	});
});
