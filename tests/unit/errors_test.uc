let t = require('harness');
let errors = require('errors');
let ids = require('ids');

t.describe('errors.new_context', () => {
	t.it('produces a fresh request_id per call', () => {
		let a = errors.new_context();
		let b = errors.new_context();
		t.assert_true(a.request_id != b.request_id);
		t.assert_equal(length(a.request_id), 26);
	});

	t.it('accepts a well-formed inbound request id', () => {
		let id = "req-01HX9876543210ABCDEFGH";
		let ctx = errors.new_context(id);
		t.assert_equal(ctx.request_id, id);
	});

	t.it('falls back to a generated id when inbound is malformed', () => {
		let ctx = errors.new_context("short");
		t.assert_true(ctx.request_id != "short");
		t.assert_equal(length(ctx.request_id), 26);
	});

	t.it('falls back when inbound contains forbidden characters', () => {
		let ctx = errors.new_context("bad space and slash/");
		t.assert_true(ctx.request_id != "bad space and slash/");
	});

	t.it('falls back when inbound is null or non-string', () => {
		let a = errors.new_context(null);
		t.assert_equal(length(a.request_id), 26);
		let b = errors.new_context(42);
		t.assert_equal(length(b.request_id), 26);
	});
});

t.describe('errors.error', () => {
	let ctx = { request_id: "01hx0000000000000000000000" };

	t.it('builds a standard envelope', () => {
		let r = errors.error(ctx, "not_found", "missing");
		t.assert_equal(r.status, 404);
		t.assert_equal(r.body.code, "not_found");
		t.assert_equal(r.body.message, "missing");
		t.assert_equal(r.body.request_id, "01hx0000000000000000000000");
		t.assert_equal(r.headers["X-Request-Id"], "01hx0000000000000000000000");
		t.assert_equal(r.headers["Content-Type"], "application/json");
	});

	t.it('maps every known code to its documented status', () => {
		let expected = {
			bad_request: 400, unauthorized: 401, invalid_token: 401,
			insufficient_scope: 403, tls_required: 403,
			not_found: 404, method_not_allowed: 405,
			conflict: 409, unmanaged_resource: 409,
			unsupported_media_type: 415, validation_failed: 422,
			locked: 423,
			internal_error: 500, reload_failed_restored: 500,
			reload_failed_unrecovered: 500, service_unavailable: 503,
		};
		for (let code in expected) {
			let r = errors.error(ctx, code, "msg");
			t.assert_equal(r.status, expected[code], code);
		}
	});

	t.it('rejects unknown codes', () => {
		t.assert_throws(() => errors.error(ctx, "made_up_code", "x"));
	});

	t.it('merges extras into the body', () => {
		let r = errors.error(ctx, "conflict", "dup", { existing_id: "u_abc" });
		t.assert_equal(r.body.existing_id, "u_abc");
		t.assert_equal(r.body.code, "conflict");
	});

	t.it('adds WWW-Authenticate on 401 unauthorized', () => {
		let r = errors.error(ctx, "unauthorized", "missing header");
		t.assert_equal(r.status, 401);
		t.assert_equal(r.headers["WWW-Authenticate"],
		               "Bearer realm=\"uapi\", error=\"unauthorized\"");
	});

	t.it('adds WWW-Authenticate on 401 invalid_token', () => {
		let r = errors.error(ctx, "invalid_token", "not recognised");
		t.assert_equal(r.headers["WWW-Authenticate"],
		               "Bearer realm=\"uapi\", error=\"invalid_token\"");
	});

	t.it('does not add WWW-Authenticate on non-401 statuses', () => {
		let r = errors.error(ctx, "insufficient_scope", "nope");
		t.assert_equal(r.status, 403);
		t.assert_equal(r.headers["WWW-Authenticate"], null);
	});
});

t.describe('errors.field_error', () => {
	t.it('builds a field error record', () => {
		let f = errors.field_error("ipaddr", "invalid_format", "must be a valid IPv4");
		t.assert_deep_equal(f, {
			field: "ipaddr",
			code: "invalid_format",
			message: "must be a valid IPv4",
		});
	});

	t.it('rejects unknown field codes', () => {
		t.assert_throws(() => errors.field_error("x", "bogus", "msg"));
	});
});

t.describe('errors.validation_failed', () => {
	let ctx = { request_id: "01hx0000000000000000000000" };

	t.it('returns a 422 envelope with errors[]', () => {
		let r = errors.validation_failed(ctx, [
			errors.field_error("name", "required", "is required"),
			errors.field_error("target", "not_in_enum", "must be ACCEPT/REJECT/DROP"),
		]);
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.code, "validation_failed");
		t.assert_equal(length(r.body.errors), 2);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[1].field, "target");
	});

	t.it('rejects empty error arrays', () => {
		t.assert_throws(() => errors.validation_failed(ctx, []));
	});
});

t.describe('errors.locked', () => {
	let ctx = { request_id: "01hx0000000000000000000000" };

	t.it('returns 423 with Retry-After header', () => {
		let r = errors.locked(ctx);
		t.assert_equal(r.status, 423);
		t.assert_equal(r.body.code, "locked");
		t.assert_equal(r.headers["Retry-After"], "1");
	});

	t.it('accepts a custom retry-after value', () => {
		let r = errors.locked(ctx, 5);
		t.assert_equal(r.headers["Retry-After"], "5");
	});
});

t.describe('errors.reload_failed_restored', () => {
	let ctx = { request_id: "01hx0000000000000000000000" };

	t.it('carries the underlying reload error', () => {
		let r = errors.reload_failed_restored(ctx, "netifd: bad proto");
		t.assert_equal(r.status, 500);
		t.assert_equal(r.body.code, "reload_failed_restored");
		t.assert_equal(r.body.reload_error, "netifd: bad proto");
	});
});

t.describe('errors.reload_failed_unrecovered', () => {
	let ctx = { request_id: "01hx0000000000000000000000" };

	t.it('carries both reload and restore errors', () => {
		let r = errors.reload_failed_unrecovered(ctx, "reload err", "restore err");
		t.assert_equal(r.status, 500);
		t.assert_equal(r.body.reload_error, "reload err");
		t.assert_equal(r.body.restore_error, "restore err");
	});
});

t.describe('errors.ok and errors.no_content', () => {
	let ctx = { request_id: "01hx0000000000000000000000" };

	t.it('ok wraps the body, sets 200, sets request_id header', () => {
		let r = errors.ok(ctx, { id: "u_abc", managed: true });
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body, { id: "u_abc", managed: true });
		t.assert_equal(r.headers["X-Request-Id"], "01hx0000000000000000000000");
	});

	t.it('no_content is 204 with null body and request_id header', () => {
		let r = errors.no_content(ctx);
		t.assert_equal(r.status, 204);
		t.assert_equal(r.body, null);
		t.assert_equal(r.headers["X-Request-Id"], "01hx0000000000000000000000");
	});
});
