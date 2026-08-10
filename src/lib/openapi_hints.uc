// Shared openapi_conditional fragments.

return {
	// Firewall resources whose `match` envelope must declare `src_zone` when
	// the envelope itself is present. Used by firewall.redirects, where a
	// redirect without a source zone is meaningless. firewall.rules used this
	// until it moved to a target-conditional rule (fw4 only demands a source
	// zone for NOTRACK and HELPER), and firewall.forwardings encodes src/dest
	// at the top level so it never needed it.
	match_requires_src_zone: {
		if:   { type: "object", required: ["match"] },
		then: { properties: { match: { type: "object", required: ["src_zone"] } } }
	},
};
