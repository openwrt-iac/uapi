const KNOWN_PATHS = {
	"*": true,
	"network": true,
	"network:interfaces": true,
	"network:devices": true,
	"network:routes": true,
	"network:rules": true,
	"network:bridge_vlans": true,
	"network:wireguard_peers": true,
	"wireless": true,
	"wireless:devices": true,
	"wireless:interfaces": true,
	"firewall": true,
	"firewall:zones": true,
	"firewall:rules": true,
	"firewall:redirects": true,
	"firewall:forwardings": true,
	"firewall:defaults": true,
	"dhcp": true,
	"dhcp:hosts": true,
	"dhcp:leases": true,
	"dhcp:leases6": true,
	"dhcp:servers": true,
	"dhcp:dnsmasq": true,
	"dhcp:odhcpd": true,
	"system": true,
	"system:timeservers": true,
	"system:password": true,
	"system:authorized_keys": true,
	"dropbear": true,
	"dropbear:instances": true,
	"uhttpd": true,
	"uhttpd:instances": true,
	"uhttpd:certs": true,
	"unbound": true,
	"unbound:server": true,
	"unbound:srv": true,
	"unbound:ext": true,
	"sqm": true,
	"sqm:queues": true,
	"snmpd": true,
	"snmpd:agents": true,
	"snmpd:com2secs": true,
	"snmpd:groups": true,
	"snmpd:accesses": true,
	"snmpd:system": true,
	"lldpd": true,
	"lldpd:config": true,
	"prometheus_node_exporter_lua": true,
	"prometheus_node_exporter_lua:config": true,
	"vnstat": true,
	"vnstat:config": true,
	"vnstat:interfaces": true,
	"mwan3": true,
	"mwan3:globals": true,
	"mwan3:interfaces": true,
	"mwan3:members": true,
	"mwan3:policies": true,
	"mwan3:rules": true,
	"usteer": true,
	"usteer:config": true,
	"openvpn": true,
	"openvpn:instances": true,
	"packages": true,
	"packages:installed": true,
	"packages:feeds": true,
	"uapi": true,
	"uapi:tokens": true,
	"uapi:metrics": true,
	"uapi:diagnostics": true,
	"raw": true,
};

const SEGMENT_RE = /^([*]|[a-z][a-z0-9_-]*)$/;

function parse(scope) {
	if (type(scope) != "string")
		die(sprintf("scope: %J is not a string", scope));

	let parts = split(scope, ":");
	if (length(parts) < 2)
		die(sprintf("scope: %J missing verb", scope));

	let verb = parts[length(parts) - 1];
	if (verb != "rw" && verb != "ro")
		die(sprintf("scope: %J has invalid verb %J", scope, verb));

	let segments = slice(parts, 0, -1);
	for (let seg in segments) {
		if (!match(seg, SEGMENT_RE))
			die(sprintf("scope: %J segment %J has invalid chars", scope, seg));
	}

	return { segments, verb };
}

function is_known_path(segments) {
	if (length(segments) == 2 && segments[0] == "raw")
		return true;
	if (!!KNOWN_PATHS[join(":", segments)])
		return true;
	let has_wildcard = false;
	for (let s in segments) if (s == "*") { has_wildcard = true; break; }
	if (!has_wildcard) return false;
	for (let known in KNOWN_PATHS) {
		let parts = split(known, ":");
		if (length(parts) != length(segments)) continue;
		let m = true;
		for (let j = 0; j < length(segments); j++) {
			if (segments[j] == "*") continue;
			if (segments[j] != parts[j]) { m = false; break; }
		}
		if (m) return true;
	}
	return false;
}

function validate_against_known_tree(scope) {
	let p = parse(scope);
	if (!is_known_path(p.segments))
		die(sprintf("scope: %J references unknown path", scope));
	return p;
}

function matches(scope_segs, resource_path) {
	if (length(scope_segs) == 1 && scope_segs[0] == "*")
		return true;
	if (length(scope_segs) > length(resource_path))
		return false;
	for (let i = 0; i < length(scope_segs); i++) {
		if (scope_segs[i] == "*") continue;
		if (scope_segs[i] != resource_path[i]) return false;
	}
	return true;
}

function match_depth(scope_segs) {
	if (length(scope_segs) == 1 && scope_segs[0] == "*")
		return 0;
	return length(scope_segs);
}

function exact_count(scope_segs) {
	if (length(scope_segs) == 1 && scope_segs[0] == "*") return 0;
	let n = 0;
	for (let s in scope_segs) if (s != "*") n++;
	return n;
}

function permits(token_scopes, resource_path, verb) {
	if (verb != "rw" && verb != "ro")
		die(sprintf("scope.permits: verb must be rw or ro, got %J", verb));
	if (type(resource_path) != "array" || length(resource_path) == 0)
		die("scope.permits: resource_path must be a non-empty array");

	let best_depth = -1;
	let best_exact = -1;
	let best_verb = null;

	for (let s in token_scopes) {
		let p = parse(s);
		if (!matches(p.segments, resource_path)) continue;
		let depth = match_depth(p.segments);
		let exact = exact_count(p.segments);
		if (depth > best_depth ||
		    (depth == best_depth && exact > best_exact)) {
			best_depth = depth;
			best_exact = exact;
			best_verb = p.verb;
		} else if (depth == best_depth && exact == best_exact && p.verb == "rw") {
			best_verb = "rw";
		}
	}

	if (best_verb == null) return false;
	if (best_verb == "rw") return true;
	return verb == "ro";
}

// subsumes(outer, inner) returns true iff every (path, verb) `inner` permits
// is also permitted by `outer`. Used to prevent scope escalation when one
// token mints another: caller's scopes must subsume the requested scopes.
function subsumes(outer_scopes, inner_scope) {
	let p = parse(inner_scope);
	// Build a representative resource path. For `*:rw`, the inner_scope's
	// segments are ["*"], representing any resource; permits() short-circuits
	// `*` matches, so checking the outer permits "*:rw" reduces to "outer must
	// have a top-level wildcard at the requested verb".
	if (length(p.segments) == 1 && p.segments[0] == "*") {
		for (let s in outer_scopes) {
			let op = parse(s);
			if (length(op.segments) == 1 && op.segments[0] == "*") {
				if (op.verb == "rw" || (op.verb == "ro" && p.verb == "ro"))
					return true;
			}
		}
		return false;
	}
	// For concrete or partial-wildcard inner scopes: there must exist some
	// outer scope whose segment-path is a prefix of inner's, with a verb
	// that covers inner's verb. permits() handles deepest-wins resolution
	// for us. Wildcard inner segments are replaced with a sentinel that
	// cannot appear in any valid scope (SEGMENT_RE rejects "?"), so only an
	// outer `*` segment matches it.
	let probe = [];
	for (let seg in p.segments)
		push(probe, seg == "*" ? "?" : seg);
	return permits(outer_scopes, probe, p.verb);
}

function subsets(outer_scopes, requested_scopes) {
	if (type(requested_scopes) != "array") return false;
	for (let s in requested_scopes) {
		if (!subsumes(outer_scopes, s)) return false;
	}
	return true;
}

// Convenience: scope-check + structured envelope. Returns null on pass,
// or an error response (insufficient_scope) on deny. `description` is a
// short noun phrase ("this operation on firewall:rules", "minting a
// token") that fills in "Token does not permit <description>".
function require_or_deny(errors_mod, ctx, scopes, path_segments, verb, description) {
	if (permits(scopes, path_segments, verb)) return null;
	let what = description != null
		? description
		: sprintf("%s on %s", verb, join(":", path_segments));
	return errors_mod.error(ctx, "insufficient_scope",
	                        sprintf("Token does not permit %s", what));
}

return {
	parse,
	permits,
	is_known_path,
	validate_against_known_tree,
	subsumes,
	subsets,
	require_or_deny,
};
