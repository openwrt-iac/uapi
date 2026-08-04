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
// and then the pair refused outright (2.4.1), and `dns` written as the inverse of the
// request (2.5.0). Each was found by hand, one release at a time.
//
// It takes two forms, because they catch different defects. Writing the body back
// unmodified catches a read the write path cannot reproduce, which is how masked
// credentials were destroyed. Changing one field first catches a read whose fields are not
// independently writable, which is how the `ipaddr` / `ipaddrs` pair became unwritable:
// an unmodified body has the scalar agreeing with the list, so the contradiction only
// appears once the list moves and the previously-read scalar travels beside it. Verified
// by re-introducing both bugs: each form catches its own and not the other's.
//
// What neither can cover: a uci option no resource models at all. PUT deliberately drops
// unmodelled options (uapi owns the section), so a view-level comparison cannot see the
// loss. That gap is curation completeness, checked against real configuration by
// tests/integration/44_stock_config_test.sh.

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

// One entry per resource whose read-then-write is non-trivial. `seed` is the uci state,
// `id` the section the property drives.
const CASES = [
	{
		file: "network.interfaces.uc", id: "wg0",
		why: "masked private_key must survive a PUT that cannot send it back",
		seed: { network: {
			wg0: { '.type': 'interface', '.anonymous': false, proto: 'wireguard',
			       private_key: WG_KEY, addresses: ['10.9.0.1/24'], listen_port: '51820' },
		} },
	},
	{
		file: "network.interfaces.uc", id: "lan",
		why: "ipaddr and ipaddrs are two names for one option; a round trip sends both",
		modify: { key: "ipaddrs", value: ["192.168.78.1/24"] },
		seed: { network: {
			lan: { '.type': 'interface', '.anonymous': false, proto: 'static',
			       device: 'br-lan', ipaddr: ['192.168.1.1/24', '10.0.0.1/24'] },
		} },
	},
	{
		file: "network.wireguard_peers.uc", id: "p1",
		why: "masked preshared_key, plus a merge hook",
		modify: { key: "allowed_ips", value: ["10.9.0.3/32"] },
		seed: { network: {
			wg0: { '.type': 'interface', '.anonymous': false, proto: 'wireguard',
			       private_key: WG_KEY, addresses: ['10.9.0.1/24'] },
			p1: { '.type': 'wireguard_wg0', '.anonymous': false,
			      public_key: WG_PUB, allowed_ips: ['10.9.0.2/32'],
			      preshared_key: WG_KEY, endpoint_host: '198.51.100.7',
			      endpoint_port: '51820' },
		} },
	},
	{
		file: "wireless.interfaces.uc", id: "w1",
		why: "masked key, and encryption requires one to be present",
		modify: { key: "ssid", value: "home2" },
		seed: { wireless: {
			w1: { '.type': 'wifi-iface', '.anonymous': false, device: 'radio0',
			      ssid: 'home', encryption: 'psk2', key: 'correcthorse' },
		} },
	},
	{
		file: "dhcp.hosts.uc", id: "h1",
		why: "a scalar tag must not be normalized into a list behind the client",
		seed: { dhcp: {
			h1: { '.type': 'host', '.anonymous': false, mac: '00:11:22:33:44:55',
			      ip: '192.168.1.50', tag: 'guest iot' },
		} },
	},
	{
		file: "dhcp.hosts.uc", id: "h2",
		why: "and a list tag, which is the shape LuCI writes, must stay a list",
		modify: { key: "tag", value: ["guest", "iot", "lab"] },
		seed: { dhcp: {
			h2: { '.type': 'host', '.anonymous': false, mac: '00:11:22:33:44:66',
			      ip: '192.168.1.51', tag: ['guest', 'iot'] },
		} },
	},
	{
		file: "openvpn.instances.uc", id: "vpn0",
		why: "three masked credentials and a merge hook",
		seed: { openvpn: {
			vpn0: { '.type': 'openvpn', '.anonymous': false, enabled: '1',
			        dev_type: 'tun', proto: 'udp', port: '1194',
			        key: '/etc/openvpn/k.pem', tls_auth: '/etc/openvpn/ta.key' },
		} },
	},
];

t.describe('property: a read written straight back changes nothing', () => {
	for (let c in CASES) {
		t.it(sprintf("%s/%s: %s", c.file, c.id, c.why), () => {
			let mod = loadfile('src/resources/' + c.file)();
			let h = handler.make(mod, { tx: tx_stub() });
			let conn = ubus.stub({ uci: c.seed });

			let first = h.get_one(conn, ctx(), c.id);
			t.assert_equal(first.status, 200);

			// The body a client would send back verbatim, runtime excluded because it is
			// live state rather than configuration and no client echoes it.
			let body = { ...first.body };
			delete body.runtime;

			let put = h.replace(conn, ctx(), c.id, body);
			if (put.status != 200) {
				// Surface the reason rather than just the code: a bare 422 here costs
				// the next reader a debugging session.
				t.assert_equal(sprintf("PUT rejected the body it just served: %J", put.body),
				               "PUT accepted");
			}

			let second = h.get_one(conn, ctx(), c.id);
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
				let put2 = h.replace(conn, ctx(), c.id, changed);
				if (put2.status != 200)
					t.assert_equal(sprintf("PUT rejected a one-field change to %s: %J",
					                       c.modify.key, put2.body),
					               "PUT accepted");
				let third = h.get_one(conn, ctx(), c.id);
				if (!ph.json_eq(third.body[c.modify.key], c.modify.value))
					t.assert_equal(sprintf("%s did not take: %J", c.modify.key,
					                       third.body[c.modify.key]),
					               sprintf("%J", c.modify.value));
			}
		});
	}
});

// The case list above must not silently fall behind the resource tree: the next resource
// carrying a masked credential or a merge hook is exactly the shape that has broken
// before. The risk set is derived from the modules rather than hand-listed so it cannot go
// stale.
t.describe('property: every non-trivial resource has a round-trip case', () => {
	t.it('covers every resource with a masked field or a merge hook', () => {
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
			let non_trivial = index(text, "writeOnly") >= 0
			                  || index(text, "merge_for_patch:") >= 0
			                  || index(text, "resolve_for_replace:") >= 0;
			if (non_trivial && !covered[name]) push(missing, name);
		}
		if (length(missing) > 0)
			t.assert_equal("uncovered non-trivial resources: " + join(", ", missing),
			               "all covered");
		t.assert_equal(length(missing), 0);
	});
});
