// LuCI reads the leases of odhcpd over ubus since f6eea3082e, because odhcpd can change or drop its
// lease file. ipv6leases also lists the leases that odhcpd only offered, which neither the lease file
// nor LuCI shows.

// The length of the valid UTF-8 sequence at byte i, or 0, as rpcd-mod-luci's utf8_seq_len() counts it.
function utf8_len(s, i) {
	let c = ord(s, i), n, cp;
	if (c < 0x80) return 1;
	if ((c & 0xe0) == 0xc0) { n = 2; cp = c & 0x1f; }
	else if ((c & 0xf0) == 0xe0) { n = 3; cp = c & 0x0f; }
	else if ((c & 0xf8) == 0xf0) { n = 4; cp = c & 0x07; }
	else return 0;
	for (let k = 1; k < n; k++) {
		let b = ord(s, i + k);
		if (b == null || (b & 0xc0) != 0x80) return 0;
		cp = (cp << 6) | (b & 0x3f);
	}
	if ((n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) || (n == 4 && cp < 0x10000) ||
	    cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))
		return 0;
	return n;
}

// A client sends any bytes as its hostname, and odhcpd gives them as they are. Escape them as
// rpcd-mod-luci's escape_hostname() does, so the JSON stays valid and the value reversible.
function escape_hostname(s) {
	let out = "";
	for (let i = 0; i < length(s);) {
		let c = ord(s, i), n = utf8_len(s, i);
		if (n > 0 && c >= 0x20 && c != 0x7f && c != 0x5c) {
			out += substr(s, i, n);
			i += n;
		} else {
			out += sprintf("\\x%02x", c);
			i++;
		}
	}
	return out;
}

// ucode reads a blobmsg u32 as a signed int32, so an iaid from 2^31 and the infinite valid of
// 0xffffffff arrive negative.
function read(conn) {
	let reply = null;
	try { reply = conn.call("dhcp", "ipv6leases", {}); } catch (e) {}
	let now = time(), leases = [];
	for (let dev, d in reply?.device)
		for (let l in d.leases) {
			if (index(l.flags, "bound") < 0) continue;
			let na = l["ipv6-addr"] != null, valid = l.valid & 0xffffffff;
			for (let a in na ? l["ipv6-addr"] : l["ipv6-prefix"])
				push(leases, {
					duid: l.duid,
					iaid: sprintf("%x", l.iaid & 0xffffffff),
					hostname: (l.hostname == "") ? null : escape_hostname(l.hostname),
					interface: dev,
					ia_type: na ? "IA_NA" : "IA_PD",
					ip: a.address,
					prefix_length: na ? null : a["prefix-length"],
					expires_at: (valid == 0xffffffff) ? null : now + valid,
				});
		}
	return leases;
}

return { read, escape_hostname };
