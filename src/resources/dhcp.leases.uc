let fs = require('fs');

const LEASES_PATH = "/tmp/dhcp.leases";
const LEASES6_PATH = "/tmp/hosts/odhcpd";
const LEASES6_PATH_ALT = "/tmp/odhcpd.leases";

function parse_leases(content) {
	let leases = [];
	if (type(content) != "string") return leases;
	for (let line in split(content, "\n")) {
		let trimmed = trim(line);
		if (trimmed == "") continue;
		let parts = split(trimmed, " ");
		if (length(parts) < 4) continue;
		push(leases, {
			expires_at: int(parts[0]),
			mac: parts[1],
			ip: parts[2],
			hostname: parts[3] == "*" ? null : parts[3],
			duid: length(parts) > 4 ? parts[4] : null,
		});
	}
	return leases;
}

// odhcpd's statefile format varies across versions. The shapes we handle are
// (data lines only; lines starting with '#' or blank are skipped):
//
//   <duid> <iaid_hex> <hostname> <expires_unix> <iface> <IA_NA|IA_PD> <ip>[/<prefixlen>] [<ip2> ...]
//
// We surface one lease entry per assigned address. Hostname '-' becomes null.
// Anything we can't parse is silently skipped; this is read-only runtime data
// and parser drift must not break the read path.
function parse_leases6(content) {
	let leases = [];
	if (type(content) != "string") return leases;
	for (let line in split(content, "\n")) {
		let trimmed = trim(line);
		if (trimmed == "" || substr(trimmed, 0, 1) == "#") continue;
		// Split on any whitespace (space OR tab) so trailing tabs or mixed
		// separators don't shift columns.
		let parts = split(trimmed, /[ \t]+/);
		if (length(parts) < 7) continue;
		let duid     = parts[0];
		let iaid     = parts[1];
		let hostname = parts[2] == "-" ? null : parts[2];
		let raw_exp  = int(parts[3]);
		// int() returns NaN (declared as float type in ucode) for non-numeric
		// input like "-" or "forever"; coerce that to null.
		let expires  = (type(raw_exp) == "int") ? raw_exp : null;
		let iface    = parts[4];
		let ia_type  = parts[5];
		for (let i = 6; i < length(parts); i++) {
			let token = parts[i];
			if (token == "" || token == "-") continue;
			let ip = token;
			let prefix_length = null;
			let slash = index(token, "/");
			if (slash >= 0) {
				ip = substr(token, 0, slash);
				let raw_plen = int(substr(token, slash + 1));
				prefix_length = (type(raw_plen) == "int") ? raw_plen : null;
			}
			push(leases, {
				duid: duid,
				iaid: iaid,
				hostname: hostname,
				interface: iface,
				ia_type: ia_type,
				ip: ip,
				prefix_length: prefix_length,
				expires_at: expires,
			});
		}
	}
	return leases;
}

function read_file(path) {
	let f = fs.open(path, "r");
	if (!f) return null;
	let content = f.read("all") ?? "";
	f.close();
	return content;
}

// v4 (#320): one endpoint. No query parameter returns the v4 leases; ?family=v6
// returns the v6 ones. The query parameter keeps the entry schema untouched.
function list_fn(conn, query) {
	if (query != null && query.family == "v6") {
		let content = read_file(LEASES6_PATH);
		if (content == null) content = read_file(LEASES6_PATH_ALT);
		return parse_leases6(content ?? "");
	}
	return parse_leases(read_file(LEASES_PATH) ?? "");
}

return {
	package: "dhcp",
	type: "lease",
	// v4 (#320): the entry id is the MAC for v4 leases and the IP for v6 ones.
	id_field: (query) => (query != null && query.family == "v6") ? "ip" : "mac",
	list_fn: list_fn,
	parse_leases: parse_leases,
	parse_leases6: parse_leases6,
	schema_properties: {
		expires_at: { type: "integer", description: "Unix epoch seconds when the lease expires" },
		mac: { type: "string", description: "Client MAC address (v4 entries)" },
		ip: { type: "string", description: "Assigned IP address" },
		hostname: { type: ["string", "null"] },
		duid:     { type: ["string", "null"], description: "Client DUID (v4 entries carry it, v6 entries always do)" },
	},
};
