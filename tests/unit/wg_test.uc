let t = require('harness');
let ubus = require('bus');
let wg = require('wg');
let fs = require('fs');

const PK = 'QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=';
const PK2 = 'TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=';
const LONG = replace(sprintf('%600s', ''), ' ', 'x');

// `wg` and `ip` are scripts here that log each command with its arguments joined by `|`, and print
// the file named after the command when a test wrote one, so a test reads what an apply runs
// without a WireGuard interface. A command that matches the shell pattern `fail` exits 1. The call
// runs in a child, whose PATH finds the scripts first. `load` is the expression that loads wg there.
function run_wg(uci, call, outputs, fail, load) {
	let mk = fs.popen("mktemp -d /tmp/uapi-wg-apply.XXXXXX");
	let dir = trim(mk.read("all") ?? "");
	mk.close();
	for (let name in [ "wg", "ip" ]) {
		fs.writefile(dir + "/" + name, sprintf("#!/bin/sh\nIFS='|'\necho \"%s|$*\" >> %s/log\ncase \"%s|$*\" in %s) exit 1 ;; esac\ncat \"%s/%s|$*\" 2>/dev/null\nexit 0\n",
		                                       name, dir, name, fail ?? "''", dir, name));
		fs.chmod(dir + "/" + name, 0o755);
	}
	for (let cmd, text in outputs ?? {}) fs.writefile(dir + "/" + cmd, text);
	let script = sprintf("let wg = %s; let c = require('bus').stub({ uci: %J }); c.set_ubus_response('network.interface.wg1', 'status', { up: true }); print(%s ?? 'ok');",
	                     load ?? "require('wg')", uci, call);
	let p = fs.popen(sprintf("PATH=%s:\"$PATH\" ucode -L tests -L src/lib -e %s 2>&1", dir, wg.shellquote(script)));
	let result = trim(p.read("all") ?? "");
	p.close();
	let log = fs.readfile(dir + "/log") ?? "";
	system([ "rm", "-rf", dir ]);
	return { result, commands: filter(split(log, "\n"), (l) => l != "") };
}
// wg as it runs where netifd has the ucode proto handler of OpenWrt main, here and in the child of
// run_wg.
const UCODE_WG = "require('harness').load_with_fs({ ...require('fs'), access: (p) => p == '/lib/netifd/proto/wireguard.uc' || require('fs').access(p) }, [ 'wg' ])";
let uc = loadstring('return ' + UCODE_WG)();
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

t.describe('wg.kernel_key', () => {
	t.it('reads the key as wg reads the config of wireguard.sh', () => {
		for (let v in [ PK, [ PK ], PK + ' ', ' ' + PK + '\t# peer B', PK + '\n# peer B\n', PK + ' #' + LONG ])
			t.assert_equal(wg.kernel_key(v), PK, v);
	});
	t.it('is null when the kernel can hold no such peer', () => {
		for (let v in [ 'not-a-key', [ PK, PK ], null, '#' + PK, substr(PK, 0, 42) + '5=' ])
			t.assert_equal(wg.kernel_key(v), null, v);
	});
	// wireguard.sh hands the config to wg through busybox's printf %b, so `\075` stands for the `=`
	// of a valid key, and a NUL byte ends the line for wg. `\532` is `+` and `2`, because octal stops
	// below 256, and `\x2bB` is `+` and `B`, because hex stops after two digits.
	t.it('reads a key with an escape as printf %b expands it for wg', () => {
		for (let v in [ substr(PK, 0, 43) + '\\075', substr(PK, 0, 43) + '\\0075', substr(PK, 0, 43) + '\\x3d',
		                PK + '\\0junk', PK + '\\t\\r', PK + '\\n' ])
			t.assert_equal(wg.kernel_key(v), PK, v);
		t.assert_equal(wg.kernel_key(substr(PK, 0, 40) + '\\532' + substr(PK, 42)), substr(PK, 0, 40) + '+2' + substr(PK, 42));
		t.assert_equal(wg.kernel_key(substr(PK, 0, 40) + '\\x2b' + substr(PK, 41)), substr(PK, 0, 40) + '+' + substr(PK, 41));
		for (let v in [ substr(PK, 0, 43) + '\\=', substr(PK, 0, 43) + '\\x3g', substr(PK, 0, 20) + '\\c' + substr(PK, 20),
		                substr(PK, 0, 43) + '\\0750' ])
			t.assert_equal(wg.kernel_key(v), null, v);
	});
	// ifup gives wg every line of the value and nothing after `\c`, which `wg set` of one peer cannot
	// do, and a value longer than the bound is not expanded.
	t.it('is false for a value that gives wg more config than its key, or that is too long to expand', () => {
		for (let v in [ PK + '\nAllowedIPs=10.0.0.3/32', PK + '\\nAllowedIPs=10.0.0.3/32', PK + '\\n[Peer]\\nPublicKey=' + PK2,
		                PK + '\\c', PK + '\\c' + PK2, PK + ' #' + LONG + '\\t' ])
			t.assert_equal(wg.kernel_key(v), false, v);
	});
	// The expansion runs under the lock of `network`, and a request can carry a long value.
	t.it('reads a long value in bounded time', () => {
		let long = replace(sprintf('%160000s', ''), ' ', 'A');
		let t0 = clock();
		t.assert_equal(wg.kernel_key(long + '\\075'), false);
		t.assert_equal(wg.kernel_keys(long + '\\075'), false);
		t.assert_equal(wg.kernel_key(long), null);
		t.assert_equal(length(wg.allowed_ips(long + '\\054')), 1);
		let t1 = clock();
		t.assert_true((t1[0] - t0[0]) + (t1[1] - t0[1]) / 1e9 < 1, 'took longer than 1 s');
	});
});

t.describe('wg.kernel_keys', () => {
	t.it('reads the first line and each later PublicKey line, as wg reads them', () => {
		t.assert_deep_equal(wg.kernel_keys(PK + '\n[Peer]\n publicKey = ' + PK2 + ' # b\nAllowedIPs=0.0.0.0/0'), [ PK, PK2 ]);
		t.assert_deep_equal(wg.kernel_keys('not-a-key\nPublicKey=' + PK2), [ PK2 ]);
		t.assert_deep_equal(wg.kernel_keys([ PK ]), [ PK ]);
		t.assert_deep_equal(wg.kernel_keys(null), []);
	});
	t.it('expands the escapes before it splits the lines, and reads no line after `\\c`', () => {
		t.assert_deep_equal(wg.kernel_keys(PK + '\nPublicKey=' + substr(PK2, 0, 43) + '\\075'), [ PK, PK2 ]);
		t.assert_deep_equal(wg.kernel_keys(PK + '\\n[Peer]\\nPublicKey=' + PK2), [ PK, PK2 ]);
		t.assert_deep_equal(wg.kernel_keys(PK + '\\c\nPublicKey=' + PK2), [ PK ]);
	});
});

t.describe('wg.allowed_ips', () => {
	t.it('splits at each space and each comma, as wg splits the line that wireguard.sh writes', () => {
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8 fd00::/8'), [ '10.0.0.0/8', 'fd00::/8' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\t10.1.0.0/16'), [ '10.0.0.0/8\t10.1.0.0/16' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8  10.1.0.0/16 '), [ '10.0.0.0/8', '', '10.1.0.0/16', '' ]);
		t.assert_deep_equal(wg.allowed_ips([ '10.0.0.0/8 10.1.0.0/16', 'fd00::/8' ]), [ '10.0.0.0/8', '10.1.0.0/16', 'fd00::/8' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8,10.1.0.0/16'), [ '10.0.0.0/8', '10.1.0.0/16' ]);
	});
	t.it('drops an empty list item, as config_get does, and what follows a #, as wg does', () => {
		t.assert_deep_equal(wg.allowed_ips([ '10.0.0.0/8', '', '10.1.0.0/16' ]), [ '10.0.0.0/8', '10.1.0.0/16' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8#c 10.1.0.0/16'), [ '10.0.0.0/8' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8 #c'), [ '10.0.0.0/8', '' ]);
	});
	t.it('is null when wireguard.sh writes no AllowedIPs line', () => {
		t.assert_equal(wg.allowed_ips(null), null);
		t.assert_equal(wg.allowed_ips(''), null);
		t.assert_equal(wg.allowed_ips([ '' ]), null);
	});
	// wireguard.sh writes `AllowedIPs=` for any value that is not empty, and wg refuses a line that
	// holds nothing once it cuts it, so the whole interface stays down.
	t.it('reads one empty entry when wg reads nothing from the line that wireguard.sh writes', () => {
		for (let v in [ '#c', '\\0', '\\04310.0.0.0/8', [ '#c', '10.0.0.0/8' ] ])
			t.assert_deep_equal(wg.allowed_ips(v), [ '' ], v);
	});
	// `\054` and `\x2c` are commas for wg, `\043` is a #, a NUL byte ends the line, and `\040` is a
	// space, which wg strips. A backslash before the space that config_get joins a list with stays.
	t.it('expands the escapes of printf %b, as wg gets the line', () => {
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\\054192.168.0.0/16'), [ '10.0.0.0/8', '192.168.0.0/16' ]);
		t.assert_deep_equal(wg.allowed_ips([ '10.0.0.0/8\\x2c10.1.0.0/16', 'fd00::/8' ]), [ '10.0.0.0/8', '10.1.0.0/16', 'fd00::/8' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\\043 10.1.0.0/16'), [ '10.0.0.0/8' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\\0 10.1.0.0/16'), [ '10.0.0.0/8' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.1\\04010.0.0.2'), [ '10.0.0.1 10.0.0.2' ]);
		t.assert_deep_equal(wg.allowed_ips([ '10.0.0.1\\', '10.0.0.2' ]), [ '10.0.0.1\\', '10.0.0.2' ]);
	});
	// ifup gives wg each later line as more config, and nothing after `\c`, which no entry can say.
	t.it('reads unexpanded a value that printf %b gives a second line or the end of the config, or that is too long', () => {
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\\n[Peer]'), [ '10.0.0.0/8\\n[Peer]' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\\c 10.1.0.0/16'), [ '10.0.0.0/8\\c', '10.1.0.0/16' ]);
		t.assert_deep_equal(wg.allowed_ips('10.0.0.0/8\\054' + LONG), [ '10.0.0.0/8\\054' + LONG ]);
	});
	// No address holds such a byte, and a byte above 127 broke the UTF-8 of the response.
	t.it('reads unexpanded a value that printf %b gives a byte that is not printable ASCII', () => {
		for (let v in [ '10.0.0.1\\377', '10.0.0.1\\303\\251', '10.0.0.1\\x01 10.0.0.2' ])
			t.assert_deep_equal(wg.allowed_ips(v), split(replace(v, ' ', ','), ','), v);
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
	t.it('splits a scalar allowed_ips into words, as wireguard.sh does', () => {
		t.assert_deep_equal(wg.to_peer({ allowed_ips: '10.0.0.2/32 10.0.1.0/24' }).allowed_ips,
		                    ['10.0.0.2/32', '10.0.1.0/24']);
	});
	// wireguard.sh joins the list with spaces and makes each space a comma, so wg gets two prefixes
	// from such an entry, and one entry from two prefixes that a tab separates.
	t.it('gives the entries that wg gets from a list entry of two prefixes, or from a tab', () => {
		t.assert_deep_equal(wg.to_peer({ allowed_ips: [ '10.0.0.2/32 10.0.1.0/24' ] }).allowed_ips,
		                    ['10.0.0.2/32', '10.0.1.0/24']);
		t.assert_deep_equal(wg.to_peer({ allowed_ips: '10.0.0.2/32\t10.0.1.0/24' }).allowed_ips,
		                    ['10.0.0.2/32\t10.0.1.0/24']);
	});
	t.it('reads the port and the keepalive as numbers, so nothing else reaches the command', () => {
		let p = wg.to_peer({ public_key: PK, allowed_ips: ['10.0.0.2/32'], endpoint_port: ' 51820',
		                     persistent_keepalive: ' 25 ' });
		t.assert_equal(p.endpoint_port, 51820);
		t.assert_equal(p.persistent_keepalive, 25);
		t.assert_equal(wg.to_peer({ persistent_keepalive: '0;touch /tmp/x' }).persistent_keepalive, -1);
		t.assert_equal(wg.to_peer({ persistent_keepalive: 'off' }).persistent_keepalive, 0);
	});
	t.it('reads a list endpoint_host as config_get gives it to wireguard.sh', () => {
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
	let unclaimed = (uci, outputs) => run_wg(uci, 'sprintf("%J", wg.unclaimed(c))', outputs);
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
	t.it('lists no peer that a stored key with an escape claims, keyed as wg reads it', () => {
		let r = unclaimed({ network: { wg1: WG1,
		                               a: peer({ public_key: substr(PK, 0, 43) + '\\075', allowed_ips: '10.0.0.2/32' }) } },
		                  dump_of([ line(PK, '(none)', '10.0.0.2/32', 'off') ]));
		t.assert_equal(r.result, '[ ]');
	});
	t.it('lists no peer that a later PublicKey line of a stored key claims', () => {
		let r = unclaimed({ network: { wg1: WG1,
		                               a: peer({ public_key: 'x\nPublicKey=' + PK, allowed_ips: '10.0.0.2/32' }) } },
		                  dump_of([ line(PK, '(none)', '10.0.0.2/32', 'off') ]));
		t.assert_equal(r.result, '[ ]');
	});
	// A failed read never looks like an empty kernel: an interface netifd does not report up is
	// not dumped at all, and a dump in another shape reads as none.
	t.it('dumps no interface that is down, and reads a dump in another shape as none', () => {
		let r = unclaimed({ network: { wg2: { '.type': 'interface', '.anonymous': false, proto: 'wireguard' } } });
		t.assert_equal(r.result, '[ ]');
		t.assert_deep_equal(r.commands, []);
		r = unclaimed({ network: { wg1: WG1 } }, { 'wg|show|wg1|dump': "priv\tpub\t51820\toff\textra\n" });
		t.assert_equal(r.result, '[ ]');
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

	t.it('checks each interface once however many ops it has', () => {
		let c = down_conn();
		wg.apply(c, [
			{ iface: "wg1", action: "remove", public_key: PK },
			{ iface: "wg1", action: "remove", public_key: PK },
			{ iface: "wg1", action: "remove", public_key: PK },
		]);
		let status = filter(c._state.ubus_calls, function(x) { return x[1] == "status"; });
		t.assert_equal(length(status), 1);
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

	t.it('removes the peer of a key that uci holds as a list', () => {
		let c = ubus.stub();
		c.set_ubus_response('network.interface.wg1', 'status', { up: true });
		let err = wg.apply(c, [ { iface: "wg1", action: "remove", public_key: [ PK ] } ]);
		t.assert_true(index(err ?? "", "wg set remove on wg1 failed") == 0, err);
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

	t.it('removes every key that a multi-line public_key gives the kernel, with a newline or its escape', () => {
		for (let v in [ PK + '\n[Peer]\nPublicKey=' + PK2, PK + '\\n[Peer]\\nPublicKey=' + PK2 ]) {
			let r = apply({ network: { wg1: WG1 } }, [ { iface: 'wg1', action: 'remove', public_key: v } ]);
			t.assert_equal(r.result, 'ok', v);
			t.assert_deep_equal(r.commands, [ 'wg|set|wg1|peer|' + PK + '|remove', 'wg|set|wg1|peer|' + PK2 + '|remove' ], v);
		}
	});

	// The remove of a stored key with a backslash answered 500 on an up interface.
	t.it('removes the key that wg read from a stored key with an escape', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'remove', public_key: substr(PK, 0, 43) + '\\075' } ]);
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(r.commands, [ 'wg|set|wg1|peer|' + PK + '|remove' ]);
	});

	// uapi does not say which key wg reads from such a value, so it refuses rather than leave a key
	// that it did not remove.
	t.it('refuses the remove of a value with a backslash that is too long to expand, and runs nothing', () => {
		let r = apply({ network: { wg1: WG1 } }, [ { iface: 'wg1', action: 'remove', public_key: PK + ' #' + LONG + '\\t' } ]);
		t.assert_true(index(r.result, 'refusing to remove') == 0, r.result);
		t.assert_deep_equal(r.commands, []);
	});

	// `wg set` of one peer cannot give the kernel the other lines, or leave out what follows `\c`.
	t.it('refuses to set a peer whose value gives wg more config than its key, and runs nothing', () => {
		for (let v in [ PK + '\\nAllowedIPs=0.0.0.0/0', PK + '\nAllowedIPs=0.0.0.0/0', PK + '\\c' ]) {
			let r = apply({ network: { wg1: WG1 } }, [ { iface: 'wg1', action: 'set', public_key: v, allowed_ips: [ '10.0.0.2/32' ] } ]);
			t.assert_true(index(r.result, 'refusing to apply a peer with a malformed public key') == 0, r.result);
			t.assert_deep_equal(r.commands, [], v);
		}
	});

	// ifup sets the sections in uci order, so the last one with the key wins.
	t.it('a remove sets again each other enabled section with the key, in uci order', () => {
		let r = apply({ network: { wg1: WG1,
		                           a: peer({ public_key: PK, allowed_ips: [ '10.0.0.2/32' ] }),
		                           b: peer({ public_key: PK, allowed_ips: [ '10.0.0.3/32' ], disabled: [ '1' ] }),
		                           c: peer({ public_key: PK2, allowed_ips: [ '10.0.0.5/32' ] }),
		                           d: peer({ public_key: PK + ' ', allowed_ips: '10.0.0.4/32' }) } },
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

	t.it('gives wg the key and the host without the whitespace that wg strips from the config', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'set', public_key: ' ' + PK, allowed_ips: [ '10.0.0.2/32' ],
		                  endpoint_host: ' fd00::1 ', endpoint_port: 51820 } ]);
		t.assert_deep_equal(r.commands, [ set_of(PK, '10.0.0.2/32') + '|endpoint|[fd00::1]:51820' ]);
	});

	t.it('refuses a preshared key that wg cannot read, and runs nothing', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.2/32' ], preshared_key: 'not-a-key' } ]);
		t.assert_true(index(r.result, 'refusing to apply') == 0, r.result);
		t.assert_deep_equal(r.commands, []);
	});

	// A marker entry makes the whole list an incremental update to wg, which adds its prefixes to
	// what the peer already holds, or refuses the command.
	t.it('refuses a peer with an allowed_ips entry marked + or -, and runs nothing', () => {
		for (let ips in [ [ '+10.0.0.0/8' ], [ '-fd00::/64' ], [ '10.0.0.5/32', '-10.0.0.6/32' ] ]) {
			let r = apply({ network: { wg1: WG1 } },
			              [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: ips } ]);
			t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1', ips);
			t.assert_deep_equal(r.commands, [], ips);
		}
	});

	// A stored value whose printf %b expansion wg reads as a marker reaches the apply through the
	// sections that a remove sets again, with no validate() in front of it.
	t.it('a remove that sets a stored marker entry again refuses the peer, and runs nothing', () => {
		let r = apply({ network: { wg1: WG1,
		                           a: peer({ public_key: PK, allowed_ips: '\\05310.0.0.0/8' }) } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK } ]);
		t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1');
		t.assert_deep_equal(r.commands, []);
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

	// netifd reads 0064 in octal, so the route that ifup installed is /52.
	t.it('withdraws the route of a stored prefix length with 3 or more digits', () => {
		let r = apply({ network: { wg1: WG1 } },
		              [ { iface: 'wg1', action: 'remove', public_key: PK, prev_allowed_ips: [ 'fd00::/0064', '10.0.0.0/024' ],
		                  prev_route_allowed_ips: true } ]);
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'),
		                    [ 'ip|-6|route|del|fd00:0:0:0:0:0:0:0/52|dev|wg1|proto|static',
		                      'ip|route|del|10.0.0.0/20|dev|wg1|proto|static|scope|link' ]);
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
	t.it('keeps a peer whose key uci holds as a list, and a route that the kernel spells another way', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: [ PK ], allowed_ips: [ 'FD00:0::/64', '::/0' ], route_allowed_ips: [ '1' ],
		                                         endpoint_host: '192.0.2.1', endpoint_port: '51820' }) } },
		                  { 'wg|show|wg1|dump': sprintf("priv\tpub\t51820\toff\n%s\t(none)\t192.0.2.1:51820\tfd00::/64\t0\t0\t0\toff\n", PK),
		                    'ip|-6|route|show|dev|wg1|proto|static': "fd00::/64 metric 1024 pref medium\ndefault metric 1024 pref medium\n" });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|remove') >= 0 || index(l, '|del|') >= 0), []);
	});

	// ifup refuses the whole config for such a keepalive, but the restore must still set the peers
	// that follow it in uci.
	t.it('sets the peers after a hand-written peer whose keepalive wg cannot read', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', persistent_keepalive: '0;touch /tmp/x' }),
		                               b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32', endpoint_host: '192.0.2.1', endpoint_port: '51820' }) } });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0),
		                    [ 'wg|set|wg1|peer|' + PK + '|allowed-ips|10.0.0.2/32|preshared-key|/dev/null',
		                      set_of(PK2, '10.0.0.3/32') + '|endpoint|192.0.2.1:51820' ]);
	});

	// ifup gives wg both prefixes of such an entry, and routes both, so the restore does too.
	t.it('sets and routes both prefixes of a list entry that holds two', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: [ '10.0.0.2/32 10.0.1.0/24' ], route_allowed_ips: '1' }) } });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0), [ set_of(PK, '10.0.0.2/32,10.0.1.0/24') ]);
		for (let pfx in [ '10.0.0.2/32', '10.0.1.0/24' ])
			t.assert_equal(length(filter(r.commands, (l) => match(l, /^ip\|.*route/) && index(l, '|' + pfx + '|') >= 0)), 1, pfx);
	});

	// wireguard.sh writes no [Peer] for a section without a key, and no AllowedIPs line for a peer
	// without allowed IPs, which LuCI leaves optional. The restore stopped at the first such section.
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

	// ifup sets the key that printf %b gives wg, and sets no peer under a key that wg cannot read.
	// The restore removed the first and stopped at both.
	t.it('keeps and sets a peer whose key holds an escape under the key that wg reads, skips a key that wg cannot read, and sets the peers after them', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: substr(PK, 0, 43) + '\\075', allowed_ips: '10.0.0.2/32',
		                                         endpoint_host: '192.0.2.1', endpoint_port: '51820' }),
		                               b: peer({ public_key: substr(PK2, 0, 43) + '\\Q', allowed_ips: '10.0.0.4/32' }),
		                               c: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } },
		                  { 'wg|show|wg1|dump': sprintf("priv\tpub\t51820\toff\n%s\t(none)\t192.0.2.1:51820\t10.0.0.2/32\t0\t0\t0\toff\n", PK) });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|remove') >= 0 || index(l, '|allowed-ips|') >= 0),
		                    [ set_of(PK, '10.0.0.2/32') + '|endpoint|192.0.2.1:51820', 'wg|set|wg1|peer|' + PK2 + '|remove',
		                      set_of(PK2, '10.0.0.3/32') ]);
	});

	// ifup gives wg the two prefixes that `\054` separates, and routes the word as uci holds it.
	t.it('sets the allowed IPs that printf %b gives wg, and routes the words of the option', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: '10.0.0.0/8\\054192.168.0.0/16', route_allowed_ips: '1' }) } });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0), [ set_of(PK, '10.0.0.0/8,192.168.0.0/16') ]);
		t.assert_deep_equal(filter(r.commands, (l) => match(l, /^ip\|route\|replace/)),
		                    [ 'ip|route|replace|10.0.0.0/16|dev|wg1|proto|static|scope|link' ]);
	});

	// ifup sets no peer at all for a preshared key that wg cannot read. Set with /dev/null, the peer
	// lost the key that the kernel held for it, and a refusal stopped the restore of the peers after it.
	t.it('keeps a peer whose preshared key wg cannot read as the kernel holds it, and sets the peers after it', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', preshared_key: 'not-a-key' }),
		                               b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } },
		                  { 'wg|show|wg1|dump': sprintf("priv\tpub\t51820\toff\n%s\t(none)\t(none)\t10.0.0.2/32\t0\t0\t0\toff\n", PK) });
		t.assert_equal(r.result, 'ok');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|peer|' + PK + '|') >= 0), []);
		t.assert_true(index(r.commands, set_of(PK2, '10.0.0.3/32')) >= 0, r.commands);
	});

	t.it('sets the peers after a peer whose preshared key wg cannot read, and fails when the kernel does not hold that peer', () => {
		let r = reconcile({ network: { wg1: WG1,
		                               a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', preshared_key: 'not-a-key' }),
		                               b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } });
		t.assert_equal(r.result, 'not restoring a peer with a malformed preshared key on wg1');
		t.assert_deep_equal(filter(r.commands, (l) => index(l, '|peer|' + PK + '|') >= 0), []);
		t.assert_true(index(r.commands, set_of(PK2, '10.0.0.3/32')) >= 0, r.commands);
	});

	// The restore refuses such a peer before anything changes in the kernel: wg would add the
	// prefixes to what the peer already holds instead of replacing them, or refuse the command.
	t.it('refuses a peer with an allowed_ips entry marked + or -, and runs nothing', () => {
		for (let v in [ '+10.0.0.0/8', '-fd00::/64', '\\05310.0.0.0/8' ]) {
			let r = reconcile({ network: { wg1: WG1,
			                               a: peer({ public_key: PK, allowed_ips: v }),
			                               b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } });
			t.assert_equal(r.result, 'refusing to apply a peer with an allowed_ips entry marked + or - on wg1', v);
			t.assert_deep_equal(r.commands, [], v);
		}
	});

	// The kernel then holds what the request gave it, under a key that the restore cannot set. In a
	// batch, a later operation of another peer is the one that fails.
	t.it('fails, after it sets the other peers, when an operation of the request named such a peer that the kernel holds', () => {
		let uci = { network: { wg1: WG1,
		                       a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', preshared_key: 'not-a-key' }),
		                       b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } };
		let dump = { 'wg|show|wg1|dump': sprintf("priv\tpub\t51820\toff\n%s\t(none)\t(none)\t10.0.0.2/32\t0\t0\t0\toff\n", PK) };
		for (let ops in [ [ { iface: 'wg1', action: 'set', public_key: PK } ],
		                  [ { iface: 'wg1', action: 'remove', public_key: PK + ' ' }, { iface: 'wg1', action: 'set', public_key: PK2 } ] ]) {
			let r = run_wg(uci, sprintf("wg.reconcile(c, [ 'wg1' ], %J)", ops), dump);
			t.assert_equal(r.result, 'not restoring a peer with a malformed preshared key on wg1', ops);
			t.assert_deep_equal(filter(r.commands, (l) => index(l, '|peer|' + PK + '|') >= 0), [], ops);
			t.assert_true(index(r.commands, set_of(PK2, '10.0.0.3/32')) >= 0, r.commands);
		}
		t.assert_equal(run_wg(uci, sprintf("wg.reconcile(c, [ 'wg1' ], %J)", [ { iface: 'wg1', action: 'set', public_key: PK2 } ]), dump).result, 'ok');
	});

	// The restore set the first key of such a value with the allowed IPs of the section and removed
	// the others, where ifup gives them to the keys after it. It refuses, as it did before it read an
	// escape, and changes nothing in the kernel.
	t.it('refuses, before it changes the kernel, a stored value that gives wg more config than its key', () => {
		for (let v in [ PK + '\\n[Peer]\\nPublicKey=' + PK2, PK + '\n[Peer]\nPublicKey=' + PK2, PK + '\\c' ]) {
			let r = reconcile({ network: { wg1: WG1, a: peer({ public_key: v, allowed_ips: '10.0.0.2/32' }),
			                               b: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }) } },
			                  { 'wg|show|wg1|dump': sprintf("priv\tpub\t51820\toff\n%s\t(none)\t(none)\t(none)\t0\t0\t0\toff\n", PK2) });
			t.assert_equal(r.result, 'refusing to apply a peer with a malformed public key on wg1', v);
			t.assert_deep_equal(r.commands, [], v);
			r = reconcile({ network: { wg1: WG1, a: peer({ public_key: PK2, allowed_ips: '10.0.0.3/32' }),
			                           b: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', preshared_key: v }) } });
			t.assert_equal(r.result, 'refusing to apply a peer with a malformed preshared key on wg1', v);
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

	// The kernel holds the peer under the key that wireguard.sh gave wg. v4 (#308): LuCI's
	// model, the stored escape blocks the PATCH, which answers 422 and changes nothing in the
	// kernel; the DELETE path does not validate, so it removes the peer and the key wg read.
	t.it('disables and deletes a peer whose stored key holds an escape, and removes the key that wg read', () => {
		let r = peer_write(escaped(), "patch(c, " + CTX + ", 'a', { disabled: true })", false);
		t.assert_equal(r.result, '422 validation_failed');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'wg|'), []);
		r = peer_write(escaped(), "remove(c, " + CTX + ", 'a')", false);
		t.assert_equal(r.result, '204');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'wg|'), [ 'wg|set|wg1|peer|' + PK + '|remove' ]);
	});

	// The restore after a failed write of another peer stopped at the peer with the escape.
	t.it('restores a failed write of another peer of the interface', () => {
		let r = peer_write(escaped(), "patch(c, " + CTX + ", 'b', { description: 'x' })", true);
		t.assert_equal(r.result, '500 reload_failed_restored');
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.2/32')) >= 0, r.commands);
	});

	// v4 (#308): the stored escape blocks every write of the peer, so the PATCH of another
	// field answers 422 and sets nothing in the kernel.
	t.it('refuses a PATCH of another field of a peer whose stored key holds an escape', () => {
		let r = peer_write(escaped(), "patch(c, " + CTX + ", 'a', { description: 'x' })", false);
		t.assert_equal(r.result, '422 validation_failed');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'wg|'), []);
	});

	t.it('deletes a peer whose stored key gives wg two keys, and removes both', () => {
		let uci = escaped();
		uci.network.a.public_key = PK + '\\n[Peer]\\nPublicKey=' + PK2;
		delete uci.network.b;
		let r = peer_write(uci, "remove(c, " + CTX + ", 'a')", false);
		t.assert_equal(r.result, '204');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'wg|'),
		                    [ 'wg|set|wg1|peer|' + PK + '|remove', 'wg|set|wg1|peer|' + PK2 + '|remove' ]);
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

	// The PATCH set the key and the new allowed IP in the kernel before its route failed, and the
	// restore answered that it had restored the peer that it left out.
	t.it('a failed write that set a peer whose stored preshared key wg cannot read answers that the restore failed', () => {
		let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', preshared_key: 'not-a-key' }) } };
		let body = { preshared_key: PK2, allowed_ips: [ '10.0.0.2/32', '10.9.0.0/16' ], route_allowed_ips: true };
		let r = peer_write(uci, sprintf("patch(c, %s, 'a', %J)", CTX, body), false,
		                   { 'wg|show|wg1|dump': sprintf("priv\tpub\t51820\toff\n%s\t(none)\t(none)\t10.0.0.2/32\t0\t0\t0\toff\n", PK) },
		                   'ip\\|route\\|replace\\|*');
		t.assert_equal(r.result, '500 reload_failed_unrecovered');
		t.assert_true(index(r.commands, 'wg|set|wg1|peer|' + PK + '|allowed-ips|10.0.0.2/32,10.9.0.0/16|persistent-keepalive|0|preshared-key|/var/run/uapi.wg.psk') >= 0,
		              r.commands);
	});

	// ifup gives wg the entries that printf %b expands and routes the words that uci holds. A PATCH
	// that leaves allowed_ips as it is keeps that option, and a PUT of the read stores the entries.
	t.it('routes the words that uci holds after a write of a peer whose allowed_ips holds an escape', () => {
		let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.0/8\\054192.168.0.0/16', route_allowed_ips: '1' }) } };
		let route = (verb, pfx) => sprintf('ip|route|%s|%s|dev|wg1|proto|static|scope|link', verb, pfx);
		let r = peer_write(uci, "patch(c, " + CTX + ", 'a', { description: 'x' })", false);
		t.assert_equal(r.result, '200');
		t.assert_true(index(r.commands, set_of(PK, '10.0.0.0/8,192.168.0.0/16')) >= 0, r.commands);
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'), [ route('replace', '10.0.0.0/16') ]);
		let put = { interface: 'wg1', public_key: PK, allowed_ips: [ '10.0.0.0/8', '192.168.0.0/16' ], route_allowed_ips: true };
		r = peer_write(uci, sprintf("replace(c, %s, 'a', %J)", CTX, put), false);
		t.assert_equal(r.result, '200');
		t.assert_deep_equal(filter(r.commands, (l) => substr(l, 0, 3) == 'ip|'),
		                    [ route('replace', '10.0.0.0/8'), route('replace', '192.168.0.0/16'), route('del', '10.0.0.0/16') ]);
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
// kernel with no path to it. The mapping mirrors wireguard.sh.
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

	t.it('rejects a prefix length followed by anything', () => {
		t.assert_deep_equal(wg.route_prefixes(['::/0;id>x;'], true), []);
	});

	t.it('spells one prefix one way, with the address masked', () => {
		t.assert_deep_equal(map(wg.route_prefixes(['FD00:0::1/64', 'fd00::/64', '10.0.0.1/24'], true), (r) => r.prefix),
		                    [ 'fd00:0:0:0:0:0:0:0/64', 'fd00:0:0:0:0:0:0:0/64', '10.0.0.0/24' ]);
	});

	// wireguard.sh routes the words of the option, which printf %b never sees, and takes the address
	// before the first `/` of a word and the length after the last, in the family of its case.
	// netifd reads the length with strtoul in base 0, or, with a dot, as an IPv4 mask whose leading
	// ones it counts.
	t.it('reads the length of a word as netifd does', () => {
		t.assert_deep_equal(map(wg.route_prefixes([ '10.0.0.0/', '10.0.0.0/0x10', '10.0.0.0/+8', 'fd00::/0x40', '10.0.0.0/255.255.0.0',
		                                           '10.0.0.0/255.0.255.0', '10.0.0.0/255.255', '10.0.0.0/8#/255.255.0.0' ], true), (r) => r.prefix),
		                    [ '0.0.0.0/0', '10.0.0.0/16', '10.0.0.0/8', 'fd00:0:0:0:0:0:0:0/64', '10.0.0.0/16', '10.0.0.0/8', '10.0.0.0/8',
		                      '10.0.0.0/16' ]);
		t.assert_deep_equal(wg.route_prefixes([ '10.0.0.0/-8', '10.0.0.0/+', '10.0.0.0/0x', '10.0.0.0/256.0.0.0', '10.0.0.0/1.2.3.4.5',
		                                        'fd00::/255.0.0.0', '10.0.0.0/0x21' ], true), []);
	});

	t.it('routes a word with an escape as the case of wireguard.sh splits it', () => {
		t.assert_deep_equal(wg.route_prefixes([ '10.0.0.0/8\\054192.168.0.0/16', 'fd00::/8\\05410.0.0.0/16' ], true),
		                    [ { prefix: '10.0.0.0/16', v6: false }, { prefix: 'fd00:0:0:0:0:0:0:0/16', v6: true } ]);
		t.assert_deep_equal(wg.route_prefixes([ '10.0.0.0/8\\054fd00::/16', '10.0.0.1,10.0.0.2', '10.0.0.1\\054', 'a/b:c' ], true), []);
	});

	// netifd installs no route for a length that base 0 cannot read, such as 08.
	t.it('reads a stored prefix length in base 0, as netifd does for the route', () => {
		t.assert_deep_equal(map(wg.route_prefixes(['fd00::/012', 'fd00::/0064', '10.0.0.0/024', 'fd00::/08',
		                                           'fd00::/0128', '10.0.0.0/100'], true), (r) => r.prefix),
		                    [ 'fd00:0:0:0:0:0:0:0/10', 'fd00:0:0:0:0:0:0:0/52', '10.0.0.0/20' ]);
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

// The ucode proto handler of OpenWrt main gives wg each value as uci holds it, routes each entry of
// allowed_ips with the length that int() reads, leaves out a peer without a key with its routes, and
// takes a flag only as "1".
t.describe('wg under the ucode handler', () => {
	let prefixes = (entries) => map(uc.route_prefixes(entries, true), (r) => r.prefix);

	t.it('expands no escape in a key', () => {
		t.assert_equal(uc.kernel_key(substr(PK, 0, 43) + '\\075'), null);
		t.assert_equal(uc.kernel_key(PK + ' # peer B'), PK);
		t.assert_equal(uc.kernel_key(PK + '\nPublicKey=' + PK2), false);
		t.assert_deep_equal(uc.kernel_keys(PK + '\\nPublicKey=' + PK2), []);
	});
	t.it('reads a list entry as one entry and an option as its words, and expands no escape', () => {
		t.assert_deep_equal(uc.allowed_ips([ '10.0.0.0/24 10.0.1.7' ]), [ '10.0.0.0/24 10.0.1.7' ]);
		t.assert_deep_equal(uc.allowed_ips(' 10.0.0.0/24\t 10.0.1.7 '), [ '10.0.0.0/24', '10.0.1.7' ]);
		t.assert_deep_equal(uc.allowed_ips('10.0.0.0/8\\054192.168.0.0/16'), [ '10.0.0.0/8\\054192.168.0.0/16' ]);
		t.assert_equal(uc.allowed_ips(''), null);
	});
	t.it('cuts the line at the first #, with the entries after it', () => {
		t.assert_deep_equal(uc.allowed_ips([ '10.0.0.0/24#/0x10', '10.0.1.7' ]), [ '10.0.0.0/24' ]);
	});
	t.it('routes each entry with the leading decimal digits of its length', () => {
		t.assert_deep_equal(prefixes([ '10.98.152.0/24#/0x10', '10.98.152.0/0x10', '10.0.0.0/8\\054192.168.0.0/16' ]),
		                    [ '10.98.152.0/24', '0.0.0.0/0', '10.0.0.0/8' ]);
	});
	t.it('routes a bare address as a host, as IPv6 only with a colon, and not an entry without a length it reads', () => {
		t.assert_deep_equal(prefixes([ '10.0.0.7', 'fd00::1', '10.0.0.0/x', '10.0.0.0/8:1', '10.0.0.0/-1' ]),
		                    [ '10.0.0.7/32', 'fd00:0:0:0:0:0:0:1/128' ]);
	});
	t.it('takes a flag as on only when it holds 1', () => {
		let v = [ '1', 'true', 'yes', 'on', [ '1' ], '0', null ];
		t.assert_deep_equal(map(v, (f) => uc.peer_flag(f)), [ true, false, false, false, false, false, false ]);
		t.assert_deep_equal(map(v, (f) => wg.peer_flag(f)), [ true, true, true, true, true, false, false ]);
	});
	t.it('withdraws a route that only a peer without a key wants', () => {
		let uci = { network: { wg1: WG1, k: peer({ allowed_ips: '10.0.0.0/24', route_allowed_ips: '1' }) } };
		let ops = sprintf("wg.apply(c, %J)", [ { iface: 'wg1', action: 'remove', public_key: PK,
		                                          prev_allowed_ips: [ '10.0.0.0/24' ], prev_route_allowed_ips: true } ]);
		let del = (r) => filter(r.commands, (l) => match(l, /^ip\|route\|del/));
		t.assert_deep_equal(del(run_wg(uci, ops, null, null, UCODE_WG)), [ 'ip|route|del|10.0.0.0/24|dev|wg1|proto|static|scope|link' ]);
		t.assert_deep_equal(del(run_wg(uci, ops)), []);
	});
	t.it('restores a peer whose disabled holds true', () => {
		let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32', disabled: 'true' }) } };
		let sets = (r) => filter(r.commands, (l) => index(l, '|allowed-ips|') >= 0);
		t.assert_deep_equal(sets(run_wg(uci, "wg.reconcile(c, [ 'wg1' ])", null, null, UCODE_WG)), [ set_of(PK, '10.0.0.2/32') ]);
		t.assert_deep_equal(sets(run_wg(uci, "wg.reconcile(c, [ 'wg1' ])")), []);
	});
	t.it('takes a prefix length with a leading zero, which the handler reads in base 10 as wg does', () => {
		let peers = t.load_with({ wg: uc }, [ '../resources/network.wireguard_peers' ]);
		t.assert_deep_equal(filter(peers.validate_new({ allowed_ips: [ '10.0.0.0/08', 'fd00::/010' ], route_allowed_ips: true }),
		                           (e) => substr(e.field, 0, 11) == 'allowed_ips'), []);
	});
});

// The ucode handler restarts the interface on every peer change, so the apply waits for the setup
// that the reload started. netifd answers each status call with the next reading, then the last.
t.describe('wg waits for the restart of the ucode handler', () => {
	let uci = { network: { wg1: WG1, a: peer({ public_key: PK, allowed_ips: '10.0.0.2/32' }) } };
	let apply = sprintf("wg.apply(c, %J)", [ { iface: 'wg1', action: 'set', public_key: PK, allowed_ips: [ '10.0.0.2/32' ] } ]);
	let PENDING = { up: false, pending: true }, DOWN = { up: false }, UP = { up: true };
	function settle(readings, call, load) {
		return run_wg(uci, sprintf("(function() { let r = %J, n = 0; c.set_ubus_response('network.interface.wg1', 'status', () => r[min(n++, length(r) - 1)]); let out = %s; return sprintf('%%s/%%d', out ?? 'ok', n); })()",
		                           readings, call), null, null, load ?? UCODE_WG);
	}
	let applied = (r) => length(filter(r.commands, (l) => index(l, 'wg|set|wg1|peer|') == 0)) > 0;
	function readings(list, until) {
		let c = ubus.stub(), n = 0;
		c.set_ubus_response('network.interface.wg1', 'status', () => list[min(n++, length(list) - 1)]);
		return uc.settled_up(c, 'wg1', until);
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
		t.assert_match(r.result, /^interface wg1 holds a setup pending that never ended after the reload, so its peers cannot be applied\/1[6-9]$/);
		t.assert_false(applied(r), 'wg set on an interface that never settled');
	});
	t.it('reads a pending interface once under wireguard.sh, and skips it', () => {
		let r = settle([ PENDING, UP ], apply, "require('wg')");
		t.assert_equal(r.result, 'ok/1');
		t.assert_false(applied(r), 'wg set on a pending interface under wireguard.sh');
	});
});
