let fs = require('fs');
let odhcpd_leases = require('odhcpd_leases');

const LEASES_PATH = "/tmp/dhcp.leases";

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
	if (query != null && query.family == "v6")
		return odhcpd_leases.read(conn);
	return parse_leases(read_file(LEASES_PATH) ?? "");
}

return {
	package: "dhcp",
	type: "lease",
	// v4 (#320): the entry id is the MAC for v4 leases and the IP for v6 ones.
	id_field: (query) => (query != null && query.family == "v6") ? "ip" : "mac",
	// dnsmasq keys a lease by client id, so one MAC can hold two leases, and a cursor on the MAC
	// repeated the page that ends on the second. It holds one lease per address, as odhcpd does.
	cursor_field: "ip",
	list_fn: list_fn,
	parse_leases: parse_leases,
	schema_properties: {
		expires_at: { type: "integer", description: "Unix epoch seconds when the lease expires" },
		mac: { type: "string", description: "Client MAC address (v4 entries)" },
		ip: { type: "string", description: "Assigned IP address" },
		hostname: { type: ["string", "null"] },
		duid:     { type: ["string", "null"], description: "Client DUID (v4 entries carry it, v6 entries always do)" },
	},
};
