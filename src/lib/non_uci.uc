// Shared scaffolding for resources whose source of truth is not /etc/config/.
// Packages, system/password, and system/authorized_keys all need the same
// transaction.with_lock + standard result-translation + audit syslog plumbing.
// Centralising it keeps each non-uci resource focused on its own work.

let errors = require('errors');
let transaction = require('transaction');
let log = require('log');

// Map a fn-returned `kind` to an error envelope code. Lock kinds are handled
// directly; the rest use this table.
const KIND_TO_CODE = {
	conflict:    "conflict",
	not_found:   "not_found",
	gone:        "not_found",
	io_error:    "internal_error",
	exec_failed: "internal_error",
	bad_request: "bad_request",
};

// Wrap transaction.with_lock(fn) with standard error-envelope translation.
// fn returns `{ ok: bool, kind?: string, ...payload }`. Returns an object:
// - { envelope: <response> } when an error envelope is ready to return as-is
// - { result: <fn-return> }  when fn succeeded; caller handles the success body
//
// kind_messages maps fn-returned kind => human message. Only kinds present in
// KIND_TO_CODE need a message here; lock kinds (locked, lock_unavailable) are
// auto-translated.
//
// lock_opts (optional): { acquire, release, lock_path } passed through to
// transaction.with_lock for test injection.
function with_lock_translated(ctx, fn, kind_messages, lock_opts) {
	let params = { fn: fn };
	if (lock_opts != null) {
		if (lock_opts.acquire != null)   params.acquire   = lock_opts.acquire;
		if (lock_opts.release != null)   params.release   = lock_opts.release;
		if (lock_opts.lock_path != null) params.lock_path = lock_opts.lock_path;
	}
	let r = transaction.with_lock(params);

	if (r.kind == "locked")
		return { envelope: errors.locked(ctx) };
	if (r.kind == "lock_unavailable")
		return { envelope: errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error)) };

	if (r.kind != null && KIND_TO_CODE[r.kind] != null) {
		let msg = (kind_messages != null) ? kind_messages[r.kind] : null;
		if (msg != null)
			return { envelope: errors.error(ctx, KIND_TO_CODE[r.kind], msg) };
	}

	return { result: r };
}

// One-line syslog emitter for non-uci-resource audits. Format matches the
// existing convention: "uapi-<action> <request_id> field=value field=value..."
// Levels surface as LOG_NOTICE for successes and LOG_WARNING for failures by
// helper convention; callers pass the chosen level explicitly.
function audit(ctx, level, action, fields) {
	let parts = [sprintf("uapi-%s %s", action, ctx.request_id)];
	if (type(fields) == "object") {
		for (let k in fields)
			push(parts, sprintf("%s=%J", k, fields[k]));
	}
	log.syslog(level, join(" ", parts));
}

function audit_notice(ctx, action, fields) {
	audit(ctx, log.LOG_NOTICE, action, fields);
}

function audit_warning(ctx, action, fields) {
	audit(ctx, log.LOG_WARNING, action, fields);
}

return {
	with_lock_translated,
	audit,
	audit_notice,
	audit_warning,
};
