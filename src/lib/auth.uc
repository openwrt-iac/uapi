let values = require('values');

const BEARER_RE = /^Bearer[ \t]+([A-Za-z0-9_-]+)$/;

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

	// Iterate every token regardless of match position. Returning on first
	// match leaks which token matched via wall-clock time; the constant-time
	// compare above is moot if the loop short-circuits. `match` is set once
	// and never overwritten so a second matching hash (cannot happen in
	// practice, but enforced) does not silently swap identities.
	let match = null;
	for (let t in tokens) {
		if (t.salt == null || t.hash == null) continue;
		let candidate = hash_fn(t.salt, bearer);
		if (!values.constant_time_equals(candidate, t.hash)) continue;
		if (match == null) match = t;
	}
	if (match == null) return { ok: false, kind: "invalid_token", reason: "no_match" };

	if (match.expires_at != null && now != null && now >= match.expires_at)
		return { ok: false, kind: "invalid_token", reason: "expired", token_name: match.name };

	let cidrs = match.allowed_cidrs ?? [];
	if (type(cidrs) == "array" && length(cidrs) > 0) {
		if (!values.ipv4_in_any_cidr(remote, cidrs))
			return { ok: false, kind: "invalid_token", reason: "ip_not_permitted", token_name: match.name };
	}

	return { ok: true, token: {
		name: match.name,
		scopes: match.scopes ?? [],
		expires_at: match.expires_at ?? null,
		allowed_cidrs: cidrs,
		last_used_at: match.last_used_at ?? null,
		last_used_ip: match.last_used_ip ?? null,
		rate: match.rate ?? null,
		burst: match.burst ?? null,
	} };
}

return { authorize };
