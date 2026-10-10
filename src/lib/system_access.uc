let fs = require('fs');
let errors = require('errors');
let values = require('values');
let non_uci = require('non_uci');
let ids = require('ids');

const KEYS_PATH = "/etc/dropbear/authorized_keys";
const USER_RE = /^(root|[a-z][a-z0-9_-]*)$/;
const MIN_PASSWORD_LEN = 8;
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
	else {
		// passwd reads two lines via stdin, so an embedded newline splits the password and
		// confuses the confirmation step.
		if (values.has_control_chars(pw))
			push(errs, errors.field_error("password", "invalid_format",
				"must not contain control characters (newline, NUL, etc.)"));
	}
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);

	let lr = non_uci.with_lock_translated(ctx, function() {
		let cmd = sprintf("/bin/busybox passwd %s >/dev/null 2>&1", user);
		let p = fs.popen(cmd, "w");
		if (p == null) return { ok: false, kind: "io_error" };
		p.write(pw + "\n");
		p.write(pw + "\n");
		let exit = p.close();
		return { ok: exit == 0, exit_code: exit };
	}, { io_error: "could not exec passwd(1)" });
	if (lr.envelope) return lr.envelope;
	let r = lr.result;
	if (!r.ok) {
		non_uci.audit_warning(ctx, "passwd-failure", { user: user, exit: r.exit_code });
		return errors.error(ctx, "internal_error",
			sprintf("passwd failed (exit %d); see syslog %s for details",
				r.exit_code, ctx.request_id));
	}
	non_uci.audit_notice(ctx, "passwd-set", { user: user });
	return errors.no_content(ctx);
}

function parse_public_key(line) {
	if (type(line) != "string") return null;
	// Reject control characters anywhere in the input. A literal newline in a
	// comment would otherwise survive parsing and write a SECOND authorized_keys
	// line: an attacker could install two keys with one POST and bypass the
	// duplicate-id conflict check.
	for (let i = 0; i < length(line); i++) {
		let c = ord(substr(line, i, 1));
		if (c == 0 || c == 10 || c == 13) return null;
	}
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
	return { id: ids.content_id(blob), type: key_type, blob: blob,
	         comment: comment, canonical: canonical };
}

function read_keys() {
	let content = non_uci.read_file_if_present(KEYS_PATH) ?? "";
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
	return non_uci.replace_private_file(KEYS_PATH, content);
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
	if (!ids.is_content_id(id))
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
	let lr = non_uci.with_lock_translated(ctx, function() {
		let existing = read_keys();
		for (let k in existing)
			if (k.id == parsed.id)
				return { ok: false, kind: "conflict" };
		push(existing, parsed);
		if (!write_keys(existing)) return { ok: false, kind: "io_error" };
		return { ok: true };
	}, {
		conflict: sprintf("key %s already present", parsed.id),
		io_error: sprintf("could not write %s", KEYS_PATH),
	});
	if (lr.envelope) return lr.envelope;
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
	let lr = non_uci.with_lock_translated(ctx, function() {
		if (!write_keys(final)) return { ok: false, kind: "io_error" };
		return { ok: true };
	}, { io_error: sprintf("could not write %s", KEYS_PATH) });
	if (lr.envelope) return lr.envelope;
	let view = [];
	for (let k in final) push(view, key_view(k));
	return errors.ok(ctx, view);
}

function remove_key(ctx, id) {
	if (!ids.is_content_id(id))
		return errors.error(ctx, "not_found", sprintf("invalid key id %J", id));
	let lr = non_uci.with_lock_translated(ctx, function() {
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
	}, {
		not_found: sprintf("no key with id %J", id),
		io_error:  sprintf("could not write %s", KEYS_PATH),
	});
	if (lr.envelope) return lr.envelope;
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
