let errors = require('errors');
let transaction = require('transaction');
let log = require('log');

const KIND_TO_CODE = {
	conflict:  "conflict",
	not_found: "not_found",
	gone:      "not_found",
	io_error:  "internal_error",
};

const _LOGFMT_SAFE = /^[A-Za-z0-9_.\/@:+-]+$/;

function _logfmt_value(v) {
	let t = type(v);
	if (t == "int" || t == "double" || t == "bool") return sprintf("%J", v);
	if (v == null) return "null";
	if (t == "string" && v != "" && match(v, _LOGFMT_SAFE)) return v;
	return sprintf("%J", v);
}

function with_lock_translated(ctx, fn, kind_messages, lock_opts) {
	let params = { fn: fn };
	if (lock_opts != null) {
		if (lock_opts.acquire != null)   params.acquire   = lock_opts.acquire;
		if (lock_opts.release != null)   params.release   = lock_opts.release;
		if (lock_opts.lock_path != null) params.lock_path = lock_opts.lock_path;
	}
	let r = transaction.with_lock(params);

	if (r.kind == "locked")
		return { envelope: errors.locked_from(ctx, null, r) };
	if (r.kind == "lock_unavailable")
		return { envelope: errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error)) };

	// A known kind always becomes an envelope. A missing caller-supplied
	// message falls back to a generic line rather than silently treating
	// the failure as success (which would let the caller dereference a
	// payload that isn't there).
	if (r.kind != null && KIND_TO_CODE[r.kind] != null) {
		let msg = (kind_messages != null) ? kind_messages[r.kind] : null;
		if (msg == null) msg = sprintf("operation failed: %s", r.kind);
		return { envelope: errors.error(ctx, KIND_TO_CODE[r.kind], msg) };
	}

	return { result: r };
}

function _audit(ctx, level, action, fields) {
	let parts = [sprintf("uapi-%s %s", action, ctx.request_id)];
	if (type(fields) == "object") {
		for (let k in fields)
			push(parts, k + "=" + _logfmt_value(fields[k]));
	}
	log.syslog(level, join(" ", parts));
}

function audit_notice(ctx, action, fields) {
	_audit(ctx, log.LOG_NOTICE, action, fields);
}

function audit_warning(ctx, action, fields) {
	_audit(ctx, log.LOG_WARNING, action, fields);
}

return { with_lock_translated, audit_notice, audit_warning };
