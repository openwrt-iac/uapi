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
const PUBKEY_RE = /^[A-Za-z0-9+\/]{43}=$/;

// Same idiom as LuCI's wireguard backend: single-quote and escape embedded
// quotes. endpoint_host is caller-supplied free-form text, so it must never
// reach the shell unquoted; keys and addresses are pattern-checked instead
// because their charsets carry no shell metacharacters.
function shellquote(s) {
	return "'" + replace("" + (s ?? ""), "'", "'\\''") + "'";
}

function run(cmd) {
	let p = fs.popen(cmd + " 2>&1", "r");
	if (p == null) return { ok: false, output: "could not exec wg" };
	let output = p.read("all") ?? "";
	let code = p.close();
	return { ok: code == 0, code: code, output: trim(output) };
}

function to_peer(section) {
	return {
		public_key: section.public_key,
		allowed_ips: (type(section.allowed_ips) == "array")
		             ? section.allowed_ips
		             : (section.allowed_ips != null ? [section.allowed_ips] : []),
		endpoint_host: section.endpoint_host,
		endpoint_port: section.endpoint_port,
		persistent_keepalive: section.persistent_keepalive,
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
		if (values.shell_bool(s.disabled, false)) return;
		push(out, s);
	});
	return out;
}

// Peer lines carry 8 tab-separated fields: public key, preshared key, endpoint,
// allowed ips, last handshake, rx, tx, keepalive, with "(none)"/"off" sentinels.
// The first line describes the interface, not a peer. The preshared key is in
// there, so this output must never be logged.
function installed_pubkeys(iface) {
	let r = run(sprintf("wg show %s dump", iface));
	if (!r.ok) return null;
	let keys = [];
	let lines = split(r.output, "\n");
	for (let i = 1; i < length(lines); i++) {
		let f = split(lines[i], "\t");
		if (length(f) >= 8 && match(f[0], PUBKEY_RE)) push(keys, f[0]);
	}
	return keys;
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
	f.write(value + "\n");
	f.close();
	return PSK_PATH;
}

// One `wg set` carrying the whole desired state. It is atomic: a bad endpoint
// fails the command and changes nothing, so the peer keeps working on its old
// config. Keepalive and preshared key are always spelled out, with 0 and
// /dev/null as the explicit clears, because `wg set` merges and would otherwise
// leave a stale value behind that uci no longer has.
// An IPv6 endpoint has to be bracketed for wg to find the port, but the caller
// may already have bracketed it: that is the form `wg show endpoints` prints
// back, so it round-trips straight into a PUT. Same guard upstream's handler
// uses. Without it "[fd00::1]" became "[[fd00::1]]" and wg refused the peer.
function endpoint_arg(host, port) {
	if (index(host, ":") >= 0 && substr(host, 0, 1) != "[")
		host = "[" + host + "]";
	return sprintf("%s:%d", host, port);
}

function set_peer(iface, peer) {
	let args = sprintf("wg set %s peer %s", iface, shellquote(peer.public_key));
	args += " allowed-ips " + shellquote(join(",", peer.allowed_ips));
	args += " persistent-keepalive " + (peer.persistent_keepalive ?? 0);

	let psk_path = null;
	if (peer.preshared_key != null && peer.preshared_key != "") {
		psk_path = psk_file(peer.preshared_key);
		if (psk_path == null)
			return { ok: false, output: "could not stage the preshared key" };
		args += " preshared-key " + psk_path;
	}
	else
		args += " preshared-key /dev/null";

	if (peer.endpoint_host != null && peer.endpoint_host != "") {
		args += " endpoint " + shellquote(endpoint_arg(peer.endpoint_host,
		                                                peer.endpoint_port ?? 51820));
	}

	let r = run(args);
	if (psk_path != null) fs.unlink(psk_path);
	return r;
}

function remove_peer(iface, pubkey) {
	return run(sprintf("wg set %s peer %s remove", iface, shellquote(pubkey)));
}

// `route_allowed_ips` asks netifd to install a route per allowed IP, which it
// does from the proto handler, so a peer-level apply has to install them too or
// the peer is present in the kernel with no path to it. Mirrors the mapping in
// wireguard.sh: a prefix is used as written, a bare address becomes a host route.
function route_prefix(allowed_ip) {
	if (type(allowed_ip) != "string") return null;
	// The kernel prints 0.0.0.0/0 and ::/0 as "default", so a route we installed
	// from a catch-all peer would not be recognised when reading state back, and
	// a rollback would leave it in place. Both spellings are accepted on input.
	if (allowed_ip == "default") return null;
	let v6 = index(allowed_ip, ":") >= 0;
	if (values.is_valid_cidr_any(allowed_ip)) return { prefix: allowed_ip, v6: v6 };
	if (values.is_valid_ip(allowed_ip))
		return { prefix: allowed_ip + (v6 ? "/128" : "/32"), v6: v6 };
	return null;
}

function routes_from(allowed_ips, enabled) {
	if (!enabled) return [];
	let out = [];
	for (let a in (type(allowed_ips) == "array" ? allowed_ips : [])) {
		let r = route_prefix(a);
		if (r != null) push(out, r);
	}
	return out;
}

function peer_routes(section) {
	return routes_from(to_peer(section).allowed_ips,
	                   values.shell_bool(section.route_allowed_ips, false));
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

// Spelled to match what netifd installs, verified against a real interface:
// `<prefix> proto static scope link dev <iface>` for v4, and the same without a
// scope for v6, where iproute2's default metric 1024 is what netifd ends up with.
function route_cmd(verb, iface, r, table) {
	let cmd = sprintf("ip %sroute %s %s dev %s proto static",
	                  r.v6 ? "-6 " : "", verb, r.prefix, iface);
	if (!r.v6) cmd += " scope link";
	if (table != null) cmd += " table " + table;
	return cmd;
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
		let t = s.target;
		if (type(t) != "string") return;
		if (t == r.prefix || (index(t, "/") == -1 && route_prefix(t)?.prefix == r.prefix))
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
		let cmd = sprintf("ip %sroute show dev %s proto static", v6 ? "-6 " : "", iface);
		if (table != null) cmd += " table " + table;
		let r = run(cmd);
		if (!r.ok) continue;
		for (let line in split(r.output, "\n")) {
			let first = split(trim(line), " ")[0];
			let p = (first == "default")
			        ? { prefix: v6 ? "::/0" : "0.0.0.0/0", v6: v6 }
			        : route_prefix(first);
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
	if (type(peer.public_key) != "string" || !match(peer.public_key, PUBKEY_RE))
		return sprintf("refusing to apply a peer with a malformed public key on %s", iface);
	if (length(peer.allowed_ips) == 0)
		return sprintf("refusing to apply a peer with no allowed_ips on %s", iface);

	// `wg set` cannot unset an endpoint, so clearing one means removing the peer
	// and setting it fresh. Safe only in this direction: with no endpoint there is
	// no name to resolve, so the following set cannot fail the way it could if it
	// carried one.
	if (peer.endpoint_host == null || peer.endpoint_host == "")
		remove_peer(iface, peer.public_key);

	let r = set_peer(iface, peer);
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

// Bring the kernel in line with what uci now holds for these interfaces: drop
// peers uci no longer lists, then apply every peer it does. Used on the rollback
// path, where a batch may have applied some peers before failing on a later one,
// so replaying the request's own operations would not undo the applied ones.
function reconcile(conn, interfaces) {
	let seen = {};
	for (let iface in interfaces) {
		if (type(iface) != "string" || !match(iface, SAFE_IFACE_RE)) continue;
		if (seen[iface]) continue;
		seen[iface] = true;
		if (!is_up(conn, iface)) continue;

		let sections = peer_sections(conn, iface);
		let wanted = {};
		for (let s in sections)
			if (type(s.public_key) == "string") wanted[s.public_key] = true;

		let current = installed_pubkeys(iface);
		if (current != null)
			for (let pk in current)
				if (!wanted[pk]) remove_peer(iface, pk);

		let wanted_routes = [];
		for (let s in sections)
			for (let r in peer_routes(s)) push(wanted_routes, r);

		for (let s in sections) {
			let err = apply_peer(iface, to_peer(s));
			if (err != null) return err;
		}

		// Withdraw what uci no longer wants. The request's own operations are not
		// available here, so the previously-wanted set comes from the kernel, and
		// route_still_wanted keeps a prefix another peer or a `config route`
		// section claims.
		let err = apply_routes(conn, iface, wanted_routes, installed_routes(conn, iface));
		if (err != null) return err;
	}
	return null;
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
			if (type(op.public_key) != "string" || !match(op.public_key, PUBKEY_RE))
				return sprintf("refusing to remove a malformed public key on %s", iface);
			let r = remove_peer(iface, op.public_key);
			if (!r.ok) return sprintf("wg set remove on %s failed: %s", iface, r.output);
			let rerr = apply_routes(conn, iface, [], previous);
			if (rerr != null) return rerr;
			continue;
		}

		let err = apply_peer(iface, op);
		if (err != null) return err;
		err = apply_routes(conn, iface,
		                   routes_from(op.allowed_ips, op.route_allowed_ips), previous);
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

return { apply, reconcile, interfaces_of, shellquote, to_peer, endpoint_arg,
         route_prefixes: routes_from, route_table };
