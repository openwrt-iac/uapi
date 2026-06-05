let ids = require('ids');
let error_ring = require('error_ring');

const STATUS_BY_CODE = {
	bad_request: 400,
	unauthorized: 401,
	invalid_token: 401,
	insufficient_scope: 403,
	scope_escalation_blocked: 403,
	tls_required: 403,
	not_found: 404,
	method_not_allowed: 405,
	conflict: 409,
	unmanaged_resource: 409,
	unsupported_media_type: 415,
	validation_failed: 422,
	locked: 423,
	too_many_requests: 429,
	precondition_failed: 412,
	invalid_cursor: 400,
	idempotency_key_conflict: 409,
	// batch_partial_failure body is emitted directly with the failing sub
	// request's HTTP status; no STATUS_BY_CODE entry needed.
	internal_error: 500,
	reload_failed_restored: 500,
	reload_failed_unrecovered: 500,
	service_unavailable: 503,
	init_script_missing: 503,
};

const FIELD_CODES = {
	required: true,
	invalid_type: true,
	invalid_format: true,
	out_of_range: true,
	not_in_enum: true,
	conflict: true,
	read_only: true,
};

// All codes the server may emit, including body-only codes that don't have a
// fixed HTTP status (batch_partial_failure carries the failing sub-request's
// status). Source for the OpenAPI ErrorEnvelope.code enum.
const ALL_CODES = [
	"bad_request", "invalid_cursor",
	"unauthorized", "invalid_token",
	"insufficient_scope", "scope_escalation_blocked", "tls_required",
	"not_found", "method_not_allowed",
	"conflict", "unmanaged_resource", "idempotency_key_conflict",
	"precondition_failed", "unsupported_media_type",
	"validation_failed", "locked", "too_many_requests",
	"internal_error", "reload_failed_restored", "reload_failed_unrecovered",
	"service_unavailable", "init_script_missing",
	"batch_partial_failure",
];

const REQUEST_ID_RE = /^[A-Za-z0-9_-]{8,128}$/;

// new_context accepts an optional client-supplied request id (from the
// X-Request-Id header). Invalid or missing values fall back to a fresh ULID.
function new_context(inbound_request_id) {
	if (type(inbound_request_id) == "string" && match(inbound_request_id, REQUEST_ID_RE))
		return { request_id: inbound_request_id };
	return { request_id: ids.new_ulid() };
}

function base_headers(ctx) {
	return {
		"Content-Type": "application/json",
		"X-Request-Id": ctx.request_id,
		// HSTS, nosniff, no-referrer (request_id leaks in URLs), no-store
		// (token-scoped data). Standard OWASP defaults for an API.
		"Strict-Transport-Security": "max-age=31536000; includeSubDomains",
		"X-Content-Type-Options": "nosniff",
		"Referrer-Policy": "no-referrer",
		"Cache-Control": "no-store",
	};
}

function error(ctx, code, message, extras) {
	let status = STATUS_BY_CODE[code];
	if (status == null)
		die(sprintf("errors.error: unknown code %J", code));

	let body = {
		code: code,
		message: message,
		request_id: ctx.request_id,
	};
	if (extras != null) {
		for (let k in extras) body[k] = extras[k];
	}
	let headers = base_headers(ctx);
	if (status == 401)
		headers["WWW-Authenticate"] =
			sprintf("Bearer realm=\"uapi\", error=\"%s\"", code);
	// Record into the diagnostics ring. Best-effort: error response wins
	// even if logging fails (disk full, permission, etc.). The append helper
	// already swallows exceptions; the extra null-check guards against
	// callers that synthesise envelopes without going through new_context.
	if (ctx != null && ctx.request_id != null)
		error_ring.append({
			ts: time(),
			request_id: ctx.request_id,
			code: code,
			status: status,
			method: ctx.method,
			path: ctx.path,
			message: message,
		});
	return { status, headers, body };
}

function field_error(field, code, message) {
	if (!FIELD_CODES[code])
		die(sprintf("errors.field_error: unknown field code %J", code));
	return { field, code, message };
}

function validation_failed(ctx, field_errors) {
	if (type(field_errors) != "array" || length(field_errors) == 0)
		die("errors.validation_failed: field_errors must be a non-empty array");
	return error(ctx, "validation_failed", "Request body failed validation",
	             { errors: field_errors });
}

// `info` (optional) carries the lock identity from transaction.uc:
//   { lock_kind: "package", package: "<pkg>" }  - per-package EX contention
//   { lock_kind: "global" }                      - global EX (non-uci writer)
// Omitting info preserves the v2.0.x wording for callers that don't pass it.
// The wrong wording (calling per-package contention "the global lock") sent
// at least one operator's debugging down the wrong path; the v2.0.2 fix is
// to identify exactly which lock the contention is on.
function locked(ctx, retry_after, info) {
	let msg;
	if (type(info) == "object" && info.lock_kind == "package" && type(info.package) == "string")
		msg = sprintf("Another write transaction holds the per-package lock for '%s'", info.package);
	else if (type(info) == "object" && info.lock_kind == "global")
		msg = "A non-uci writer holds the global write lock";
	else
		msg = "Another write transaction holds the lock";
	let r = error(ctx, "locked", msg);
	r.headers["Retry-After"] = "" + (retry_after ?? 1);
	return r;
}

function reload_failed_restored(ctx, reload_error) {
	return error(ctx, "reload_failed_restored",
	             "Service reload failed; prior configuration has been restored",
	             { reload_error });
}

function reload_failed_unrecovered(ctx, reload_error, restore_error) {
	return error(ctx, "reload_failed_unrecovered",
	             "Service reload failed AND restore failed; configuration is in an unknown state",
	             { reload_error, restore_error });
}

function ok(ctx, body) {
	return { status: 200, headers: base_headers(ctx), body };
}

function no_content(ctx) {
	return {
		status: 204,
		headers: { "X-Request-Id": ctx.request_id },
		body: null,
	};
}

return {
	new_context,
	error,
	field_error,
	validation_failed,
	locked,
	reload_failed_restored,
	reload_failed_unrecovered,
	ok,
	no_content,
	STATUS_BY_CODE,
	FIELD_CODES,
	ALL_CODES,
};
