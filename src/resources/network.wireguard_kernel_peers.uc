let ids = require('ids');
let values = require('values');
let wg = require('wg');

function list_fn(conn) {
	let out = [];
	for (let p in wg.unclaimed(conn))
		push(out, { id: ids.content_id(p.interface + " " + p.public_key), ...p });
	return out;
}

return {
	package: "network",
	type: "wireguard_kernel_peer",
	id_field: "id",
	list_fn: list_fn,
	schema_properties: {
		id:                   { type: "string", pattern: "^[a-f0-9]{12}$",
		                        description: "Stable id of the peer on its interface: the first 12 hex characters of the sha256 of the interface name and the public key, so a client tells one entry from another across reads" },
		interface:            { type: "string",
		                        description: "The interface that holds the peer, up and with proto=wireguard" },
		public_key:           { type: "string", pattern: "^" + values.WG_KEY_PATTERN + "$",
		                        description: "The public key that the kernel holds the peer under, as wg prints it" },
		endpoint:             { type: ["string", "null"],
		                        description: "The endpoint of the peer in the kernel, as an address and a port, such as `192.0.2.1:51820` or `[2001:db8::1]:51820`. null when the kernel holds no endpoint for the peer." },
		allowed_ips:          { type: "array", items: { type: "string" },
		                        description: "The allowed IPs of the peer in the kernel, in the form that the kernel prints, with the host bits cleared and an IPv6 address in its short lower-case form. Empty when the kernel holds none for the peer." },
		persistent_keepalive: { type: "integer", minimum: 0, maximum: 65535,
		                        description: "The keepalive interval of the peer in the kernel, in seconds, 0 when it is off." },
		latest_handshake:     { type: "integer", minimum: 0,
		                        description: "The time of the latest handshake with the peer, in seconds since the epoch, 0 when there was none." },
		rx_bytes:             { type: "integer", minimum: 0,
		                        description: "Bytes that the kernel received from the peer since it added the peer." },
		tx_bytes:             { type: "integer", minimum: 0,
		                        description: "Bytes that the kernel sent to the peer since it added the peer." },
	},
};
