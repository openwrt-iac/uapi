let ids = require('ids');

const STATUS_BY_CODE = {
	bad_request: 400,
	unauthorized: 401,
	invalid_token: 401,
	insufficient_scope: 403,
	tls_required: 403,
	not_found: 404,
	method_not_allowed: 405,
	conflict: 409,
	unmanaged_resource: 409,
	unsupported_media_type: 415,
	validation_failed: 422,
	locked: 423,
	internal_error: 500,
	reload_failed_restored: 500,
	reload_failed_unrecovered: 500,
	service_unavailable: 503,
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

function new_context() {
	return { request_id: ids.new_ulid() };
}

function base_headers(ctx) {
	return {
		"Content-Type": "application/json",
		"X-Request-Id": ctx.request_id,
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
	return { status, headers: base_headers(ctx), body };
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

function locked(ctx, retry_after) {
	let r = error(ctx, "locked",
	              "Another write transaction holds the global lock");
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
};
