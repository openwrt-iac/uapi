let odhcpd_leases = require('odhcpd_leases');

return {
	package: "dhcp",
	type: "lease6",
	id_field: "ip",
	list_fn: odhcpd_leases.read,
	schema_properties: {
		duid:          { type: "string",
		                 description: "Client DUID (hex)" },
		iaid:          { type: "string",
		                 description: "Identity Association ID (hex)" },
		hostname:      { type: ["string", "null"] },
		interface:     { type: "string",
		                 description: "Network device that odhcpd served the lease on, as odhcpd names it (for example `br-lan`), not the uci interface" },
		ia_type:       { type: "string", enum: ["IA_NA", "IA_TA", "IA_PD"],
		                 description: "DHCPv6 Identity Association type" },
		ip:            { type: "string",
		                 description: "Assigned IPv6 address or prefix" },
		prefix_length: { type: ["integer", "null"],
		                 description: "Prefix length for IA_PD; null for IA_NA" },
		expires_at:    { type: ["integer", "null"],
		                 description: "Unix epoch seconds when the lease expires; null for one that does not expire" },
	},
};
