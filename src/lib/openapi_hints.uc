// Shared openapi_conditional fragments. Cross-resource invariants live in
// one literal rather than N copies, so changes to the contract land once.

return {
	// Firewall resources whose `match` envelope must declare `src_zone` when
	// the envelope itself is present. Used by firewall.rules and
	// firewall.redirects (and firewall.forwardings already encodes src/dest
	// at the top level so it doesn't need this).
	match_requires_src_zone: {
		if:   { type: "object", required: ["match"] },
		then: { properties: { match: { type: "object", required: ["src_zone"] } } }
	},
};
