const BEARER_RE = /^Bearer[ \t]+([A-Za-z0-9_-]+)$/;

function authorize(tokens, authorization_header, hash_fn) {
	if (type(authorization_header) != "string" || authorization_header == "")
		return { ok: false, kind: "unauthorized" };
	let m = match(authorization_header, BEARER_RE);
	if (!m) return { ok: false, kind: "unauthorized" };
	let bearer = m[1];

	if (type(tokens) != "array") return { ok: false, kind: "invalid_token" };

	for (let t in tokens) {
		if (t.salt == null || t.hash == null) continue;
		let candidate = hash_fn(t.salt, bearer);
		if (candidate == t.hash)
			return { ok: true, token: { name: t.name, scopes: t.scopes ?? [] } };
	}
	return { ok: false, kind: "invalid_token" };
}

return { authorize };
