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
		let expires = int(parts[0]);
		push(leases, {
			expires_at: (expires == 0) ? null : expires,
			mac: parts[1],
			ip: parts[2],
			hostname: parts[3] == "*" ? null : odhcpd_leases.escape_hostname(parts[3]),
			duid: (length(parts) > 4 && parts[4] != "*") ? parts[4] : null,
		});
	}
	return leases;
}

function read_file(path) {
	let f = fs.open(path, "r");
	if (!f) return "";
	let content = f.read("all") ?? "";
	f.close();
	return content;
}

function list_fn(conn, query) {
	if (query != null && query.family == "v6")
		return odhcpd_leases.read(conn);
	return parse_leases(read_file(LEASES_PATH));
}

return {
	package: "dhcp",
	type: "lease",
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
		expires_at: { type: ["integer", "null"], description: "Unix epoch seconds when the lease expires, null for a lease that does not expire. dnsmasq writes 0 for such a v4 lease, and odhcpd gives 0xffffffff for such a v6 lease" },
		mac: { type: "string", description: "Client MAC address (v4 entries only)" },
		iaid: { type: "string", description: "Identity association id, in hex (v6 entries only)" },
		interface: { type: "string", description: "Network device that odhcpd served the lease on, such as `br-lan`, not the uci interface (v6 entries only)" },
		ia_type: { type: "string", enum: [ "IA_NA", "IA_PD" ], description: "An address (`IA_NA`) or a delegated prefix (`IA_PD`) (v6 entries only)" },
		prefix_length: { type: ["integer", "null"], description: "Length of a delegated prefix; null for an address (v6 entries only)" },
		ip: { type: "string", description: "Assigned IP address" },
		hostname: { type: ["string", "null"], description: "Client hostname, null when the client sent none. A v6 entry gives the bytes that the client sent, as odhcpd holds them, which are not always a valid DNS name. A v4 entry gives the name that dnsmasq writes. A control byte (0x00 to 0x1f, 0x7f), the backslash and each byte that is not part of valid UTF-8 read as `\\x` and two lowercase hex digits, as LuCI shows them, so `\\x5c` is a backslash" },
		duid:     { type: ["string", "null"], description: "Client DUID. A v4 entry carries the client id that dnsmasq records, or null when the client sent none. A v6 entry always carries the DUID" },
	},
};
