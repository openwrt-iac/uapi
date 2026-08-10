let fs = require('fs');

const LEASES_PATH = "/tmp/hosts/odhcpd";
const LEASES_PATH_ALT = "/tmp/odhcpd.leases";

// odhcpd's statefile format varies across versions. The shapes we handle are
// (data lines only; lines starting with '#' or blank are skipped):
//
//   <duid> <iaid_hex> <hostname> <expires_unix> <iface> <IA_NA|IA_PD> <ip>[/<prefixlen>] [<ip2> ...]
//
// We surface one lease entry per assigned address. Hostname '-' becomes null.
// Anything we can't parse is silently skipped; this is read-only runtime data
// and parser drift must not break the read path.
function parse_leases(content) {
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

function list_fn(conn, query) {
	let content = read_file(LEASES_PATH);
	if (content == null) content = read_file(LEASES_PATH_ALT);
	return parse_leases(content ?? "");
}

return {
	package: "dhcp",
	type: "lease6",
	id_field: "ip",
	list_fn: list_fn,
	parse_leases: parse_leases,
	schema_properties: {
		duid:          { type: "string",
		                 description: "Client DUID (hex)" },
		iaid:          { type: "string",
		                 description: "Identity Association ID (hex)" },
		hostname:      { type: ["string", "null"] },
		interface:     { type: "string",
		                 description: "Server-side interface that issued the lease" },
		ia_type:       { type: "string", enum: ["IA_NA", "IA_TA", "IA_PD"],
		                 description: "DHCPv6 Identity Association type" },
		ip:            { type: "string",
		                 description: "Assigned IPv6 address or prefix" },
		prefix_length: { type: ["integer", "null"],
		                 description: "Prefix length for IA_PD; null for IA_NA" },
		expires_at:    { type: ["integer", "null"],
		                 description: "Unix epoch seconds when the lease expires; null for non-numeric values like 'forever'" },
	},
};
