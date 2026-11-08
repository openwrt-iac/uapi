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
// returns the v6 ones.
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
	query: {
		family: { enum: [ "v4", "v6" ],
		          description: "`v4`, the default, for the leases of dnsmasq, or `v6` for the IPv6 leases of odhcpd. Another value answers 400." },
	},
	list_fn: list_fn,
	parse_leases: parse_leases,
	schema_properties: {
		expires_at: { type: ["integer", "null"], description: "Unix epoch seconds when the lease expires. A lease that does not expire reads 0 for v4, as dnsmasq writes it, and null for v6" },
		mac: { type: "string", description: "Client MAC address (v4 entries only)" },
		iaid: { type: "string", description: "Identity association id, in hex (v6 entries only)" },
		interface: { type: "string", description: "Network device that odhcpd served the lease on, such as `br-lan`, not the uci interface (v6 entries only)" },
		ia_type: { type: "string", enum: [ "IA_NA", "IA_PD" ], description: "An address (`IA_NA`) or a delegated prefix (`IA_PD`) (v6 entries only)" },
		prefix_length: { type: ["integer", "null"], description: "Length of a delegated prefix; null for an address (v6 entries only)" },
		ip: { type: "string", description: "Assigned IP address" },
		hostname: { type: ["string", "null"] },
		duid:     { type: ["string", "null"], description: "Client DUID. A v4 entry carries the client id that dnsmasq records, a v6 entry always carries the DUID" },
	},
};
