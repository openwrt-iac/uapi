const BEARER_RE = /^Bearer[ \t]+([A-Za-z0-9_-]+)$/;

function authorize(tokens_by_bearer, authorization_header) {
	if (type(authorization_header) != "string" || authorization_header == "")
		return { ok: false, kind: "unauthorized" };
	let m = match(authorization_header, BEARER_RE);
	if (!m) return { ok: false, kind: "unauthorized" };
	let record = tokens_by_bearer[m[1]];
	if (!record) return { ok: false, kind: "invalid_token" };
	return { ok: true, token: record };
}

function stub_enabled() {
	return getenv("UAPI_AUTH_STUB") == "1";
}

function stub_token() {
	return { name: "stub", scopes: ["*:rw"] };
}

return { authorize, stub_enabled, stub_token };
