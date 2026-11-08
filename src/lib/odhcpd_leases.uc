let fs = require('fs');

// odhcpd writes one line for each lease, `# <device> <duid> <iaid> <hostname> <valid until> <id>
// <length>`, then ` <address>/<length>` for each address or prefix, and `ipv4` for the iaid on a
// DHCPv4 lease that it serves. The length is 128 for an address. rpcd-mod-luci reads the file the
// same way, from the leasefile of each odhcpd section, else from /tmp/odhcpd.leases. A lease reads as
// one entry for each of its addresses or prefixes. The hostname is the client's, and odhcpd of 25.12
// writes it unescaped, so a line whose other fields do not parse is skipped.
function read(conn) {
	let paths = [];
	conn.uci_foreach("dhcp", "odhcpd", (s) => { if (type(s.leasefile) == "string") push(paths, s.leasefile); });
	let leases = [];
	for (let path in (length(paths) > 0) ? paths : [ "/tmp/odhcpd.leases" ])
		for (let line in split(fs.readfile(path) ?? "", "\n")) {
			let f = split(trim(line), /[ \t]+/);
			if (f[0] != "#" || length(f) < 9 || f[3] == "ipv4") continue;
			let valid = int(f[5]), plen = int(f[7]);
			let addrs = map(slice(f, 8), (t) => match(t, /^([0-9a-fA-F:.]+)\/([0-9]+)$/));
			if (!match(f[5], /^-?[0-9]+$/) || !match(f[7], /^[0-9]+$/) || plen < 1 || plen > 128 ||
			    length(filter(addrs, (m) => m == null || length(iptoarr(m[1]) ?? []) != 16)) > 0)
				continue;
			let na = plen == 128;
			for (let m in addrs) {
				push(leases, {
					duid: f[2],
					iaid: f[3],
					hostname: (f[4] == "-") ? null : f[4],
					interface: f[1],
					ia_type: na ? "IA_NA" : "IA_PD",
					ip: m[1],
					prefix_length: na ? null : int(m[2]),
					expires_at: (valid >= 0) ? valid : null,
				});
			}
		}
	return leases;
}

return { read };
