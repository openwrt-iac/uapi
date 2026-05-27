const FALLBACK = {
	network: ["network"],
	wireless: ["network"],
	firewall: ["firewall"],
	dhcp: ["dnsmasq"],
};

function lookup_init(conn, pkg) {
	let init = null;
	let affects = [];
	conn.uci_foreach('ucitrack', pkg, function(s) {
		init = s.init ?? pkg;
		let aff = s.affects;
		if (type(aff) == "array") affects = aff;
		else if (aff != null) affects = [aff];
		return false;
	});
	return { init, affects };
}

function reload_services(conn, pkg) {
	let entry = lookup_init(conn, pkg);
	let services = [];
	let known = false;

	if (entry.init != null) {
		known = true;
		push(services, entry.init);
		for (let other in entry.affects) {
			let other_entry = lookup_init(conn, other);
			push(services, other_entry.init ?? other);
		}
	} else if (FALLBACK[pkg]) {
		known = true;
		for (let s in FALLBACK[pkg]) push(services, s);
	}

	let seen = {};
	let out = [];
	for (let s in services) {
		if (seen[s]) continue;
		seen[s] = true;
		push(out, s);
	}

	return { services: out, known };
}

return { reload_services, FALLBACK };
