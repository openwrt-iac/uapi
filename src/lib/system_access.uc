let fs = require('fs');
let errors = require('errors');
let transaction = require('transaction');
let log = require('log');

const KEYS_PATH = "/etc/dropbear/authorized_keys";
const USER_RE = /^(root|[a-z][a-z0-9_-]*)$/;
const MIN_PASSWORD_LEN = 8;
const KEY_ID_RE = /^[a-z0-9]{12}$/;
const BLOB_RE = /^[A-Za-z0-9+\/]+=*$/;

const VALID_KEY_TYPES = {
	"ssh-rsa": true,
	"ssh-ed25519": true,
	"ecdsa-sha2-nistp256": true,
	"ecdsa-sha2-nistp384": true,
	"ecdsa-sha2-nistp521": true,
	"sk-ssh-ed25519@openssh.com": true,
	"sk-ecdsa-sha2-nistp256@openssh.com": true,
};

function audit_password(ctx, user) {
	log.syslog(log.LOG_NOTICE,
		sprintf("uapi-passwd-set %s user=%J", ctx.request_id, user));
}

function audit_passwd_failure(ctx, user, exit_code) {
	log.syslog(log.LOG_WARNING,
		sprintf("uapi-passwd-failure %s user=%J exit=%d",
			ctx.request_id, user, exit_code));
}

function set_password(ctx, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let user = body.user;
	let pw = body.password;
	let errs = [];
	if (type(user) != "string" || user == "")
		push(errs, errors.field_error("user", "required", "is required"));
	else if (!match(user, USER_RE))
		push(errs, errors.field_error("user", "invalid_format",
			"must be 'root' or a lowercase Unix-shaped name"));
	if (type(pw) != "string" || pw == "")
		push(errs, errors.field_error("password", "required", "is required"));
	else if (length(pw) < MIN_PASSWORD_LEN)
		push(errs, errors.field_error("password", "out_of_range",
			sprintf("must be at least %d characters", MIN_PASSWORD_LEN)));
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);

	let r = transaction.with_lock({ fn: function() {
		let cmd = sprintf("/bin/busybox passwd %s >/dev/null 2>&1", user);
		let p = fs.popen(cmd, "w");
		if (p == null) return { ok: false, kind: "io_error" };
		p.write(pw + "\n");
		p.write(pw + "\n");
		let exit = p.close();
		return { ok: exit == 0, exit_code: exit };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (r.kind == "io_error")
		return errors.error(ctx, "internal_error", "could not exec passwd(1)");
	if (!r.ok) {
		audit_passwd_failure(ctx, user, r.exit_code);
		return errors.error(ctx, "internal_error",
			sprintf("passwd failed (exit %d); see syslog %s for details",
				r.exit_code, ctx.request_id));
	}
	audit_password(ctx, user);
	return errors.no_content(ctx);
}

function parse_public_key(line) {
	if (type(line) != "string") return null;
	let trimmed = trim(line);
	if (trimmed == "" || substr(trimmed, 0, 1) == "#") return null;
	let parts = split(trimmed, " ");
	let key_type_idx = -1;
	for (let i = 0; i < length(parts); i++) {
		if (VALID_KEY_TYPES[parts[i]]) { key_type_idx = i; break; }
	}
	if (key_type_idx < 0 || key_type_idx + 1 >= length(parts)) return null;
	let key_type = parts[key_type_idx];
	let blob = parts[key_type_idx + 1];
	if (!match(blob, BLOB_RE)) return null;
	let comment = "";
	if (key_type_idx + 2 < length(parts)) {
		let rest = [];
		for (let i = key_type_idx + 2; i < length(parts); i++) push(rest, parts[i]);
		comment = join(" ", rest);
	}
	let canonical = key_type + " " + blob;
	if (comment != "") canonical = canonical + " " + comment;
	// Stable id derived from the blob's tail (base64; we replace +/= with
	// lowercase ASCII so the id matches KEY_ID_RE for URL routing). No crypto
	// requirement: ids only need to be stable and collision-resistant enough
	// for a per-router authorized_keys file.
	let tail = length(blob) >= 12 ? substr(blob, length(blob) - 12) : blob;
	let id = "";
	for (let i = 0; i < length(tail); i++) {
		let c = substr(tail, i, 1);
		if (c == "+")      c = "g";
		else if (c == "/") c = "h";
		else if (c == "=") c = "z";
		else               c = lc(c);
		id = id + c;
	}
	return { id: id, type: key_type, blob: blob, comment: comment, canonical: canonical };
}

function read_keys() {
	let f = fs.open(KEYS_PATH, "r");
	if (!f) return [];
	let content = f.read("all") ?? "";
	f.close();
	let out = [];
	let seen = {};
	for (let line in split(content, "\n")) {
		let k = parse_public_key(line);
		if (k == null) continue;
		if (seen[k.id]) continue;
		seen[k.id] = true;
		push(out, k);
	}
	return out;
}

function write_keys(parsed_keys) {
	let lines = [];
	for (let k in parsed_keys) push(lines, k.canonical);
	let content = length(lines) > 0 ? (join("\n", lines) + "\n") : "";
	let f = fs.open(KEYS_PATH, "w");
	if (!f) return false;
	f.write(content);
	f.close();
	try { fs.chmod(KEYS_PATH, 384); } catch (e) {}  // 0600
	return true;
}

function key_view(k) {
	return { id: k.id, type: k.type, comment: k.comment };
}

function list_keys(ctx) {
	let keys_arr = read_keys();
	let view = [];
	for (let k in keys_arr) push(view, key_view(k));
	return errors.ok(ctx, view);
}

function get_key(ctx, id) {
	if (!match(id, KEY_ID_RE))
		return errors.error(ctx, "not_found", sprintf("invalid key id %J", id));
	let keys_arr = read_keys();
	for (let k in keys_arr)
		if (k.id == id) return errors.ok(ctx, key_view(k));
	return errors.error(ctx, "not_found", sprintf("no key with id %J", id));
}

function add_key(ctx, body) {
	if (type(body) != "object" || type(body.key) != "string")
		return errors.error(ctx, "bad_request",
			"Request body must be a JSON object with a 'key' string field");
	let parsed = parse_public_key(body.key);
	if (parsed == null)
		return errors.validation_failed(ctx, [errors.field_error("key", "invalid_format",
			sprintf("must be a valid SSH public key (allowed types: %s)",
				join(", ", keys(VALID_KEY_TYPES))))]);
	let r = transaction.with_lock({ fn: function() {
		let existing = read_keys();
		for (let k in existing)
			if (k.id == parsed.id)
				return { ok: false, kind: "conflict" };
		push(existing, parsed);
		if (!write_keys(existing)) return { ok: false, kind: "io_error" };
		return { ok: true };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (r.kind == "conflict")
		return errors.error(ctx, "conflict",
			sprintf("key %s already present", parsed.id));
	if (r.kind == "io_error")
		return errors.error(ctx, "internal_error",
			sprintf("could not write %s", KEYS_PATH));
	return errors.ok(ctx, key_view(parsed));
}

function replace_keys(ctx, body) {
	if (type(body) != "object" || type(body.keys) != "array")
		return errors.error(ctx, "bad_request",
			"Request body must be a JSON object with a 'keys' array field");
	let parsed = [];
	let errs = [];
	for (let i = 0; i < length(body.keys); i++) {
		let p = parse_public_key(body.keys[i]);
		if (p == null)
			push(errs, errors.field_error(sprintf("keys[%d]", i), "invalid_format",
				"must be a valid SSH public key"));
		else
			push(parsed, p);
	}
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);
	let seen = {};
	let final = [];
	for (let k in parsed) {
		if (seen[k.id]) continue;
		seen[k.id] = true;
		push(final, k);
	}
	let r = transaction.with_lock({ fn: function() {
		if (!write_keys(final)) return { ok: false, kind: "io_error" };
		return { ok: true };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (r.kind == "io_error")
		return errors.error(ctx, "internal_error",
			sprintf("could not write %s", KEYS_PATH));
	let view = [];
	for (let k in final) push(view, key_view(k));
	return errors.ok(ctx, view);
}

function remove_key(ctx, id) {
	if (!match(id, KEY_ID_RE))
		return errors.error(ctx, "not_found", sprintf("invalid key id %J", id));
	let r = transaction.with_lock({ fn: function() {
		let existing = read_keys();
		let kept = [];
		let found = false;
		for (let k in existing) {
			if (k.id == id) { found = true; continue; }
			push(kept, k);
		}
		if (!found) return { ok: false, kind: "not_found" };
		if (!write_keys(kept)) return { ok: false, kind: "io_error" };
		return { ok: true };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (r.kind == "not_found")
		return errors.error(ctx, "not_found", sprintf("no key with id %J", id));
	if (r.kind == "io_error")
		return errors.error(ctx, "internal_error",
			sprintf("could not write %s", KEYS_PATH));
	return errors.no_content(ctx);
}

return {
	set_password: set_password,
	list_keys: list_keys,
	get_key: get_key,
	add_key: add_key,
	replace_keys: replace_keys,
	remove_key: remove_key,
	parse_public_key: parse_public_key,
};
