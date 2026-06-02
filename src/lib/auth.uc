let values = require('values');

const BEARER_RE = /^Bearer[ \t]+([A-Za-z0-9_-]+)$/;

// authorize accepts the loaded token records (with optional expires_at and
// allowed_cidrs metadata), the inbound Authorization header, a hash function,
// and a `req` envelope { remote_addr, now }. It returns:
//   { ok: true,  token: { name, scopes, expires_at, allowed_cidrs } }
//   { ok: false, kind: "unauthorized"  }   // missing/malformed header
//   { ok: false, kind: "invalid_token", reason: "no_match" | "expired"
//                                              | "ip_not_permitted" }
// `reason` shapes the user-visible message but the wire `kind` stays
// `invalid_token` for all hash/expiry/ip failures (operators correlate via the
// audit log; clients should not learn whether the token exists).
function authorize(tokens, authorization_header, hash_fn, req) {
	if (type(authorization_header) != "string" || authorization_header == "")
		return { ok: false, kind: "unauthorized" };
	let m = match(authorization_header, BEARER_RE);
	if (!m) return { ok: false, kind: "unauthorized" };
	let bearer = m[1];

	if (type(tokens) != "array") return { ok: false, kind: "invalid_token", reason: "no_match" };

	let r = req ?? {};
	let now = r.now;
	let remote = r.remote_addr;

	for (let t in tokens) {
		if (t.salt == null || t.hash == null) continue;
		let candidate = hash_fn(t.salt, bearer);
		if (candidate != t.hash) continue;

		if (t.expires_at != null && now != null && now >= t.expires_at)
			return { ok: false, kind: "invalid_token", reason: "expired", token_name: t.name };

		let cidrs = t.allowed_cidrs ?? [];
		if (type(cidrs) == "array" && length(cidrs) > 0) {
			if (!values.ipv4_in_any_cidr(remote, cidrs))
				return { ok: false, kind: "invalid_token", reason: "ip_not_permitted", token_name: t.name };
		}

		return { ok: true, token: {
			name: t.name,
			scopes: t.scopes ?? [],
			expires_at: t.expires_at ?? null,
			allowed_cidrs: cidrs,
			last_used_at: t.last_used_at ?? null,
			last_used_ip: t.last_used_ip ?? null,
		} };
	}
	return { ok: false, kind: "invalid_token", reason: "no_match" };
}

return { authorize };
