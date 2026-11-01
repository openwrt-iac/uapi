let fs = require('fs');

const FALLBACK = {
	network: ["network"],
	wireless: ["network"],
	firewall: ["firewall"],
	dhcp: [],
	system: ["system"],
};
// The daemons with a procd trigger on the package, or on dhcp, which LuCI's ucitrack has system
// affect. An image can lack each of them and an operator can stop it. LuCI's ucitrack also has
// network affect dhcp, and docs/raw.md says why a network write reloads only odhcpd of them.
const FALLBACK_IF_RUNNING = {
	dhcp: ["dnsmasq", "odhcpd", "unbound"],
	network: ["odhcpd"],
	system: ["dnsmasq", "odhcpd", "unbound"],
};

function default_init_exists(pkg) {
	let st = null;
	try { st = fs.stat("/etc/init.d/" + pkg); } catch (e) {}
	return st != null;
}

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

function reload_services(conn, pkg, opts) {
	let init_exists = (opts != null && opts.init_exists != null)
	                  ? opts.init_exists : default_init_exists;
	let entry = lookup_init(conn, pkg);
	let services = [];
	let if_running = [];
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
		if_running = FALLBACK_IF_RUNNING[pkg] ?? [];
	} else if (init_exists(pkg)) {
		known = true;
		push(services, pkg);
	}

	let seen = {};
	let out = [];
	for (let s in services) {
		if (seen[s]) continue;
		seen[s] = true;
		push(out, s);
	}

	return { services: out, if_running, known };
}

return { reload_services };
