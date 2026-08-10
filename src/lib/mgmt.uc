let fs = require('fs');

// Which interface is the caller reaching uapi through.
//
// Asked of the kernel rather than answered by comparing the caller's address against
// each interface's configured prefixes. A caller on a routed network sits inside no
// local prefix, and that operator is precisely the one a write can strand: containment
// math would return "unknown" for the case that matters most. The route lookup also
// answers for both families, where uapi's own prefix helpers are IPv4-only.
//
// Advisory only. Nothing here refuses a write: severing your own path is a legitimate
// operation (renumbering the management VLAN, moving to an out-of-band path), and LuCI
// warns rather than blocking on the same condition.

// REMOTE_ADDR comes from uhttpd, but it is interpolated into a command line, so it is
// validated as an address rather than trusted for being internal.
const ADDR_RE = /^[0-9A-Fa-f:.]{2,45}$/;

function inbound_device(addr) {
	if (type(addr) != "string" || !match(addr, ADDR_RE)) return null;
	let p = fs.popen("ip route get " + addr + " 2>/dev/null", "r");
	if (p == null) return null;
	let line = p.read("line") ?? "";
	p.close();
	let m = match(line, / dev ([^ \t\n]+)/);
	return (m != null) ? m[1] : null;
}

// netifd names the routed device `l3_device`, which is what differs from `device` on a
// tunnelled or bridged interface, so both are compared before giving up.
//
// `device_lookup` is an injection seam, the same one bus.uc gives ubus: the route lookup
// needs the `ip` binary, which the unit container does not have, so the mapping half is
// tested against a stub and the lookup half is tested on a real box.
function inbound_interface(conn, addr, device_lookup) {
	let dev = (device_lookup ?? inbound_device)(addr);
	if (dev == null) return null;
	let out = { address: addr, device: dev, interface: null };
	if (conn == null) return out;
	let dump;
	try { dump = conn.call("network.interface", "dump", {}); }
	catch (e) { return out; }
	for (let i in (dump ?? {}).interface ?? []) {
		if (i.l3_device == dev || i.device == dev) { out.interface = i.interface; break; }
	}
	return out;
}

// The fields LuCI treats as path-affecting on the inbound interface: it warns on
// `disabled`, `proto`, `ipaddr` and `netmask` and does no firewall analysis at all.
// Matching that scope is deliberate; predicting a firewall lockout means modelling fw4
// zone and rule ordering, which cannot be done honestly from a resource module.
//
// `ipaddrs` is the same option as `ipaddr` under the name that replaces it, and watching
// only the scalar made the guard blind to the exact case it exists for. A PATCH naming
// `ipaddrs` has its `ipaddr` deleted by merge_for_patch, and a PUT naming only `ipaddrs`
// leaves resolve_for_replace's early return untouched, so renumbering the caller's own
// interface produced no warning at all. The deprecation is steering every client toward
// that spelling, so the blind path was becoming the normal one.
const WATCHED = [ "disabled", "proto", "ipaddr", "ipaddrs", "netmask" ];

function changed_fields(existing, incoming) {
	let out = [];
	for (let f in WATCHED) {
		if (!exists(incoming, f)) continue;
		let before = (existing ?? {})[f];
		let after = incoming[f];
		if (sprintf("%J", before) != sprintf("%J", after)) push(out, f);
	}
	return out;
}

// Whether a write aimed at `device` can move the caller's own path. Two resources reach the
// caller without touching `config interface` at all: a `bridge-vlan` on the bridge carrying
// the request turns on VLAN filtering, which drops untagged traffic, and a `device` write can
// change that bridge's ports or its name. A bridge-vlan on `br-lan` took a test box off the
// network mid-suite and, because the follow-up delete never ran, it stayed off until someone
// reached a console.
//
// Two ways to match. The write names the caller's device outright, or it names a bridge the
// caller's device is a port of, which is the common shape: the request arrives on `br-lan`
// and the write targets `br-lan`, or it arrives on `eth0` and the write reconfigures the
// bridge `eth0` belongs to.
function targets_mgmt_device(conn, dev, target) {
	if (dev == null || target == null) return false;
	if (dev == target) return true;
	if (conn == null) return false;

	// Bridge membership comes from uci rather than from the kernel: a write can add a port
	// to a bridge that has not been applied yet, and the caller is on the path uci is about
	// to describe.
	let member = false;
	try {
		conn.uci_foreach("network", "device", function(sec) {
			if (sec.name != target) return;
			let ports = sec.ports;
			if (type(ports) == "string") ports = [ ports ];
			for (let port in ports ?? [])
				if (port == dev) member = true;
		});
	} catch (e) { return false; }
	return member;
}

return { inbound_device, inbound_interface, changed_fields, targets_mgmt_device, WATCHED };
