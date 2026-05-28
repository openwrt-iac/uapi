import * as fs from 'fs';

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
	if (!f) return "";
	let content = f.read("all") ?? "";
	f.close();
	return content;
}

function list_fn(conn, query) {
	return parse_leases(read_file(LEASES_PATH));
}

return {
	package: "dhcp",
	type: "lease",
	id_field: "mac",
	list_fn: list_fn,
	parse_leases: parse_leases,
};
