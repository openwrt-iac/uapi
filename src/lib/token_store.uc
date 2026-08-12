let fs = require('fs');
let ratelimit = require('ratelimit');
let transaction = require('transaction');
let errors = require('errors');
let values = require('values');
let scope = require('scope');

// digest is optional at module-load time so unit tests in the build env (no
// ucode-mod-digest installed) can still exercise the validation paths. On a
// real OpenWrt install it is a hard dependency and always present.
let _digest = null;
try { _digest = require('digest'); } catch (e) {}

const PACKAGE = "uapi";
const TOKEN_TYPE = "token";
const LAST_USED_DIR = "/var/run/uapi-token-update";
const LAST_USED_THROTTLE_SECONDS = 60;
// uci section-name charset. Hyphens are NOT permitted by libuci; if we let
// one through, cursor.set returns true but the write silently never persists
// and the caller gets a fake bearer.
const NAME_RE = /^[A-Za-z0-9_]{1,63}$/;

function random_hex(n_bytes) {
	let f = fs.open("/dev/urandom", "r");
	if (!f) die("token_store: cannot open /dev/urandom");
	let raw = f.read(n_bytes);
	f.close();
	let hex = "";
	for (let i = 0; i < length(raw); i++) hex += sprintf("%02x", ord(raw, i));
	return hex;
}

// Fallback hash for unit-test environments only; production always has
// ucode-mod-digest installed (declared as an APK dependency). The fallback
// is NOT cryptographically secure; it must never run on a real router.
function _fallback_hash(salt, bearer) {
	let s = salt + ":" + bearer;
	let h1 = 5381, h2 = 7919;
	for (let i = 0; i < length(s); i++) {
		let c = ord(substr(s, i, 1));
		h1 = ((h1 * 33) + c) % 4294967296;
		h2 = ((h2 * 65599) + c) % 4294967296;
	}
	return sprintf("%08x%08x", h1, h2);
}

function _hash_bearer(salt, bearer) {
	if (_digest != null) return _digest.sha256(salt + ":" + bearer);
	return _fallback_hash(salt, bearer);
}

function _read_record(s, include_secret) {
	let cidrs = type(s.allowed_cidrs) == "array" ? s.allowed_cidrs
	          : (s.allowed_cidrs != null ? [s.allowed_cidrs] : []);
	let scopes = type(s.scopes) == "array" ? s.scopes
	           : (s.scopes != null ? [s.scopes] : []);
	let rec = {
		name: s['.name'],
		scopes,
		expires_at: values.as_int(s.expires_at),
		allowed_cidrs: cidrs,
		last_used_at: values.as_int(s.last_used_at),
		last_used_ip: s.last_used_ip ?? null,
		rate: values.as_int(s.rate),
		burst: values.as_int(s.burst),
	};
	if (include_secret) {
		rec.salt = s.salt;
		rec.hash = s.hash;
	}
	return rec;
}

function list_for_auth(conn) {
	let out = [];
	conn.uci_foreach(PACKAGE, TOKEN_TYPE, function(s) {
		if (!s.salt || !s.hash) return;
		push(out, _read_record(s, true));
	});
	return out;
}

function list_public(conn) {
	let out = [];
	conn.uci_foreach(PACKAGE, TOKEN_TYPE, function(s) {
		push(out, _read_record(s, false));
	});
	return out;
}

function get_public(conn, name) {
	let s = conn.uci_get(PACKAGE, name);
	if (!s || type(s) != "object" || s['.type'] != TOKEN_TYPE) return null;
	let view = { ...s };
	view['.name'] = name;
	return _read_record(view, false);
}

function _ensure_uapi_file(conn) {
	// uci requires the package file before commit; touch it if absent.
	let path = "/etc/config/" + PACKAGE;
	if (fs.stat(path) == null) {
		let f = fs.open(path, "w");
		if (f) f.close();
		try { conn.uci_load(PACKAGE); } catch (_) {}
	}
}

function _validate_create_body(body) {
	if (type(body) != "object")
		return [errors.field_error("(root)", "invalid_type", "must be a JSON object")];
	let errs = [];
	if (type(body.name) != "string" || !match(body.name, NAME_RE))
		push(errs, errors.field_error("name", "invalid_format",
			"must match [A-Za-z0-9_]+ (uci section-name charset; use underscores instead of hyphens)"));
	if (type(body.scopes) != "array" || length(body.scopes) == 0)
		push(errs, errors.field_error("scopes", "required",
			"must be a non-empty array of scope strings"));
	else for (let i = 0; i < length(body.scopes); i++) {
		if (type(body.scopes[i]) != "string")
			push(errs, errors.field_error(sprintf("scopes[%d]", i),
				"invalid_type", "scope must be a string"));
	}
	if (body.expires_in_seconds != null) {
		let n = values.as_int(body.expires_in_seconds);
		if (n == null || n <= 0)
			push(errs, errors.field_error("expires_in_seconds", "out_of_range",
				"must be a positive integer"));
	}
	if (body.allowed_cidrs != null) {
		if (type(body.allowed_cidrs) != "array")
			push(errs, errors.field_error("allowed_cidrs", "invalid_type",
				"must be an array of CIDR strings"));
		else for (let i = 0; i < length(body.allowed_cidrs); i++) {
			if (!values.is_valid_cidr_any(body.allowed_cidrs[i]))
				push(errs, errors.field_error(sprintf("allowed_cidrs[%d]", i),
					"invalid_format", "must be IPv4/N or IPv6/N"));
		}
	}
	if (body.rate != null) {
		let n = values.as_int(body.rate);
		if (n == null || n <= 0)
			push(errs, errors.field_error("rate", "out_of_range",
				"must be a positive integer"));
	}
	if (body.burst != null) {
		let n = values.as_int(body.burst);
		if (n == null || n <= 0)
			push(errs, errors.field_error("burst", "out_of_range",
				"must be a positive integer"));
	}
	return errs;
}

// Runs under the uapi-package transaction, so the lock held is the per-package flock plus a
// snapshot, not a token-specific one.
// No reload service - the token store is re-read by the HTTP path on every
// request, so a write is visible to the very next handler fork.
// tx_overrides lets unit tests bypass the real flock + uci_export by passing
// noop acquire/release/check_services.
function create(conn, body, caller_scopes, now, tx_overrides) {
	let params = {
		package: PACKAGE,
		reload_services: [],
		fn: function(c, pkg) {
			_ensure_uapi_file(c);
			let errs = _validate_create_body(body);
			if (length(errs) > 0)
				return { ok: false, kind: "validation", errors: errs };
			if (!scope.subsets(caller_scopes, body.scopes))
				return { ok: false, kind: "scope_escalation_blocked" };
			let existing = c.uci_get(pkg, body.name);
			if (existing && type(existing) == "object" && existing['.type'] == TOKEN_TYPE)
				return { ok: false, kind: "conflict",
				         message: sprintf("Token %J already exists", body.name) };
			let bearer = random_hex(16);
			let salt = random_hex(8);
			let hash = _hash_bearer(salt, bearer);
			c.uci_create_section(pkg, body.name, TOKEN_TYPE);
			c.uci_set(pkg, body.name, "salt", salt);
			c.uci_set(pkg, body.name, "hash", hash);
			c.uci_set(pkg, body.name, "scopes", body.scopes);
			if (body.expires_in_seconds != null && now != null) {
				let n = values.as_int(body.expires_in_seconds);
				c.uci_set(pkg, body.name, "expires_at", "" + (now + n));
			}
			if (type(body.allowed_cidrs) == "array" && length(body.allowed_cidrs) > 0)
				c.uci_set(pkg, body.name, "allowed_cidrs", body.allowed_cidrs);
			// rate / burst: validation above guarantees positive int or
			// digit-only string; coerce to string directly without re-parsing.
			if (body.rate != null)  c.uci_set(pkg, body.name, "rate",  "" + body.rate);
			if (body.burst != null) c.uci_set(pkg, body.name, "burst", "" + body.burst);
			return { ok: true, body: { bearer, name: body.name } };
		},
	};
	for (let k in tx_overrides ?? {}) params[k] = tx_overrides[k];
	return transaction.transaction(conn, params);
}

function remove(conn, name, tx_overrides) {
	let params = {
		package: PACKAGE,
		reload_services: [],
		fn: function(c, pkg) {
			let existing = c.uci_get(pkg, name);
			if (!existing || type(existing) != "object" || existing['.type'] != TOKEN_TYPE)
				return { ok: false, kind: "not_found",
				         message: sprintf("Token %J not found", name) };
			c.uci_delete(pkg, name);
			// Inside the transaction so a rolled-back revoke does not lose the bucket,
			// and best-effort because a revoke must not fail on a tmpfs hiccup.
			try { ratelimit.forget(name); } catch (_) {}
			return { ok: true, body: { deleted: name } };
		},
	};
	for (let k in tx_overrides ?? {}) params[k] = tx_overrides[k];
	return transaction.transaction(conn, params);
}

// update_last_used is best-effort: throttled to once per LAST_USED_THROTTLE_SECONDS
// per token via a tmpfs sentinel mtime. Failures are silent - auth itself has
// already succeeded and the wire response must not depend on the audit write.
function update_last_used(conn, name, addr, now) {
	if (name == null || now == null) return;
	if (!match(name, NAME_RE)) return;
	try { fs.mkdir(LAST_USED_DIR); } catch (_) {}
	let marker = LAST_USED_DIR + "/" + name;
	let st = fs.stat(marker);
	if (st != null && st.mtime != null
	    && (now - st.mtime) < LAST_USED_THROTTLE_SECONDS)
		return;
	let fd = fs.open(marker, "w");
	if (fd) { fd.write(""); fd.close(); }

	let r = transaction.transaction(conn, {
		package: PACKAGE,
		reload_services: [],
		fn: function(c, pkg) {
			let existing = c.uci_get(pkg, name);
			if (!existing || type(existing) != "object" || existing['.type'] != TOKEN_TYPE)
				return { ok: false, kind: "not_found" };
			c.uci_set(pkg, name, "last_used_at", "" + now);
			if (addr != null) c.uci_set(pkg, name, "last_used_ip",
			                             values.normalize_addr(addr) ?? addr);
			return { ok: true };
		},
	});
	return r;
}

return {
	list_for_auth,
	list_public,
	get_public,
	create,
	remove,
	update_last_used,
};
