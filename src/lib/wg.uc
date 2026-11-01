let fs = require('fs');
let values = require('values');

// netifd reads wireguard peers with `config_foreach wireguard_<iface>` inside the
// proto setup step, so a peer edit leaves the parent `interface` section untouched
// and `/etc/init.d/network reload` converges nothing: the peer is committed to uci
// and never reaches the kernel, and deleting one does not revoke it.
//
// The obvious alternative, asking netifd to re-apply via `network.interface.<i>
// renew`, was built and measured first. It is unusable: the ubus call returns in
// 0 ms so a failed apply is undetectable, and a failure runs proto_setup_failed,
// which takes the whole interface down. One peer with an unresolvable endpoint
// dropped a working tunnel and its healthy peers while the API answered 200. A
// down+up restart behaves identically and also interrupts a healthy tunnel every
// time. `wg` is the only per-peer path: a bad peer fails alone, synchronously,
// and leaves everything else running. netifd and LuCI both reach for it the same
// way, because WireGuard exposes no ubus service of its own.
const SAFE_IFACE_RE = /^[A-Za-z0-9_-]+$/;
const WG_KEY_RE = regexp("^" + values.WG_KEY_PATTERN + "$");

// Same idiom as LuCI's wireguard backend: single-quote and escape embedded quotes.
function shellquote(s) {
	return "'" + replace("" + (s ?? ""), "'", "'\\''") + "'";
}

// Every command goes through here with each argument quoted, so no caller has to remember to:
// the restore after a failed write and the route withdraw read peers straight from uci, where no
// validate() ran. route_cmd once put a prefix that passed its check unquoted into `ip route`, and
// `::/0;id>x;` ran `id` as root.
function command_line(argv) {
	return join(" ", map(argv, shellquote));
}

function run(argv) {
	let p = fs.popen(command_line(argv) + " 2>&1", "r");
	if (p == null) return { ok: false, output: "could not exec wg" };
	let output = p.read("all") ?? "";
	let code = p.close();
	return { ok: code == 0, code: code, output: trim(output) };
}

const ESCAPES = { a: 7, b: 8, e: 27, f: 12, n: 10, r: 13, t: 9, v: 11, "\\": 92 };

// printf_b() walks a value byte by byte under the lock of `network`. A key line that escapes each of
// its 44 characters as `\0ooo` is 220 bytes long. A value with a backslash that is longer than this
// bound is not expanded, and uapi then does not say which key or allowed IPs wg reads from it.
const ESCAPED_MAX = 512;

// wireguard.sh hands its config to wg through busybox's `printf %b`, which expands the escapes of
// every value in it as coreutils/printf.c and libbb/process_escape_sequence.c do: `\c` ends the
// output, a 0 right after the backslash is skipped when an octal digit follows it, up to three
// octal digits up to 255 or `\x` and up to two hex digits give one byte, the letters of ESCAPES and
// a second backslash give their character, and a backslash before anything else stays.
function printf_b(s) {
	let out = [];
	for (let i = 0; i < length(s); ) {
		let c = substr(s, i++, 1);
		if (c != "\\") {
			push(out, c);
			continue;
		}
		let next = substr(s, i, 1);
		if (next == "c") return { text: join("", out), stopped: true };
		if (next == "0" && match(substr(s, i + 1, 1), /^[0-7]$/)) i++;
		let oct = match(substr(s, i, 3), /^[0-7]+/)?.[0];
		let hexd = (next == "x") ? match(substr(s, i + 1, 2), /^[0-9A-Fa-f]+/)?.[0] : null;
		if (oct != null) {
			if (int(oct, 8) > 255) oct = substr(oct, 0, 2);
			push(out, chr(int(oct, 8)));
			i += length(oct);
		}
		else if (hexd != null) {
			push(out, chr(hex(hexd)));
			i += 1 + length(hexd);
		}
		else if (ESCAPES[next] != null) {
			push(out, chr(ESCAPES[next]));
			i++;
		}
		else
			push(out, "\\");
	}
	return { text: join("", out), stopped: false };
}

// The lines that wg reads for a stored value from the config of wireguard.sh, which joins a list
// with spaces, each cut at `#` and without whitespace. wg_line() also ends a line at a NUL byte, as
// wg's parser does, because ucode's regex functions stop there. `stopped` when `\c` ended the
// config in the value. null for a value that is not expanded.
function config_lines(v) {
	let s = values.config_get(v);
	if (type(s) != "string") return { lines: [], stopped: false };
	let x = (index(s, "\\") < 0) ? { text: s, stopped: false } : (length(s) <= ESCAPED_MAX) ? printf_b(s) : null;
	if (x == null) return null;
	return { lines: map(split(x.text, "\n"), (l) => values.wg_line(l)), stopped: x.stopped };
}

// A stored key as wg reads it: the first line. null when that is not a WireGuard key, so the
// kernel can hold no such peer. false when the value gives wg more config than the key, in a later
// line or by ending the config with `\c`, or is not expanded: `wg set` cannot give the kernel what
// ifup gave it then.
function kernel_key(v) {
	let c = config_lines(v);
	if (c == null) return false;
	let first = c.lines[0];
	if (first == null || !match(first, WG_KEY_RE)) return null;
	return (c.stopped || length(filter(slice(c.lines, 1), (l) => l != "")) > 0) ? false : first;
}

// Each later line of a stored public_key is a line of the config, so one that reads `PublicKey=`
// sets a key too, of this peer or of a peer that a `[Peer]` line before it adds. false for a value
// that is not expanded.
function kernel_keys(v) {
	let c = config_lines(v);
	if (c == null) return false;
	let out = [];
	for (let i = 0; i < length(c.lines); i++) {
		let l = c.lines[i];
		let key = (i == 0) ? l : (lc(substr(l, 0, 10)) == "publickey=") ? substr(l, 10) : null;
		if (key != null && match(key, WG_KEY_RE)) push(out, key);
	}
	return out;
}

// The allowed IPs that wg reads from a stored value: config_get joins a list with spaces,
// wireguard.sh makes each space a comma, printf %b expands the line, so `\054` separates two entries
// and `\040` does not, and wg cuts the line at a NUL byte and at `#` and splits it at commas. wg also
// strips the whitespace, which an entry keeps here so that a tab between two prefixes shows.
// wireguard.sh writes the line for any value that is not empty, and wg refuses the line when nothing
// is left of it, so that reads as one empty entry, which a write refuses too. A value that the
// expansion would give a second line, the end of the config or a byte that is not printable ASCII,
// none of which an address holds, or that is too long to expand, reads unexpanded, so that its
// backslash shows in an entry and the response stays valid UTF-8.
function allowed_ips(v) {
	let s = values.config_get(v);
	if (type(s) != "string" || s == "") return null;
	s = replace(s, " ", ",");
	let x = (index(s, "\\") >= 0 && length(s) <= ESCAPED_MAX) ? printf_b(s) : null;
	let t = (x != null && !x.stopped && index(x.text, "\n") < 0) ? split(split(x.text, chr(0))[0], "#")[0] : null;
	return split((t != null && match(t, /^[ -~]*$/)) ? t : split(s, "#")[0], ",");
}

function to_peer(section) {
	return {
		public_key: section.public_key,
		allowed_ips: allowed_ips(section.allowed_ips) ?? [],
		endpoint_host: values.config_get(section.endpoint_host),
		endpoint_port: values.service_port(section.endpoint_port, () => fs.readfile("/etc/services")),
		// Read as wg reads it, since a stored value reaches here from uci without passing through
		// validate(), and set_peer_argv() gives it to `wg set` with %d.
		persistent_keepalive: values.wg_keepalive(section.persistent_keepalive),
		preshared_key: section.preshared_key,
	};
}

function peer_sections(conn, iface) {
	let want = "wireguard_" + iface;
	let out = [];
	conn.uci_foreach('network', null, function(s) {
		if (s['.type'] != want) return;
		// A disabled peer is one netifd omits when it builds the config, so the
		// kernel should not carry it either.
		if (values.shell_bool(values.config_get(s.disabled), false)) return;
		push(out, s);
	});
	return out;
}

// dump_print() in src/show.c of wireguard-tools, 1.0.20250521 in OpenWrt 25.12, prints the
// interface on the first line in 4 tab-separated fields, its private key first, then a line per peer
// of 8: public key, preshared key, endpoint, allowed IPs joined with commas, latest handshake in
// epoch seconds or 0, rx bytes, tx bytes and keepalive. An unset key, endpoint or allowed IPs prints
// `(none)`, and no keepalive `off`. The output holds both keys, so it must never be logged, and only
// the fields below leave here. The fields are read by position, so a dump in another shape reads as
// a failed one, null: a field more after the public key would put the preshared key in `endpoint`,
// and a line skipped would read as a peer that the kernel does not hold.
function kernel_peers(iface) {
	let r = run([ "wg", "show", iface, "dump" ]);
	if (!r.ok) return null;
	let peers = {};
	let lines = split(r.output, "\n");
	if (length(split(lines[0], "\t")) != 4) return null;
	for (let i = 1; i < length(lines); i++) {
		let f = split(lines[i], "\t");
		if (length(f) != 8 || !match(f[0], WG_KEY_RE)) return null;
		peers[f[0]] = {
			endpoint: (f[2] == "(none)") ? null : f[2],
			allowed_ips: (f[3] == "(none)") ? [] : split(f[3], ","),
			persistent_keepalive: (f[7] == "off") ? 0 : int(f[7]),
			latest_handshake: int(f[4]),
			rx_bytes: int(f[5]),
			tx_bytes: int(f[6]),
		};
	}
	return peers;
}

// `wg set` takes a preshared key only as a file, never as an argument, which is
// the behaviour we want: the secret never appears in the command line and so
// never in ps. Mode is set before the content is written, as elsewhere, so the
// key never exists on disk under the default umask. The path is fixed because
// every uci transaction holds the per-package exclusive lock for `network`,
// so two peer applies cannot be in flight at once. It is on tmpfs.
const PSK_PATH = "/var/run/uapi.wg.psk";

function psk_file(value) {
	try { fs.unlink(PSK_PATH); } catch (e) {}
	let f = fs.open(PSK_PATH, "w");
	if (!f) return null;
	try { fs.chmod(PSK_PATH, 384); } catch (e) {}  // 0600
	// wg reads an empty key file as no key, so a write that the tmpfs cannot hold set the peer
	// without its preshared key and answered 200. close() drops fclose's error, and flush() answers
	// inverted on the ucode that CI runs, so the size on disk is what shows it.
	let content = value + "\n";
	f.write(content);
	f.close();
	if (fs.stat(PSK_PATH)?.size != length(content)) {
		fs.unlink(PSK_PATH);
		return null;
	}
	return PSK_PATH;
}

// One `wg set` carrying the whole desired state. It is atomic: a bad endpoint
// fails the command and changes nothing, so the peer keeps working on its old
// config. Keepalive and preshared key are spelled out, with 0 and /dev/null as
// the explicit clears, because `wg set` merges and would otherwise leave a stale
// value behind that uci no longer has. An empty allowed-ips is the clear of the
// list, for a peer without allowed IPs, which LuCI allows and ifup sets.
// An IPv6 endpoint has to be bracketed for wg to find the port. A peer that LuCI's RPC, /raw or a
// shell stored can hold one bracketed already, and without the guard "[fd00::1]" became
// "[[fd00::1]]" and wg refused the peer.
function endpoint_arg(host, port) {
	if (index(host, ":") >= 0 && substr(host, 0, 1) != "[")
		host = "[" + host + "]";
	return sprintf("%s:%d", host, port);
}

function set_peer_argv(iface, peer, psk_path) {
	let argv = [ "wg", "set", iface, "peer", peer.public_key, "allowed-ips", join(",", peer.allowed_ips) ];
	// -1 is a stored value that wg refuses, which another writer stored or a PUT sent back from its
	// read: a write that leaves it as it is and the restore give it here. The restore sets every peer from uci and stops at the first one
	// that fails, so a refusal here kept every later peer of the interface out of the kernel. The
	// kernel keeps its keepalive.
	if (peer.persistent_keepalive !== -1)
		push(argv, "persistent-keepalive", sprintf("%d", peer.persistent_keepalive ?? 0));
	push(argv, "preshared-key", psk_path ?? "/dev/null");
	if (peer.endpoint_host != null && peer.endpoint_host != "")
		push(argv, "endpoint", endpoint_arg(peer.endpoint_host, peer.endpoint_port ?? 51820));
	return argv;
}

function remove_peer(iface, pubkey) {
	return run([ "wg", "set", iface, "peer", pubkey, "remove" ]);
}

// The length of a route as parse_netmask_string() in netifd reads it: strtoul in base 0, which skips
// leading whitespace and takes a sign, or, with a dot, an IPv4 mask that inet_aton reads, whose
// leading ones it counts. null for a length that netifd refuses.
function netmask_len(s, v6) {
	let num = (t) => match(t, /^(0[xX][0-9A-Fa-f]+|0[0-7]*|[1-9][0-9]*)$/) ? int(t, 0) : null;
	if (index(s, ".") < 0) {
		if (s == "") return 0;
		let m = match(s, /^[[:space:]]*([+-]?)(.*)$/);
		let n = num(m[2]);
		return (m[1] == "-" && n !== 0) ? null : n;
	}
	let parts = map(split(s, "."), num);
	if (v6 || length(parts) > 4 || length(filter(parts, (p) => type(p) != "int")) > 0
	    || length(filter(slice(parts, 0, -1), (p) => p > 255)) > 0 || parts[-1] >= 1 << (8 * (5 - length(parts))))
		return null;
	let mask = parts[-1], ones = 0;
	for (let i = 0; i < length(parts) - 1; i++) mask |= parts[i] << (24 - 8 * i);
	while (ones < 32 && ((mask >> (31 - ones)) & 1)) ones++;
	return ones;
}

// `route_allowed_ips` asks netifd to install a route per allowed IP, which it
// does from the proto handler, so a peer-level apply has to install them too or
// the peer is present in the kernel with no path to it. Mirrors the mapping in
// wireguard.sh: a bare address becomes a host route.
//
// `prefix` is one spelling of the route that netifd installs: the length as netifd reads it, and the
// address masked to it, because `ip route` refuses an IPv4 prefix with host bits. Routes are
// compared by it. Compared as written, a PUT that respelled `FD00::/64` deleted the route that it
// had just installed, and so did a rollback for a route that the kernel prints in another spelling
// than uci holds.
function route_prefix(allowed_ip) {
	if (type(allowed_ip) != "string") return null;
	let parts = split(allowed_ip, "/");
	if (length(parts) > 2) return null;
	let v6 = index(parts[0], ":") >= 0;
	let bits = v6 ? 128 : 32;
	let len = (length(parts) == 1) ? bits : netmask_len(parts[1], v6);
	if (type(len) != "int" || len > bits) return null;
	if (v6) {
		let words = values.ipv6_words(parts[0]);
		if (words == null) return null;
		for (let i = 0; i < 8; i++) {
			let keep = len - (i * 16);
			words[i] &= (keep >= 16) ? 0xFFFF : (keep <= 0) ? 0 : ((0xFFFF << (16 - keep)) & 0xFFFF);
		}
		return { prefix: join(":", map(words, (w) => sprintf("%x", w))) + "/" + len, v6: true };
	}
	if (!values.is_valid_ipv4(parts[0])) return null;
	let n = values.ipv4_to_int(parts[0]) & ((-1 << (32 - len)) & 0xFFFFFFFF);
	return { prefix: sprintf("%d.%d.%d.%d/%d", (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255, len),
	         v6: false };
}

// wireguard.sh routes each word of the option as uci holds it, which printf %b never sees, through a
// case: a `:` before the last `/` makes the word an IPv6 prefix, else a `.` before it an IPv4 one,
// else a `:` or a `.` makes it a host. The address is what precedes the first `/` and the length
// what follows the last, so `10.0.0.0/8\054192.168.0.0/16`, which gives wg two prefixes, routes
// 10.0.0.0/16.
function word_route(w) {
	let slash = rindex(w, "/"), colon = index(w, ":"), dot = index(w, ".");
	let v6 = colon >= 0 && colon < slash, len;
	if (v6 || (dot >= 0 && dot < slash)) len = substr(w, slash + 1);
	else if (colon >= 0) { v6 = true; len = "128"; }
	else if (dot >= 0) len = "32";
	else return null;
	let r = route_prefix(split(w, "/")[0] + "/" + len);
	return (r?.v6 === v6) ? r : null;
}

function routes_from(words, enabled) {
	if (!enabled) return [];
	let out = [];
	for (let w in (type(words) == "array" ? words : [])) {
		let r = word_route(w);
		if (r != null) push(out, r);
	}
	return out;
}

// wireguard.sh installs a route for each word of `for allowed_ip in $peer_a_ips`.
function peer_routes(section) {
	return routes_from(values.config_get_words(section.allowed_ips) ?? [],
	                   values.shell_bool(values.config_get(section.route_allowed_ips), false));
}

// netifd puts an interface's routes in ip4table / ip6table when those are set,
// not in main, so a route installed without them lands in the wrong table and
// the peer still has no path.
function route_table(conn, iface, v6) {
	let s = conn.uci_get('network', iface);
	if (type(s) != "object") return null;
	let t = v6 ? s.ip6table : s.ip4table;
	if (type(t) != "string" || !match(t, /^[A-Za-z0-9_-]+$/)) return null;
	return t;
}

function ip_route(v6, args, table) {
	return [ "ip", ...(v6 ? [ "-6" ] : []), "route", ...args, ...(table != null ? [ "table", table ] : []) ];
}

// Spelled to match what netifd installs, verified against a real interface:
// `<prefix> proto static scope link dev <iface>` for v4, and the same without a
// scope for v6, where iproute2's default metric 1024 is what netifd ends up with.
function route_cmd(verb, iface, r, table) {
	return ip_route(r.v6, [ verb, r.prefix, "dev", iface, "proto", "static", ...(r.v6 ? [] : [ "scope", "link" ]) ], table);
}

// Routes are shared: two peers can carry overlapping allowed_ips, and a
// `config route` section can name the same prefix on the same interface. So a
// prefix is only withdrawn when nothing else still wants it, and the kernel is
// never scanned for strays, which would risk deleting a route uapi did not put
// there.
function route_still_wanted(conn, iface, r) {
	for (let s in peer_sections(conn, iface))
		for (let w in peer_routes(s))
			if (w.prefix == r.prefix) return true;
	let claimed = false;
	conn.uci_foreach('network', null, function(s) {
		if (s['.type'] != "route" && s['.type'] != "route6") return;
		if (s.interface != iface) return;
		if (route_prefix(s.target)?.prefix == r.prefix)
			claimed = true;
	});
	return claimed;
}

// Only `proto static` routes on this device are considered, which is how netifd
// spells the ones it installs for route_allowed_ips; the interface's own on-link
// prefix is `proto kernel` and so is never a candidate. Used on the reconcile
// path, where the set of previously-wanted prefixes is not known from the request.
function installed_routes(conn, iface) {
	let out = [];
	for (let v6 in [false, true]) {
		let table = route_table(conn, iface, v6);
		let r = run(ip_route(v6, [ "show", "dev", iface, "proto", "static" ], table));
		if (!r.ok) continue;
		for (let line in split(r.output, "\n")) {
			// The kernel prints 0.0.0.0/0 and ::/0 as "default", so a route installed for a
			// catch-all peer was not recognised, and a rollback left it in place.
			let first = split(trim(line), " ")[0];
			let p = route_prefix((first == "default") ? (v6 ? "::/0" : "0.0.0.0/0") : first);
			if (p != null) push(out, p);
		}
	}
	return out;
}

function apply_routes(conn, iface, wanted, previous) {
	for (let r in wanted) {
		let res = run(route_cmd("replace", iface, r, route_table(conn, iface, r.v6)));
		if (!res.ok)
			return sprintf("installing route %s on %s failed: %s",
			               r.prefix, iface, res.output);
	}

	let keep = {};
	for (let r in wanted) keep[r.prefix] = true;
	for (let r in previous) {
		if (keep[r.prefix]) continue;
		if (route_still_wanted(conn, iface, r)) continue;
		run(route_cmd("del", iface, r, route_table(conn, iface, r.v6)));
	}
	return null;
}

function apply_peer(iface, peer) {
	let key = kernel_key(peer.public_key);
	if (!key)
		return sprintf("refusing to apply a peer with a malformed public key on %s", iface);
	let psk = kernel_key(peer.preshared_key);
	if (!psk && peer.preshared_key != null && peer.preshared_key != "")
		return sprintf("refusing to apply a peer with a malformed preshared key on %s", iface);
	// wg strips the whitespace from the config line that wireguard.sh writes, and `wg set` does not.
	let host = replace(peer.endpoint_host ?? "", /[[:space:]]/g, "");
	// A port that reads 0 is a stored 0 or a name that does not resolve, which a write refuses to
	// set, as for the keepalive above. A write that leaves it as it is, and the restore, set the rest of
	// the peer, and the kernel keeps its endpoint.
	let keep_endpoint = host != "" && peer.endpoint_port === 0;

	// The key is staged before anything changes in the kernel. Staged after the remove below, a key
	// that the tmpfs could not hold left the peer removed and not set again, and the restore did the
	// same to the first such peer of the interface, one that the write may not have named.
	let psk_path = null;
	if (psk) {
		psk_path = psk_file(psk);
		if (psk_path == null)
			return sprintf("could not stage the preshared key of a peer on %s", iface);
	}

	// `wg set` cannot unset an endpoint, so clearing one means removing the peer
	// and setting it fresh. Safe only in this direction: with no endpoint there is
	// no name to resolve, so the following set cannot fail the way it could if it
	// carried one.
	if (host == "")
		remove_peer(iface, key);

	let r = run(set_peer_argv(iface, { ...peer, public_key: key, endpoint_host: keep_endpoint ? null : host }, psk_path));
	if (psk_path != null) fs.unlink(psk_path);
	if (!r.ok)
		return sprintf("wg set on %s failed: %s", iface, r.output);
	return null;
}

// A down interface holds no peer state, and ifup reads the peers from uci, so
// there is nothing to apply. An interface netifd does not know is the same case:
// it is how a peer orphaned by deleting its parent is still deletable.
function is_up(conn, iface) {
	let status = null;
	try {
		status = conn.call("network.interface." + iface, "status", {});
	} catch (e) {
		return false;
	}
	return type(status) == "object" && status.up === true;
}

const NOT_HELD = { endpoint: null, allowed_ips: null, persistent_keepalive: null, latest_handshake: null,
                   rx_bytes: null, tx_bytes: null };

// What the kernel holds under the key that wg reads from a stored public_key. Empty when uapi did not
// read the kernel, so that a failed read never looks like a missing peer: the interface is not up,
// wg fails, or the value gives wg more than a key or is too long to expand, so that uapi cannot tell
// which peer wg set for it. A collection GET reads every peer, so each interface is read once and
// kept on the connection, which lasts one request.
function runtime(conn, iface, public_key) {
	let key = kernel_key(public_key);
	if (conn == null || key === false) return {};
	conn.wg_peers ??= {};
	if (!exists(conn.wg_peers, iface))
		conn.wg_peers[iface] = is_up(conn, iface) ? kernel_peers(iface) : null;
	let peers = conn.wg_peers[iface];
	if (peers == null) return {};
	let held = key ? peers[key] : null;
	return { in_kernel: held != null, ...(held ?? NOT_HELD) };
}

// Bring the kernel in line with what uci now holds for these interfaces: drop
// peers uci no longer lists, then apply every peer it does. Used on the rollback
// path, where a batch may have applied some peers before failing on a later one,
// so replaying the request's own operations would not undo the applied ones.
// `ops` are those operations, which name the peers that the request may have changed in the kernel.
function reconcile(conn, interfaces, ops) {
	let seen = {}, missing = null, named = {};
	for (let op in ops ?? [])
		for (let k in ((op.action == "remove") ? kernel_keys(op.public_key) : [ kernel_key(op.public_key) ]) || [])
			if (k) named[op.iface + "|" + k] = true;
	for (let iface in interfaces) {
		if (type(iface) != "string" || !match(iface, SAFE_IFACE_RE)) continue;
		if (seen[iface]) continue;
		seen[iface] = true;
		if (!is_up(conn, iface)) continue;

		let sections = peer_sections(conn, iface);
		let wanted = {};
		for (let s in sections) {
			let key = kernel_key(s.public_key);
			// Refused before anything changes in the kernel, as apply_peer() refuses it.
			if (key === false)
				return sprintf("refusing to apply a peer with a malformed public key on %s", iface);
			if (key && kernel_key(s.preshared_key) === false)
				return sprintf("refusing to apply a peer with a malformed preshared key on %s", iface);
			if (key) wanted[key] = true;
		}

		let current = kernel_peers(iface);
		for (let pk in current)
			if (!wanted[pk]) remove_peer(iface, pk);

		let wanted_routes = [];
		for (let s in sections)
			for (let r in peer_routes(s)) push(wanted_routes, r);

		// wireguard.sh writes no [Peer] for a section without a key, so ifup sets no peer for it, and
		// the kernel holds no peer under a key that wg cannot read. A preshared key that wg cannot read
		// makes wg refuse the whole config at ifup, so wg never sets that peer without it: set with
		// /dev/null here, the peer would lose the key that the kernel holds. So the peer stays as the
		// kernel holds it, which restores it only when the request did not set or remove it and the
		// kernel holds it. Otherwise it fails the restore, once the other peers are set.
		for (let s in sections) {
			let key = kernel_key(s.public_key);
			if (!key) continue;
			if (kernel_key(s.preshared_key) === null && (s.preshared_key ?? "") != "") {
				if (named[iface + "|" + key] || current?.[key] == null)
					missing = sprintf("not restoring a peer with a malformed preshared key on %s", iface);
				continue;
			}
			let err = apply_peer(iface, to_peer(s));
			if (err != null) return err;
		}

		// Withdraw what uci no longer wants. The previously-wanted set comes from the
		// kernel, which holds what a batch applied before it failed, and
		// route_still_wanted keeps a prefix another peer or a `config route`
		// section claims.
		let err = apply_routes(conn, iface, wanted_routes, installed_routes(conn, iface));
		if (err != null) return err;
	}
	return missing;
}

// ops are {iface, action: "set"|"remove", ...peer fields}, in the order the
// request produced them, so a batch that touches one peer twice ends on its last
// state.
// `applied` collects the interfaces this call found live and therefore applied
// to, so the response can say which ones a write reached. Recorded on the
// up/down decision rather than per operation: the two only differ when an
// operation fails, and a failure returns an error, which routes the request into
// the restore recipe whose result carries no kernel fields at all. Skipping is
// normal rather than a failure, and without this the caller cannot tell a write
// that landed in the kernel from one that only landed in uci.
function apply(conn, ops, applied) {
	let up = {};
	for (let op in ops) {
		let iface = op.iface;
		if (type(iface) != "string" || !match(iface, SAFE_IFACE_RE))
			return sprintf("refusing to apply to interface %J", iface);
		if (up[iface] == null) {
			up[iface] = is_up(conn, iface);
			if (up[iface] && type(applied) == "array")
				push(applied, iface);
		}
		if (!up[iface]) continue;

		let previous = routes_from(op.prev_allowed_ips, op.prev_route_allowed_ips);

		if (op.action == "remove") {
			let keys = kernel_keys(op.public_key);
			if (keys === false)
				return sprintf("refusing to remove a public key of more than %d characters with a backslash on %s", ESCAPED_MAX, iface);
			// The kernel holds one peer per key, so another section that holds the key is set again,
			// in uci order as ifup sets them, and the last wins. apply_peer() sets it over the peer
			// that the kernel holds, so the key is not removed here: a remove here dropped the peer
			// when that section's preshared key could not be staged.
			let again = filter(peer_sections(conn, iface), (s) => index(keys, kernel_key(s.public_key)) >= 0);
			let held = {};
			for (let s in again) held[kernel_key(s.public_key)] = true;
			for (let key in keys) {
				if (held[key]) continue;
				let r = remove_peer(iface, key);
				if (!r.ok) return sprintf("wg set remove on %s failed: %s", iface, r.output);
			}
			for (let s in again) {
				let err = apply_peer(iface, to_peer(s));
				if (err != null) return err;
			}
			let rerr = apply_routes(conn, iface, [], previous);
			if (rerr != null) return rerr;
			continue;
		}

		let err = apply_peer(iface, op);
		if (err != null) return err;
		err = apply_routes(conn, iface,
		                   routes_from(op.route_words, op.route_allowed_ips), previous);
		if (err != null) return err;
	}
	return null;
}

function interfaces_of(ops) {
	let seen = {}, out = [];
	for (let op in ops) {
		if (type(op.iface) != "string" || seen[op.iface]) continue;
		seen[op.iface] = true;
		push(out, op.iface);
	}
	return out;
}

return { apply, reconcile, runtime, interfaces_of, shellquote, to_peer, endpoint_arg, kernel_key, kernel_keys, allowed_ips,
         route_prefixes: routes_from, route_table, route_cmd, set_peer_argv, command_line };
