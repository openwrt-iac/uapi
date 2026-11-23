let t = require('harness');
let ubus = require('bus');
let wg = require('wg');
let fs = require('fs');

const PK = 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=';
const PK2 = 'TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=';

// `wg`, `ip` and `nslookup` are scripts here that log each command with its arguments joined by `|`,
// and print the file named after the command when a test wrote one, so a test reads what an apply
// runs without a WireGuard interface or a resolver. A command that matches the shell pattern `fail`
// then exits 1. The call runs in a child, whose PATH finds the scripts first.
function run_wg(uci, call, outputs, fail) {
	let mk = fs.popen("mktemp -d /tmp/uapi-wg-apply.XXXXXX");
	let dir = trim(mk.read("all") ?? "");
	mk.close();
	for (let name in [ "wg", "ip", "nslookup" ]) {
		fs.writefile(dir + "/" + name, sprintf("#!/bin/sh\nIFS='|'\necho \"%s|$*\" >> %s/log\ncat \"%s/%s|$*\" 2>/dev/null\ncase \"%s|$*\" in %s) exit 1 ;; esac\nexit 0\n",
		                                       name, dir, dir, name, name, fail ?? "''"));
		fs.chmod(dir + "/" + name, 0o755);
	}
	for (let cmd, text in outputs ?? {}) fs.writefile(dir + "/" + cmd, text);
	let script = sprintf("let wg = require('wg'); let c = require('bus').stub({ uci: %J }); c.set_ubus_response('network.interface.wg1', 'status', { up: true }); print(%s ?? 'ok');",
	                     uci, call);
	let p = fs.popen(sprintf("PATH=%s:\"$PATH\" ucode -L tests -L src/lib -e %s 2>&1", dir, wg.shellquote(script)));
	let result = trim(p.read("all") ?? "");
	p.close();
	let log = fs.readfile(dir + "/log") ?? "";
	system([ "rm", "-rf", dir ]);
	return { result, commands: filter(split(log, "\n"), (l) => l != "") };
}
const WG1 = { '.type': 'interface', '.anonymous': false, proto: 'wireguard' };
let peer = (extra) => ({ '.type': 'wireguard_wg1', '.anonymous': false, ...extra });
let set_of = (key, ips) => sprintf("wg|set|wg1|peer|%s|allowed-ips|%s|persistent-keepalive|0|preshared-key|/dev/null", key, ips);

// Every wg and ip argument goes through shellquote, and the restore reads values from uci that
// no validate() saw. Same idiom as LuCI's wireguard backend.
t.describe('wg.shellquote', () => {
	t.it('wraps a plain value in single quotes', () => {
		t.assert_equal(wg.shellquote("vpn.example.org"), "'vpn.example.org'");
	});
	t.it('neutralises a command substitution', () => {
		t.assert_equal(wg.shellquote("$(reboot)"), "'$(reboot)'");
	});
	t.it('escapes an embedded single quote so the quoting cannot be broken out of', () => {
		t.assert_equal(wg.shellquote("a'b"), "'a'\\''b'");
	});
	t.it('escapes every embedded quote, not just the first', () => {
		t.assert_equal(wg.shellquote("a'b'c"), "'a'\\''b'\\''c'");
	});
	t.it('renders null as an empty quoted string', () => {
		t.assert_equal(wg.shellquote(null), "''");
	});
});

// The handler gives wg each key as uci holds it, and skips a peer whose key is not a WireGuard key.
t.describe('wg.kernel_key', () => {
	t.it('reads a key as the whole value', () => {
		t.assert_equal(wg.kernel_key(PK), PK);
	});
	t.it('is null when the kernel can hold no such peer', () => {
		for (let v in [ 'not-a-key', [ PK ], [ PK, PK ], null, '#' + PK, substr(PK, 0, 42) + '5=', substr(PK, 0, 43) + '\\075',
		                PK + ' # peer B', ' ' + PK, PK + '\nPublicKey=' + PK2 ])
			t.assert_equal(wg.kernel_key(v), null, v);
	});
});

// The handler takes a list as its entries and an option as its words, joins them with commas and
// expands no escape, and wg cuts the line at `#` and splits it at commas.
t.describe('wg.allowed_ips', () => {
	t.it('reads a list entry as one entry and an option as its words, and expands no escape', () => {
		t.assert_deep_equal(wg.allowed_ips([ '10.0.0.0/24 10.0.1.7' ]), [ '10.0.0.0/24 10.0.1.7' ]);
		t.assert_deep_equal(wg.allowed_ips(' 10.0.0.0/24\t 10.0.1.7 '), [ '10.0.0.0/24', '10.0.1.7' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\\054192.168.0.0/16'), [ '10.0.0.0/8\\054192.168.0.0/16' ]);
	});
	t.it('splits at each comma, as wg splits the line', () => {
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8,10.1.0.0/16'), [ '10.0.0.0/8', '10.1.0.0/16' ]);
		t.assert_deep_equal(wg.allowed_ips([ '10.0.0.0/8', '10.1.0.0/16,fd00::/8' ]), [ '10.0.0.0/8', '10.1.0.0/16', 'fd00::/8' ]);
	});
	t.it('cuts the line at the first #, with the entries after it', () => {
		t.assert_deep_equal(wg.allowed_ips([ '10.0.0.0/24#/0x10', '10.0.1.7' ]), [ '10.0.0.0/24' ]);
	});
	t.it('is null without a value, and one empty entry when wg reads nothing from the line', () => {
		t.assert_equal(wg.allowed_ips(null), null);
		t.assert_equal(wg.allowed_ips(''), null);
		for (let v in [ '#c', [ '#c', '10.0.0.0/8' ] ])
			t.assert_deep_equal(wg.allowed_ips(v), [ '' ], v);
	});
});

t.describe('wg.interfaces_of', () => {
	t.it('dedups while preserving first-seen order', () => {
		t.assert_deep_equal(wg.interfaces_of([
			{ iface: "wgB" }, { iface: "wgA" }, { iface: "wgB" },
		]), ["wgB", "wgA"]);
	});
	t.it('ignores ops with no interface', () => {
		t.assert_deep_equal(wg.interfaces_of([{ action: "set" }, { iface: "wg1" }]), ["wg1"]);
	});
	t.it('is empty for no ops', () => {
		t.assert_deep_equal(wg.interfaces_of([]), []);
	});
});

t.describe('wg.to_peer', () => {
	t.it('reads the fields off a uci section', () => {
		let p = wg.to_peer({
			public_key: PK, allowed_ips: ['10.0.0.2/32'],
			endpoint_host: 'vpn.example.org', endpoint_port: '51820',
			persistent_keepalive: '25', preshared_key: 'psk',
		});
		t.assert_equal(p.public_key, PK);
		t.assert_deep_equal(p.allowed_ips, ['10.0.0.2/32']);
		t.assert_equal(p.endpoint_host, 'vpn.example.org');
		t.assert_equal(p.preshared_key, 'psk');
	});

	// uci collapses a single-element list to a scalar on read, so a peer with one
	// allowed_ips entry arrives as a string and would otherwise be iterated
	// character by character.
	t.it('lifts a scalar allowed_ips into a list', () => {
		t.assert_deep_equal(wg.to_peer({ allowed_ips: '10.0.0.2/32' }).allowed_ips,
		                    ['10.0.0.2/32']);
	});
	t.it('splits a scalar allowed_ips into words, as the handler does', () => {
		t.assert_deep_equal(wg.to_peer({ allowed_ips: '10.0.0.2/32 10.0.1.0/24' }).allowed_ips,
		                    ['10.0.0.2/32', '10.0.1.0/24']);
	});
	t.it('reads the port and the keepalive as numbers, so nothing else reaches the command', () => {
		let p = wg.to_peer({ public_key: PK, allowed_ips: ['10.0.0.2/32'], endpoint_port: '51820',
		                     persistent_keepalive: '25' });
		t.assert_equal(p.endpoint_port, 51820);
		t.assert_equal(p.persistent_keepalive, 25);
		t.assert_equal(wg.to_peer({ persistent_keepalive: '0;touch /tmp/x' }).persistent_keepalive, -1);
		t.assert_equal(wg.to_peer({ endpoint_port: '51820;touch /tmp/x' }).endpoint_port, 0);
		t.assert_equal(wg.to_peer({ persistent_keepalive: 'off' }).persistent_keepalive, 0);
	});
	t.it('reads a list endpoint_host as one string', () => {
		t.assert_equal(wg.to_peer({ endpoint_host: [ 'vpn.example.org' ] }).endpoint_host, 'vpn.example.org');
	});
	t.it('yields an empty list when allowed_ips is absent', () => {
		t.assert_deep_equal(wg.to_peer({}).allowed_ips, []);
	});
});

// These assert the paths that decide NOT to run wg, which is what makes them
// testable off-device: reaching the command would fail on a box without wg and
// surface as an error string rather than null.
t.describe('wg.unclaimed against logging wg and ip', () => {
	let unclaimed = (uci, outputs) => run_wg(uci, 'sprintf("%J", wg.unclaimed(c).peers)', outputs);
	let unread = (uci, outputs) => run_wg(uci, 'sprintf("%J", wg.unclaimed(c).unread)', outputs).result;
	let dump_of = (entries) => ({ 'wg|show|wg1|dump': "priv\tpub\t51820\toff\n" + join("", entries) });
	let line = (key, endpoint, ips, keepalive) =>
		sprintf("%s\t(none)\t%s\t%s\t0\t0\t0\t%s\n", key, endpoint, ips, keepalive);

	// runtime() reports the kernel beside each section, so the kernel peers that no section of
	// their interface claims are the ones that no read showed. A section of another interface
	// claims nothing, and a disabled section claims, because its runtime already reports the peer.
	t.it('lists each kernel peer that no section of its interface claims', () => {
		let r = unclaimed({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32' }),
		                               b: { '.type': 'wireguard_wg2', '.anonymous': false, public_key: PK2 } } },
		                  dump_of([ line(PK, '(none)', '10.0.0.2/32', 'off'),
		                            line(PK2, '198.51.100.7:51820', '10.0.0.3/32,fd00::/64', '25') ]));
		t.assert_equal(r.result, sprintf('[ { "interface": "wg1", "public_key": "%s", "endpoint": "198.51.100.7:51820", "allowed_ips": [ "10.0.0.3/32", "fd00::/64" ], "persistent_keepalive": 25, "latest_handshake": 0, "rx_bytes": 0, "tx_bytes": 0 } ]', PK2));
	});
	t.it('lists no peer that a disabled section claims', () => {
		let r = unclaimed({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', disabled: '1' }) } },
		                  dump_of([ line(PK, '(none)', '10.0.0.2/32', 'off') ]));
		t.assert_equal(r.result, '[ ]');
	});
	// A down interface holds no peer and is not dumped. A failed read never looks like an empty
	// kernel: an up interface whose dump is in another shape lists nothing and is named as unread.
	t.it('dumps no interface that is down, and names an up interface whose dump it cannot read', () => {
		let down = { network: { wg2: { '.type': 'interface', '.anonymous': false, proto: 'wireguard' } } };
		let r = unclaimed(down);
		t.assert_equal(r.result, '[ ]');
		t.assert_deep_equal(r.commands, []);
		t.assert_equal(unread(down), '[ ]');
		let odd = { 'wg|show|wg1|dump': "priv\tpub\t51820\toff\textra\n" };
		t.assert_equal(unclaimed({ network: { wg1: WG1 } }, odd).result, '[ ]');
		t.assert_equal(unread({ network: { wg1: WG1 } }, odd), '[ "wg1" ]');
		t.assert_equal(unread({ network: { wg1: WG1 } }, dump_of([])), '[ ]');
	});
});

t.describe('wg.apply', () => {
	function down_conn() {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.wg1', 'status', { up: false });
		return c;
	}

	t.it('does nothing when there are no ops', () => {
		let c = ubus.stub();
		t.assert_equal(wg.apply(c, []), null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});

	// A down interface holds no peer state and ifup reads the peers from uci, so
	// there is nothing to apply.
	t.it('skips ops for an interface that is down', () => {
		t.assert_equal(wg.apply(down_conn(), [
			{ iface: "wg1", action: "set", public_key: PK, allowed_ips: ['10.0.0.2/32'] },
		]), null);
	});

	// An interface netifd does not know is the same case, and it is how a peer
	// orphaned by deleting its parent stays deletable instead of failing the write.
	t.it('skips ops for an interface netifd does not know', () => {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.gone', 'status', { _error: 'Not found' });
		t.assert_equal(wg.apply(c, [
			{ iface: "gone", action: "remove", public_key: PK },
		]), null);
	});

	// The wait for the restart of the handler reads a down interface twice, half a second apart.
	t.it('checks each interface once however many ops it has', () => {
		let c = down_conn();
		wg.apply(c, [
			{ iface: "wg1", action: "remove", public_key: PK },
			{ iface: "wg1", action: "remove", public_key: PK },
			{ iface: "wg1", action: "remove", public_key: PK },
		]);
		let status = filter(c._state.ubus_calls, function(x) { return x[1] == "status"; });
		t.assert_equal(length(status), 2);
	});

	// A stored key that is not a WireGuard key made the DELETE of its peer, or a write that
	// replaced the key, answer 500 on an up interface.
	t.it('removes nothing for a key that is not a WireGuard key', () => {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.wg1', 'status', { up: true });
		t.assert_equal(wg.apply(c, [
			{ iface: "wg1", action: "remove", public_key: "not-a-key" },
		]), null);
	});

	t.it('refuses an interface name that could escape into a command', () => {
		let c = ubus.stub();
		let err = wg.apply(c, [{ iface: "wg1; reboot", action: "remove", public_key: PK }]);
		t.assert_true(err != null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});
});

t.describe('wg.apply against logging wg and ip', () => {
	let apply = (uci, ops, outputs) => run_wg(uci, sprintf("wg.apply(c, %J)", ops), outputs);

	// ifup sets the sections in uci order, so the last one with the key wins.
	t.it('a remove sets again each other enabled section with the key, in uci order', () => {
		let r = apply({ network: { wg1: WG1,
		                           a: peer({ public_key: PK, allowed_ips: [ '10.0.0.2/32' ] }),
		                           b: peer({ public_key: PK, allowed_ips: [ '10.0.0.3/32' ], disabled: '1' }),
		                           c: peer({ public_key: PK2, allowed_ips: [ '10.0.0.5/32' ] }),
		                           d: peer({ public_key: PK, allowed_ips: '10.0.0.4/32' }) } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK } ]);
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0),
		                    [ set_of(PK, '10.0.0.2/32'), set_of(PK, '10.0.0.4/32') ]);
	});

	t.it('a remove sets again a section with the key and no allowed IPs, with none', () => {
		let r = apply({ network: { wg1: WG1, a: peer({ public_key: PK }) } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK } ]);
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0), [ set_of(PK, '') ]);
	});

	t.it('gives wg the host without the whitespace that wg strips from the config', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.2/32' ],
		                  endpoint_host: ' fd00::1 ', endpoint_port: 51820 } ]);
		t.assert_deep_equal(r.commands, [ set_of(PK, '10.0.0.2/32') + '|endpoint|[fd00::1]:51820' ]);
	});

	// A marker entry makes the whole list an incremental update to wg, which adds its prefixes to
	// what the peer already holds, or refuses the command.
	t.it('refuses a peer with an allowed_ips entry marked + or -, and runs nothing', () => {
		for (let ips in [ [ '+10.0.0.0/8' ], [ '-fd00::/64' ], [ '10.0.0.5/32', '-10.0.0.6/32' ], [ ' +10.0.0.0/8' ], [ '10.0.0.5/32', '\t-10.0.0.6/32' ] ]) {
			let r = apply({ network: { wg1: WG1 } },
			              [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: ips } ]);
			t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1', ips);
			t.assert_deep_equal(r.commands, [], ips);
		}
	});

	// A stored marker entry reaches the apply through the sections that a remove sets again, with no
	// validate() in front of it.
	t.it('a remove that sets a stored marker entry again refuses the peer, and runs nothing', () => {
		let r = apply({ network: { wg1: WG1,
		                           a: peer({ public_key: PK, allowed_ips: '+10.0.0.0/8' }) } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK } ]);
		t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1');
		t.assert_deep_equal(r.commands, []);
	});

	// #387: the remove set the first section with the key again before it refused the second, and the
	// restore refuses that section before it changes the kernel, so the kernel kept what the remove
	// had set.
	t.it('a remove refuses a later section with the key before it sets an earlier one again', () => {
		let first = peer({ public_key: PK, allowed_ips: [ '10.0.0.2/32' ] });
		let r = apply({ network: { wg1: WG1, b: first, c: peer({ public_key: PK, allowed_ips: [ '\t+10.0.0.0/8' ] }) } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK } ]);
		t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1');
		t.assert_deep_equal(r.commands, []);
	});

	// getaddrinfo of musl reads these as addresses, and looks the others up as names.
	t.it('reads an IPv4 address as inet_aton does', () => {
		let dotted = (n) => (n == null) ? null : sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
		let v = [ '192.168.1.01', '010.0.0.1', '167772161', '0x0a000001', '0X0A.0', '1.16777215', '4294967295', '192.0.2.1',
		          '10.0.0.256', '1.2.3.4.5', '1.2.3.4.', '08.0.0.1', '4294967296', '1.16777216', '.', '0x', '1..2', ' 10.0.0.1', '+1', '' ];
		t.assert_deep_equal(map(v, (s) => dotted(wg.inet_aton(s))),
		                    [ '192.168.1.1', '8.0.0.1', '10.0.0.1', '10.0.0.1', '10.0.0.0', '1.255.255.255', '255.255.255.255', '192.0.2.1',
		                      null, null, null, null, null, null, null, null, null, null, null, null ]);
	});

	// lookup_ipliteral.c of musl 1.2.5 takes an index on any address, and a name only on a link-local
	// or multicast link-local one, cut as the kernel reads it.
	t.it('reads the zone of an IPv6 address as musl does', () => {
		let cases = {
			'fd00::1': null, 'vpn.example.org': null, 'host%3': null, '1.2.3.4%3': null,
			'fe80::1%3': 3, '2001:db8::1%3': 3, '2001:db8::1%0004294967295': 4294967295,
			'fe80::1%br-lan': 'br-lan', 'febf::1%eth0': 'eth0', 'ff02::1%eth0': 'eth0', 'ff32::1%eth0': 'eth0',
			'fe80::1%3x': '3x', 'fe80::1%eth0:1': 'eth0', 'fe80::1%abcdefghijklmnopq': 'abcdefghijklmno',
			'2001:db8::1%x': false, 'fd00::1%eth0': false, 'fec0::1%eth0': false, 'ff05::1%eth0': false,
			'2001:db8::1%4294967296': false, 'fe80::1%99999999999999999999999': false, 'fe80::1%': false,
			'fe80::1%..': false, 'fe80::1%.': false, 'fe80::1%a/b': false, 'fe80::1%:1': false,
		};
		for (let h, want in cases)
			t.assert_equal(wg.ipv6_zone(h), want, h);
	});

	t.it('reads a zone as missing when it names no interface in /sys/class/net', () => {
		let asked = [];
		let w = t.load_with_fs({ ...fs, access: (p) => (push(asked, p), p == '/sys/class/net/br-lan' || p == '/sys/class/net/eth0') }, [ 'wg' ]);
		let cases = {
			'fe80::1%br-lan': false, 'fe80::1%eth0:1': false, 'fe80::1%3': false, '2001:db8::1%3': false, 'fd00::1': false,
			'fe80::1%nosuchdev': true, 'fe80::1%../eth0': false, '2001:db8::1%x': false,
		};
		for (let h, want in cases)
			t.assert_equal(w.missing_zone(h), want, h);
		t.assert_deep_equal(asked, [ '/sys/class/net/br-lan', '/sys/class/net/eth0', '/sys/class/net/nosuchdev' ]);
	});

	// A write that leaves such a port as uci holds it gives it here, and so does the restore, which
	// must still set the peers after it.
	t.it('sets a peer with a host and a port that reads 0 without its endpoint, and does not remove it', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.2/32' ], endpoint_host: '192.0.2.1', endpoint_port: 0 },
		                { iface: 'wg1', action: 'set', public_key: PK2, allowed_ips: [ '10.0.0.3/32' ] } ]);
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, PK + '|') >= 0), [ set_of(PK, '10.0.0.2/32') ]);
		t.assert_true(index(r.commands, set_of(PK2, '10.0.0.3/32')) >= 0, r.commands);
	});

	t.it('sets a peer whose keepalive wg cannot read without a keepalive', () => {
		t.assert_deep_equal(wg.set_peer_argv('wg1', { public_key: PK, allowed_ips: [ '10.0.0.2/32' ], persistent_keepalive: -1 }, null),
		                    [ 'wg', 'set', 'wg1', 'peer', PK, 'allowed-ips', '10.0.0.2/32', 'preshared-key', '/dev/null' ]);
	});

	t.it('installs the masked prefix, which netifd installs and ip route takes', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.1/24' ], route_words: [ '10.0.0.1/24' ],
		                  route_allowed_ips: true } ]);
		t.assert_equal(r.result, 'ok');
		t.assert_equal(r.commands[2], 'ip|route|replace|10.0.0.0/24|dev|wg1|proto|static|scope|link');
	});

	t.it('keeps the route of a prefix that a write respells', () => {
		let r = apply({ network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: [ 'fd00::/64' ], route_allowed_ips: '1' }) } },
		              [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ 'fd00::/64' ], route_words: [ 'fd00::/64' ],
		                  route_allowed_ips: true, prev_allowed_ips: [ 'FD00:0::/64' ], prev_route_allowed_ips: true } ]);
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'),
		                    [ 'ip|-6|route|replace|fd00:0:0:0:0:0:0:0/64|dev|wg1|proto|static' ]);
	});

	// The handler reads the length in base 10, so the route that ifup installed is /64.
	t.it('withdraws the route of a stored prefix length with leading zeros', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK, prev_allowed_ips: [ 'fd00::/0064', '10.0.0.0/024' ],
		                  prev_route_allowed_ips: true } ]);
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'),
		                    [ 'ip|-6|route|del|fd00:0:0:0:0:0:0:0/64|dev|wg1|proto|static',
		                      'ip|route|del|10.0.0.0/24|dev|wg1|proto|static|scope|link' ]);
	});

	t.it('keeps a route that a config route section names in another spelling', () => {
		let r = apply({ network: { wg1: WG1, rt: { '.type': 'route6', interface: 'wg1', target: 'FD00:0::/64' } } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK, prev_allowed_ips: [ 'fd00::/64' ],
		                  prev_route_allowed_ips: true } ]);
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'), []);
	});
});

// /var/run is root's, so the key file is a file in /tmp. On a full tmpfs the open creates the file
// and the write fails, so the full case creates the file and hands the module a handle on /dev/full.
t.describe('wg with a preshared key', () => {
	const PSK_PATH = '/var/run/uapi.wg.psk';
	const KEY_FILE = '/tmp/uapi-test-wg.psk';
	const PSK = 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXphYmNkZWY=';
	function key_file(full, uci) {
		let key = { commands: [] };
		let at = (p) => (p == PSK_PATH) ? KEY_FILE : p;
		key.wg = t.load_with_fs({ ...fs,
			open: (p, m) => {
				let f = fs.open(at(p), m);
				if (!full || p != PSK_PATH || f == null) return f;
				f.close();
				return fs.open('/dev/full', 'w');
			},
			stat: (p) => fs.stat(at(p)),
			chmod: (p, mode) => fs.chmod(at(p), mode),
			unlink: (p) => fs.unlink(at(p)),
			popen: (cmd) => { push(key.commands, cmd); key.wrote = fs.readfile(KEY_FILE); return { read: () => "", close: () => 0 }; },
		}, [ 'wg' ]);
		key.conn = ubus.stub({ uci: uci ?? {} });
		key.conn.set_ubus_response('network.interface.wg1', 'status', { up: true });
		return key;
	}
	let cmd = (argv) => wg.command_line(argv) + ' 2>&1';
	let set_op = (extra) => ({ iface: 'wg1', action: 'set', allowed_ips: [ '10.0.0.2/32' ], preshared_key: PSK, ...extra });

	t.it('gives wg the key in a file and removes the file after', () => {
		let key = key_file(false);
		let r = key.wg.apply(key.conn, [ set_op({ public_key: PK, endpoint_host: '192.0.2.1', endpoint_port: 51820 }) ], []);
		let left = fs.stat(KEY_FILE);
		fs.unlink(KEY_FILE);
		t.assert_equal(r, null);
		t.assert_deep_equal(key.commands, [ cmd([ 'wg', 'set', 'wg1', 'peer', PK, 'allowed-ips', '10.0.0.2/32',
		                                          'persistent-keepalive', '0', 'preshared-key', PSK_PATH,
		                                          'endpoint', '192.0.2.1:51820' ]) ]);
		t.assert_equal(key.wrote, PSK + "\n");
		t.assert_equal(left, null);
	});

	t.it('fails the apply and removes the file when the tmpfs cannot hold the key', () => {
		let key = key_file(true);
		let r = key.wg.apply(key.conn, [ set_op({ public_key: PK, endpoint_host: '192.0.2.1', endpoint_port: 51820 }) ], []);
		let left = fs.stat(KEY_FILE);
		fs.unlink(KEY_FILE);
		t.assert_match(r, /could not stage the preshared key/);
		t.assert_deep_equal(key.commands, []);
		t.assert_equal(left, null);
	});

	// a and b have a key and no endpoint, and a write of b cannot stage b's key. Both the apply and
	// the restore removed a peer before they staged its key: the apply removed b, and the restore,
	// which sets every peer of wg1 again, removed a, which the write did not name. Neither came back.
	t.it('removes no peer when a key cannot be staged, in the apply or in the restore', () => {
		let key = key_file(true, { network: { wg1: WG1,
			a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', preshared_key: PSK }),
			b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32', preshared_key: PSK }) } });
		t.assert_match(key.wg.apply(key.conn, [ set_op({ public_key: PK2, allowed_ips: [ '10.0.0.3/32' ] }) ], []), /could not stage/);
		t.assert_match(key.wg.reconcile(key.conn, [ 'wg1' ]), /could not stage/);
		t.assert_deep_equal(key.commands, [ cmd([ 'wg', 'show', 'wg1', 'dump' ]) ]);
	});

	// The delete of a section that shares its key with b removed the key before b's key was staged.
	t.it('keeps a key that another section holds when the key of that section cannot be staged', () => {
		let key = key_file(true, { network: { wg1: WG1, b: peer({ public_key: PK, allowed_ips: '10.0.0.3/32', preshared_key: PSK }) } });
		t.assert_match(key.wg.apply(key.conn, [ { iface: 'wg1', action: 'remove', public_key: PK } ], []), /could not stage/);
		t.assert_deep_equal(key.commands, []);
	});
});

t.describe('wg.reconcile against logging wg and ip', () => {
	let reconcile = (uci, outputs) => run_wg(uci, "wg.reconcile(c, [ 'wg1' ])", outputs);

	// The kernel prints ::/0 as default.
	t.it('keeps a peer, and a route that the kernel spells another way', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: [ 'FD00:0::/64', '::/0' ], route_allowed_ips: '1',
		                                         endpoint_host: '192.0.2.1', endpoint_port: '51820' }) } },
		                  { 'wg|show|wg1|dump': sprintf("priv\tpub\t51820\toff\n%s\t(none)\t192.0.2.1:51820\tfd00::/64\t0\t0\t0\toff\n", PK),
		                    'ip|-6|route|show|dev|wg1|proto|static': "fd00::/64 metric 1024 pref medium\ndefault metric 1024 pref medium\n" });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|remove') >= 0 || index(l, '|del|') >= 0), []);
	});

	// The handler leaves out such a keepalive, and the restore must still set the peers that follow it
	// in uci.
	t.it('sets the peers after a hand-written peer whose keepalive wg cannot read', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', persistent_keepalive: '0;touch /tmp/x' }),
		                               b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32', endpoint_host: '192.0.2.1', endpoint_port: '51820' }) } });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0),
		                    [ 'wg|set|wg1|peer|' + PK + '|allowed-ips|10.0.0.2/32|preshared-key|/dev/null',
		                      set_of(PK2, '10.0.0.3/32') + '|endpoint|192.0.2.1:51820' ]);
	});

	// The handler skips a section without a key, and writes no AllowedIPs line for a peer without
	// allowed IPs, which LuCI leaves optional. The restore stopped at the first such section.
	t.it('skips a section without a key, sets a peer without allowed IPs with none, and sets the peers after them', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ allowed_ips: '10.0.0.2/32' }),
		                               b: peer({ public_key: '', allowed_ips: '10.0.0.4/32' }),
		                               c: peer({ public_key: PK }),
		                               d: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0),
		                    [ set_of(PK, ''), set_of(PK2, '10.0.0.3/32') ]);
	});

	// The restore refuses such a peer before anything changes in the kernel: wg would add the
	// prefixes to what the peer already holds instead of replacing them, or refuse the command.
	t.it('refuses a peer with an allowed_ips entry marked + or -, and runs nothing', () => {
		for (let v in [ '+10.0.0.0/8', '-fd00::/64', '\t+10.0.0.0/8' ]) {
			let r = reconcile({ network: { wg1: WG1,
			                               a: peer({ public_key: PK, allowed_ips: v }),
			                               b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } });
			t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1', v);
			t.assert_deep_equal(r.commands, [], v);
		}
	});
});

// A peer write through the handler and its transaction. With fail_reload the reload of the write
// fails and that of the restore passes, so the restore reconciles the interface.
function peer_write(uci, call, fail_reload, outputs, fail) {
	return run_wg(uci, sprintf("(function() { let n = 0; let h = require('handler').make(loadfile('src/resources/network.wireguard_peers.uc')(), { tx: { acquire: () => ({}), release: () => null, check_services: () => null, reload: () => (%J && n++ == 0) ? 'refused' : null } }); let r = h.%s; return sprintf('%%d %%s', r.status, r.body?.code ?? ''); })()",
	                           fail_reload, call), outputs, fail);
}

t.describe('a peer write on an up interface, against logging wg and ip', () => {
	const CTX = "{ request_id: '01hx0000000000000000000000' }";
	let escaped = () => ({ network: { wg1: WG1,
	                                  a: peer({ public_key: substr(PK, 0, 43) + '\\075', allowed_ips: [ '10.0.0.2/32' ] }),
	                                  b: peer({ public_key: PK2, allowed_ips: [ '10.0.0.3/32' ] }) } });

	// v4 (#308): the stored escape blocks every write of the peer, so the PATCH of another
	// field answers 422 and sets nothing in the kernel.
	t.it('refuses a PATCH of another field of a peer whose stored key holds an escape', () => {
		let r = peer_write(escaped(), "patch(c, " + CTX + ", 'a', { description: 'x' })", false);
		t.assert_equal(r.result, '422 validation_failed');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'wg|'), []);
	});

	// Its schema check read the whole patched document, which holds the stored key. v4 (#308):
	// the stored escape blocks the JSON Patch of another field as well, so both it and one
	// that sets such a key answer 422.
	t.it('refuses a JSON Patch of another field of a peer whose stored key holds an escape, and one that sets such a key', () => {
		const JCTX = "{ request_id: '01hx0000000000000000000000', json_patch: true }";
		let r = peer_write(escaped(), "patch(c, " + JCTX + ", 'a', [ { op: 'replace', path: '/description', value: 'x' } ])", false);
		t.assert_equal(r.result, '422 validation_failed');
		t.assert_deep_equal(r.commands, []);
		let ops = [ { op: 'replace', path: '/public_key', value: substr(PK, 0, 43) + '\\075' } ];
		r = peer_write(escaped(), sprintf("patch(c, %s, 'b', %J)", JCTX, ops), false);
		t.assert_equal(r.result, '422 validation_failed');
		t.assert_deep_equal(r.commands, []);
		ops = [ { op: 'add', path: '/bogus', value: 1 }, { op: 'remove', path: '/bogus' } ];
		t.assert_equal(peer_write(escaped(), sprintf("patch(c, %s, 'b', %J)", JCTX, ops), false).result, '200');
	});

	// The handler gives wg the entries that a comma separates, and routes each entry as uci holds it.
	// A PATCH that leaves allowed_ips as it is keeps that option, and a PUT of the read stores the entries.
	t.it('routes the entries that uci holds after a write of a peer whose allowed_ips holds a comma', () => {
		let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.0/8,192.168.0.0/16', route_allowed_ips: '1' }) } };
		let route = (verb, pfx) => sprintf('ip|route|%s|%s|dev|wg1|proto|static|scope|link', verb, pfx);
		let r = peer_write(uci, "patch(c, " + CTX + ", 'a', { description: 'x' })", false);
		t.assert_equal(r.result, '200');
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.0/8,192.168.0.0/16')) >= 0, r.commands);
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'), [ route('replace', '10.0.0.0/8') ]);
		let put = { interface: 'wg1', public_key: PK, allowed_ips: [ '10.0.0.0/8', '192.168.0.0/16' ], route_allowed_ips: true };
		r = peer_write(uci, sprintf("replace(c, %s, 'a', %J)", CTX, put), false);
		t.assert_equal(r.result, '200');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'), [ route('replace', '10.0.0.0/8'), route('replace', '192.168.0.0/16') ]);
	});
});

t.describe('wg.reconcile', () => {
	t.it('does nothing for an empty interface list', () => {
		let c = ubus.stub();
		t.assert_equal(wg.reconcile(c, []), null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});

	t.it('skips an interface that is down', () => {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.wg1', 'status', { up: false });
		t.assert_equal(wg.reconcile(c, ["wg1"]), null);
	});

	t.it('skips a name that could escape into a command', () => {
		let c = ubus.stub();
		t.assert_equal(wg.reconcile(c, ["wg1 && reboot"]), null);
		t.assert_equal(length(c._state.ubus_calls), 0);
	});
});

// route_allowed_ips asks netifd to install a route per allowed IP from its proto
// handler, so a peer-level apply has to install them or the peer sits in the
// kernel with no path to it. The mapping mirrors the handler.
t.describe('wg route prefixes', () => {
	t.it('turns a bare address into a host route', () => {
		t.assert_deep_equal(wg.route_prefixes(['10.0.0.0/24', '10.0.1.5'], true),
		                    [{ prefix: '10.0.0.0/24', v6: false },
		                     { prefix: '10.0.1.5/32', v6: false }]);
	});

	t.it('uses /128 for a bare IPv6 address', () => {
		t.assert_deep_equal(wg.route_prefixes(['fd00::1'], true),
		                    [{ prefix: 'fd00:0:0:0:0:0:0:1/128', v6: true }]);
	});

	t.it('marks an IPv6 prefix so the apply uses ip -6', () => {
		t.assert_true(wg.route_prefixes(['fd00:90::/64'], true)[0].v6);
	});

	// The flag defaults to false, and a peer without it gets no routes at all,
	// which is what netifd does.
	t.it('yields nothing when route_allowed_ips is not set', () => {
		t.assert_deep_equal(wg.route_prefixes(['10.0.0.0/24'], false), []);
	});

	t.it('skips entries that are not addresses or prefixes', () => {
		t.assert_deep_equal(wg.route_prefixes(['not-an-ip', '10.0.0.0/24'], true),
		                    [{ prefix: '10.0.0.0/24', v6: false }]);
	});

	t.it('tolerates a missing allowed_ips list', () => {
		t.assert_deep_equal(wg.route_prefixes(null, true), []);
	});

	// The catch-all forms are real: peers on production routers carry
	// allowed_ips=0.0.0.0/0. The kernel prints those back as "default", which is
	// handled where kernel output is read rather than treated as an address here.
	t.it('handles the catch-all prefixes', () => {
		t.assert_deep_equal(wg.route_prefixes(['0.0.0.0/0'], true),
		                    [{ prefix: '0.0.0.0/0', v6: false }]);
		t.assert_deep_equal(wg.route_prefixes(['::/0'], true),
		                    [{ prefix: '0:0:0:0:0:0:0:0/0', v6: true }]);
	});

	t.it('rejects an out-of-range prefix length', () => {
		t.assert_deep_equal(wg.route_prefixes(['10.0.0.0/33'], true), []);
		t.assert_deep_equal(wg.route_prefixes(['fd00::/129'], true), []);
	});

	t.it('spells one prefix one way, with the address masked', () => {
		t.assert_deep_equal(map(wg.route_prefixes(['FD00:0::1/64', 'fd00::/64', '10.0.0.1/24'], true), (r) => r.prefix),
		                    [ 'fd00:0:0:0:0:0:0:0/64', 'fd00:0:0:0:0:0:0:0/64', '10.0.0.0/24' ]);
	});

	// The handler takes the address before the first `/` and the length that ucode's int() reads
	// from what follows it, its leading decimal digits.
	t.it('routes each entry with the leading decimal digits of its length', () => {
		t.assert_deep_equal(map(wg.route_prefixes([ '10.98.152.0/24#/0x10', '10.98.152.0/0x10', '10.0.0.0/8\\054192.168.0.0/16', 'fd00::/0064' ], true), (r) => r.prefix),
		                    [ '10.98.152.0/24', '0.0.0.0/0', '10.0.0.0/8', 'fd00:0:0:0:0:0:0:0/64' ]);
	});
	t.it('routes a bare address as a host, as IPv6 only with a colon, and not an entry without a length it reads', () => {
		t.assert_deep_equal(map(wg.route_prefixes([ '10.0.0.7', 'fd00::1', '10.0.0.0/x', '10.0.0.0/8:1', '10.0.0.0/-1' ], true), (r) => r.prefix),
		                    [ '10.0.0.7/32', 'fd00:0:0:0:0:0:0:1/128' ]);
	});
});

// The withdraw path and the restore read peers from uci, where no validate() ran, and every
// command goes through a shell. A stored `::/0;id>x;` ran `id` as root before each argument was
// quoted. The commands run here with `ip` and `wg` as no-op shell functions.
t.describe('wg commands quote every argument', () => {
	function writes_nothing(argv) {
		let mk = fs.popen("mktemp -d /tmp/uapi-wg-quote.XXXXXX");
		let dir = trim(mk.read("all") ?? "");
		mk.close();
		t.assert_true(match(dir, /^\/tmp\/uapi-wg-quote\./) != null, "mktemp gave " + dir);
		let p = fs.popen(sprintf("ip() { :; }; wg() { :; }; cd %s || exit 1; %s; echo done",
		                         dir, wg.command_line(argv)));
		let out = p.read("all");
		p.close();
		let left = fs.lsdir(dir);
		system([ "rm", "-rf", dir ]);
		t.assert_equal(trim(out), "done");
		t.assert_deep_equal(left, []);
	}

	t.it('route_cmd runs no part of a stored prefix, interface or table', () => {
		writes_nothing(wg.route_cmd("del", "wg1;id>y;", { prefix: "::/0;id>x;", v6: true }, "77;id>z;"));
	});

	t.it('the peer set runs no part of a stored key, allowed IP or endpoint', () => {
		writes_nothing(wg.set_peer_argv("wg1;id>a;", {
			public_key: "k;id>b;", allowed_ips: [ "10.0.0.2/32;id>c;" ],
			endpoint_host: "x$(id>d)y", endpoint_port: 51820, persistent_keepalive: 25,
		}, null));
	});
});

// netifd puts an interface's routes in ip4table / ip6table when set, so a route
// installed into main would leave the peer without a path.
t.describe('wg.route_table', () => {
	function conn_with(opts) {
		return ubus.stub({ uci: { network: { wg1: { '.type': 'interface', ...opts } } } });
	}
	t.it('is null when the interface sets no table', () => {
		t.assert_equal(wg.route_table(conn_with({}), 'wg1', false), null);
	});
	t.it('reads ip4table for v4 and ip6table for v6', () => {
		let c = conn_with({ ip4table: '77', ip6table: '88' });
		t.assert_equal(wg.route_table(c, 'wg1', false), '77');
		t.assert_equal(wg.route_table(c, 'wg1', true), '88');
	});
	t.it('refuses a table name that could escape into a command', () => {
		t.assert_equal(wg.route_table(conn_with({ ip4table: '77; reboot' }), 'wg1', false), null);
	});
	t.it('is null for an interface that does not exist', () => {
		t.assert_equal(wg.route_table(ubus.stub(), 'nope', false), null);
	});
});

// wg needs an IPv6 endpoint bracketed to find the port. A write that sets a bracketed host is
// refused since 3.2.0, but a peer can keep a stored one, and double-bracketing made wg refuse it.
t.describe('wg IPv6 endpoint bracketing', () => {
	function endpoint_arg(host) { return wg.endpoint_arg(host, 51820); }

	t.it('brackets a bare IPv6 address', () => {
		t.assert_equal(endpoint_arg('fd00::1'), '[fd00::1]:51820');
	});
	t.it('leaves an already-bracketed address alone', () => {
		t.assert_equal(endpoint_arg('[fd00::1]'), '[fd00::1]:51820');
	});
	t.it('leaves IPv4 and hostnames alone', () => {
		t.assert_equal(endpoint_arg('198.51.100.7'), '198.51.100.7:51820');
		t.assert_equal(endpoint_arg('vpn.example.org'), 'vpn.example.org:51820');
	});
});

// The handler gives wg each value as uci holds it, leaves out a peer without a key with its routes,
// and takes a flag only as "1". Since openwrt ecd9120f04 it leaves out a value that wg would refuse:
// the peer for its key, the line for a preshared key, an endpoint or a keepalive.
const SERVICES = "https\t\t443/tcp\nhttps\t\t443/udp\nopenvpn\t\t1194/udp\t\tovpn\n";
let svc = t.load_with_fs({ ...fs, readfile: (p) => (p == '/etc/services') ? SERVICES : fs.readfile(p) }, [ 'wg' ]);

t.describe('wg reads and sets a peer as the handler does', () => {
	t.it('reads a keepalive as the handler gives it to wg, and -1 for one that it leaves out', () => {
		let v = [ 'off', 'OFF', '0', '025', '65535', '65536', '25 # x', ' 25', 'abc', [ '25' ], '', null ];
		t.assert_deep_equal(map(v, (k) => wg.keepalive(k)), [ 0, 0, 0, 25, 65535, -1, -1, -1, -1, -1, null, null ]);
	});
	t.it('reads a port as the handler gives it to wg, and 0 for one that it leaves the endpoint out for', () => {
		let v = [ '51820', '051820', '0', '65536', '+51820', ' 51820', 'https', 'openvpn', 'ovpn', 'nosuch', '', null ];
		t.assert_deep_equal(map(v, (p) => svc.endpoint_port(p)), [ 51820, 51820, 0, 0, 0, 0, 443, 1194, 0, 0, null, null ]);
	});
	// The handler reads busybox's nslookup, whose output holds a `Name:` line for each address that a
	// name has, and takes an address as it stands.
	t.it('reads a host as resolving as the handler does, and gives nslookup the host as one argument', () => {
		let hosts = [ 'vpn.example.org', 'nx.invalid', '192.0.2.1', 'fd00::1', "x$(id>d)y" ];
		let r = run_wg({ network: {} }, sprintf("sprintf('%%J', map(%J, (h) => wg.resolves(h)))", hosts),
		               { 'nslookup|vpn.example.org': "Server:\t\t127.0.0.1\nName:\tvpn.example.org\nAddress: 192.0.2.7\n" });
		t.assert_equal(r.result, '[ true, false, true, true, false ]');
		t.assert_deep_equal(r.commands, [ 'nslookup|vpn.example.org', 'nslookup|nx.invalid', "nslookup|x$(id>d)y" ]);
		r = run_wg({ network: {} }, "wg.resolves('1.2.3.4.5')");
		t.assert_deep_equal([ r.result, r.commands ], [ 'true', [] ]);
	});
	// wg refuses the whole config for a host that it cannot resolve, so the handler leaves out the
	// endpoint and keeps the peer and the interface. The write takes the host there, and answers that
	// the kernel did not get its endpoint.
	// The apply keeps the endpoint that the kernel holds for a stored port of 0, which the handler
	// leaves out.
	t.it('reports an endpoint left out for a port of 0', () => {
		let call = "(function() { let o = []; return wg.apply(c, [ { iface: 'wg1', action: 'remove', public_key: '%s' } ], [], o) ?? sprintf('%%J', o); })()";
		let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', endpoint_host: '192.0.2.1', endpoint_port: '0' }) } };
		t.assert_equal(run_wg(uci, sprintf(call, PK)).result, '[ "wg1" ]');
	});
	t.it('sets a peer whose host does not resolve without its endpoint, and reports the interface', () => {
		let set = { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.2/32' ], endpoint_host: 'nx.invalid', endpoint_port: 51820 };
		let call = "(function() { let o = []; return wg.apply(c, %J, [], o) ?? sprintf('%%J', o); })()";
		let r = run_wg({ network: { wg1: WG1 } }, sprintf(call, [ set ]));
		t.assert_equal(r.result, '[ "wg1" ]');
		t.assert_deep_equal(r.commands, [ 'nslookup|nx.invalid', set_of(PK, '10.0.0.2/32') ]);
		r = run_wg({ network: { wg1: WG1 } }, sprintf(call, [ { ...set, endpoint_host: 'vpn.example.org' } ]),
		           { 'nslookup|vpn.example.org': "Name:\tvpn.example.org\nAddress: 192.0.2.7\n" });
		t.assert_equal(r.result, '[ ]');
		t.assert_deep_equal(r.commands, [ 'nslookup|vpn.example.org', set_of(PK, '10.0.0.2/32') + '|endpoint|vpn.example.org:51820' ]);
		let again = { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', endpoint_host: 'nx.invalid', endpoint_port: '51820' }) };
		r = run_wg({ network: again }, sprintf(call, [ { iface: 'wg1', action: 'remove', public_key: PK } ]));
		t.assert_equal(r.result, '[ "wg1" ]');
		r = run_wg({ network: again }, "wg.reconcile(c, [ 'wg1' ])");
		t.assert_equal(r.result, 'ok');
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.2/32')) >= 0, r.commands);
	});
	t.it('sets nothing for a peer whose stored key is not a WireGuard key, and sets the others', () => {
		let ops = [ { iface: 'wg1', action: 'set', public_key: PK + ' # peer B', allowed_ips: [ '10.0.0.2/32' ] },
		            { iface: 'wg1', action: 'set', public_key: PK2, allowed_ips: [ '10.0.0.3/32' ] } ];
		let r = run_wg({ network: { wg1: WG1 } }, sprintf("wg.apply(c, %J)", ops));
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|peer|' + PK) >= 0), []);
		t.assert_true(index(r.commands, set_of(PK2, '10.0.0.3/32')) >= 0, r.commands);
	});
	t.it('sets a peer whose stored preshared key is not a WireGuard key without one, in an apply and a restore', () => {
		let a = peer({ public_key: PK, allowed_ips: '10.0.0.2/32', preshared_key: 'not-a-key' });
		let uci = { network: { wg1: WG1, a, b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } };
		let r = run_wg(uci, "wg.reconcile(c, [ 'wg1' ])");
		t.assert_equal(r.result, 'ok');
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.2/32')) >= 0, r.commands);
		t.assert_true(index(r.commands, set_of(PK2, '10.0.0.3/32')) >= 0, r.commands);
		r = run_wg(uci, sprintf("wg.apply(c, [ { iface: 'wg1', action: 'set', ...wg.to_peer(%J) } ])", a));
		t.assert_equal(r.result, 'ok');
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.2/32')) >= 0, r.commands);
	});
	t.it('marks an error of a value that the handler leaves out as not live, so it does not keep the interface down', () => {
		let view = { interface: 'wg1', public_key: 'not-a-key', endpoint_host: '192.0.2.1', endpoint_port: 0, persistent_keepalive: -1 };
		let peers = t.load_with({ wg }, [ '../resources/network.wireguard_peers' ]);
		let live = () => map(peers.validate_new(view), (e) => [ e.field, e.live ]);
		t.assert_deep_equal(live(), [ [ 'public_key', false ], [ 'endpoint_port', false ], [ 'persistent_keepalive', false ] ]);
		view.public_key = replace(PK, /4=$/, '5=');
		t.assert_deep_equal(live()[0], [ 'public_key', true ]);
	});
	// The handler reads the port with `endpoint_port ?? '51820'`. The restore left the endpoint out,
	// where the restart of the handler had set it.
	t.it('sets a stored peer with a host and no port with port 51820, as the handler does', () => {
		let s = peer({ public_key: PK, allowed_ips: '10.0.0.2/32', endpoint_host: '192.0.2.1' });
		t.assert_equal(wg.to_peer(s).endpoint_port, null);
		let r = run_wg({ network: { wg1: WG1, a: s } }, "wg.reconcile(c, [ 'wg1' ])");
		t.assert_equal(r.result, 'ok');
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.2/32') + '|endpoint|192.0.2.1:51820') >= 0, r.commands);
		r = run_wg({ network: { wg1: WG1, a: s } }, sprintf("wg.apply(c, [ { iface: 'wg1', action: 'set', ...wg.to_peer(%J) } ])", s));
		t.assert_deep_equal(r.commands, [ set_of(PK, '10.0.0.2/32') + '|endpoint|192.0.2.1:51820' ]);
	});
	// The handler takes an empty value, which only a hand edit of the file stores, as a port, which it
	// refuses.
	t.it('leaves out the endpoint of an empty port, and reads no port for it', () => {
		let s = peer({ public_key: PK, allowed_ips: '10.0.0.2/32', endpoint_host: '192.0.2.1', endpoint_port: '' });
		t.assert_equal(wg.endpoint_port(''), null);
		t.assert_equal(wg.to_peer(s).endpoint_port, 0);
		let r = run_wg({ network: { wg1: WG1, a: s } }, "wg.reconcile(c, [ 'wg1' ])");
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.2/32')) >= 0, r.commands);
	});
	t.it('takes a flag as on only when it holds 1', () => {
		let v = [ '1', 'true', 'yes', 'on', [ '1' ], '0', null ];
		t.assert_deep_equal(map(v, (f) => wg.peer_flag(f)), [ true, false, false, false, false, false, false ]);
	});
	t.it('withdraws a route that only a peer without a key wants', () => {
		let uci = { network: { wg1: WG1, k: peer({ allowed_ips: '10.0.0.0/24', route_allowed_ips: '1' }) } };
		let ops = sprintf("wg.apply(c, %J)", [ { iface: 'wg1', action: 'remove', public_key: PK,
		                                          prev_allowed_ips: [ '10.0.0.0/24' ], prev_route_allowed_ips: true } ]);
		let del = (r) => filter(r.commands, (l) => match(l, /^ip\|route\|del/));
		t.assert_deep_equal(del(run_wg(uci, ops)), [ 'ip|route|del|10.0.0.0/24|dev|wg1|proto|static|scope|link' ]);
	});
	t.it('refuses a list entry whose marker follows a space, and sets nothing', () => {
		let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: [ ' +10.0.0.0/8' ] }) } };
		let r = run_wg(uci, "wg.reconcile(c, [ 'wg1' ])");
		t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0), []);
	});
	t.it('restores a peer whose disabled holds true', () => {
		let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', disabled: 'true' }) } };
		let sets = (r) => filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0);
		t.assert_deep_equal(sets(run_wg(uci, "wg.reconcile(c, [ 'wg1' ])")), [ set_of(PK, '10.0.0.2/32') ]);
	});
	t.it('takes a prefix length with a leading zero, which the handler reads in base 10 as wg does', () => {
		let peers = t.load_with({ wg }, [ '../resources/network.wireguard_peers' ]);
		t.assert_deep_equal(filter(peers.validate_new({ allowed_ips: [ '10.0.0.0/08', 'fd00::/010' ], route_allowed_ips: true }),
		                           (e) => substr(e.field, 0, 11) == 'allowed_ips'), []);
	});
});

// The handler restarts the interface on every peer change, so the apply waits for the setup that the
// reload started. netifd answers each status call with the next reading, then the last.
t.describe('wg waits for the restart of the handler', () => {
	let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32' }) } };
	let apply = sprintf("wg.apply(c, %J)", [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.2/32' ] } ]);
	let PENDING = { up: false, pending: true }, DOWN = { up: false }, UP = { up: true };
	function settle(readings, call) {
		return run_wg(uci, sprintf("(function() { let r = %J, n = 0; c.set_ubus_response('network.interface.wg1', 'status', () => r[min(n++, length(r) - 1)]); let out = %s; return sprintf('%%s/%%d', out ?? 'ok', n); })()",
		                           readings, call));
	}
	let applied = (r) => length(filter(r.commands, (l) => index(l, 'wg|set|wg1|peer|') == 0)) > 0;
	function readings(list, until) {
		let c = ubus.stub(), n = 0;
		c.set_ubus_response('network.interface.wg1', 'status', () => list[min(n++, length(list) - 1)]);
		return wg.settled_up(c, 'wg1', until);
	}

	t.it('applies once a pending setup comes up', () => {
		let r = settle([ PENDING, UP ], apply);
		t.assert_equal(r.result, 'ok/2');
		t.assert_true(applied(r), 'no wg set');
	});
	t.it('skips an interface that reads down twice, half a second apart', () => {
		let r = settle([ DOWN ], apply);
		t.assert_equal(r.result, 'ok/2');
		t.assert_false(applied(r), 'wg set on a down interface');
	});
	t.it('reads null for a setup still pending at the deadline, and false for a down interface', () => {
		t.assert_equal(readings([ PENDING ], time()), null);
		t.assert_equal(readings([ DOWN ], time()), false);
		t.assert_equal(readings([ PENDING, DOWN, PENDING, UP ], time() + 8), true);
	});
	t.it('fails the write when the setup never settles, after the 8 s of the deadline', () => {
		let r = settle([ PENDING ], apply);
		let m = match(r.result, /^interface wg1 holds a setup pending that never ended after the reload, so its peers cannot be applied\/([0-9]+)$/);
		// time() counts whole seconds, so the deadline ends 7 to 8 s after the first reading: 15 to
		// 17 readings half a second apart, and fewer on a slow runner. Two would be a give-up.
		t.assert_true(m != null && int(m[1]) >= 10 && int(m[1]) <= 17, r.result);
		t.assert_false(applied(r), 'wg set on an interface that never settled');
	});
	// netifd's next setup reads uci, which no longer gives the peer access, so a revoke keeps its
	// commit where a restore would give the access back.
	t.it('skips the interface of a remove when the setup never settles, and keeps the write', () => {
		let r = settle([ PENDING ], sprintf("wg.apply(c, %J)", [ { iface: 'wg1', action: 'remove', public_key: PK } ]));
		let m = match(r.result, /^ok\/([0-9]+)$/);
		t.assert_true(m != null && int(m[1]) >= 10 && int(m[1]) <= 17, r.result);
		t.assert_deep_equal(r.commands, []);
	});
});

// One stored peer that wg refuses keeps the whole interface down, so a wait for the restart of the
// handler cannot tell a restart that the write broke from one that was broken before it. The apply
// names such a peer, as the peer resource judges it on what the write committed, and netifd sets
// the peers from uci at the next setup.
t.describe('wg names a stored peer that keeps its interface down', () => {
	let PENDING = { up: false, pending: true }, UP = { up: true };
	let set = { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.2/32' ] };
	let mine = peer({ public_key: PK, allowed_ips: '10.0.0.2/32' });
	let bad = peer({ public_key: PK2, allowed_ips: '10.0.0.3/33' });
	// The error of the apply, its applied and blocked lists, and the number of status reads of wg1.
	function apply(network, ops, status) {
		let call = sprintf("(function() { let n = 0, a = [], b = []; c.set_ubus_response('network.interface.wg1', 'status', () => (n++, %J)); c.set_ubus_response('network.interface.wg2', 'status', %J); let e = wg.apply(c, %J, a, [], b); return sprintf('%%J', [ e, a, b, n ]); })()",
		                   status, UP, ops);
		let r = run_wg({ network }, call);
		return { result: json(r.result), commands: r.commands };
	}
	let sets = (r) => filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0);

	t.it('skips the interface with no wait, and names the peer', () => {
		let r = apply({ wg1: WG1, mine, bad }, [ set ], PENDING);
		t.assert_deep_equal(r.result, [ null, [], [ 'wg1/bad' ], 0 ]);
		t.assert_deep_equal(r.commands, []);
	});
	t.it('names no peer that is disabled or has no key, and none of a disabled interface', () => {
		for (let network in [ { wg1: WG1, mine, bad: { ...bad, disabled: '1' } }, { wg1: WG1, mine, bad: { ...bad, public_key: null } },
		                      { wg1: { ...WG1, disabled: '1' }, mine, bad }, { wg1: { ...WG1, disabled: 'true' }, mine, bad } ])
			t.assert_deep_equal(apply(network, [ set ], UP).result[2], [], network);
	});
	t.it('applies one interface of a batch and names the peer that keeps the other down', () => {
		let r = apply({ wg1: WG1, wg2: WG1, mine, bad, two: { ...mine, '.type': 'wireguard_wg2' } },
		              [ set, { ...set, iface: 'wg2' } ], PENDING);
		t.assert_deep_equal(r.result, [ null, [ 'wg2' ], [ 'wg1/bad' ], 0 ]);
		t.assert_deep_equal(sets(r), [ replace(set_of(PK, '10.0.0.2/32'), '|wg1|', '|wg2|') ]);
	});
	// A write of network/interfaces restarts the interface and changes no peer.
	t.it('a check names the peer, and waits for nothing on a clean interface', () => {
		let check = [ { iface: 'wg1', action: 'check' } ];
		t.assert_deep_equal(apply({ wg1: WG1, mine, bad }, check, UP).result, [ null, [], [ 'wg1/bad' ], 0 ]);
		t.assert_deep_equal(apply({ wg1: WG1, mine }, check, UP).result, [ null, [], [], 0 ]);
		let r = apply({ wg1: WG1, mine }, [ ...check, set ], UP);
		t.assert_deep_equal(r.result, [ null, [ 'wg1' ], [], 1 ]);
		t.assert_deep_equal(sets(r), [ set_of(PK, '10.0.0.2/32') ]);
	});
	t.it('a write that fixed or deleted the peer finds none, and waits for the restart', () => {
		let r = apply({ wg1: WG1, mine, bad: { ...bad, allowed_ips: '10.0.0.3/32' } }, [ set ], UP);
		t.assert_deep_equal(r.result, [ null, [ 'wg1' ], [], 1 ]);
		r = apply({ wg1: WG1, mine }, [ { iface: 'wg1', action: 'remove', public_key: PK2 } ], UP);
		t.assert_deep_equal(r.result, [ null, [ 'wg1' ], [], 1 ]);
		t.assert_deep_equal(r.commands, [ 'wg|set|wg1|peer|' + PK2 + '|remove' ]);
	});
	// musl refuses the address, so wg refuses the config of the whole interface. A write refuses such a
	// zone only when it sends it, because an interface can exist at one time and not at another.
	t.it('names a peer whose zone names no interface of the router, when the handler gives wg its endpoint', () => {
		let zoned = (host, port) => ({ wg1: WG1, mine, z: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32', endpoint_host: host, endpoint_port: port }) });
		t.assert_deep_equal(apply(zoned('fe80::1%nosuchdev0', '51820'), [ set ], UP).result[2], [ 'wg1/z' ]);
		t.assert_deep_equal(apply(zoned('fe80::1%lo', '51820'), [ set ], UP).result[2], []);
		for (let port in [ '', 'nosuchservice' ])
			t.assert_deep_equal(apply(zoned('fe80::1%nosuchdev0', port), [ set ], UP).result[2], [], port);
	});
});
