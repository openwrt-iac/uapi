let t = require('harness');
let non_uci = require('non_uci');

function ctx() { return { request_id: "01hxnonuci0000000000000000" }; }
const LOCK_STUB = { acquire: function() { return {}; }, release: function() {} };

t.describe('non_uci.with_lock_translated', () => {
	t.it('lock contention yields locked envelope', () => {
		let lr = non_uci.with_lock_translated(ctx(),
			function() { return { ok: true }; }, {},
			{ acquire: function() { return null; }, release: function() {} });
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 423);
		t.assert_equal(lr.envelope.body.code, "locked");
	});

	t.it('lock_unavailable yields internal_error envelope', () => {
		let lr = non_uci.with_lock_translated(ctx(),
			function() { return { ok: true }; }, {},
			{ acquire: function() { return { unavailable: "/no/such" }; },
			  release: function() {} });
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 500);
	});

	t.it('translates kind=conflict to envelope when message provided', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "conflict" };
		}, { conflict: "thing already exists" }, LOCK_STUB);
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 409);
		t.assert_equal(lr.envelope.body.code, "conflict");
		t.assert_equal(lr.envelope.body.message, "thing already exists");
	});

	t.it('translates kind=not_found to 404', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "not_found" };
		}, { not_found: "gone" }, LOCK_STUB);
		t.assert_equal(lr.envelope.status, 404);
		t.assert_equal(lr.envelope.body.code, "not_found");
	});

	t.it('translates kind=io_error to 500 internal_error', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "io_error" };
		}, { io_error: "disk full" }, LOCK_STUB);
		t.assert_equal(lr.envelope.status, 500);
		t.assert_equal(lr.envelope.body.code, "internal_error");
	});

	t.it('translates kind=gone to 404', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "gone" };
		}, { gone: "vanished" }, LOCK_STUB);
		t.assert_equal(lr.envelope.status, 404);
	});

	t.it('unmapped kind falls through as result (caller handles)', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "weird_custom_kind", payload: 42 };
		}, {}, LOCK_STUB);
		t.assert_true(lr.envelope == null);
		t.assert_equal(lr.result.kind, "weird_custom_kind");
		t.assert_equal(lr.result.payload, 42);
	});

	t.it('mapped kind WITHOUT a caller-supplied message still produces an envelope', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "conflict" };
		}, {}, LOCK_STUB);
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 409);
		t.assert_equal(lr.envelope.body.code, "conflict");
		t.assert_true(match(lr.envelope.body.message, /operation failed: conflict/) != null);
	});

	t.it('success result passes through with all fields', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: true, info: { foo: "bar" }, count: 7 };
		}, {}, LOCK_STUB);
		t.assert_true(lr.envelope == null);
		t.assert_true(lr.result.ok);
		t.assert_equal(lr.result.info.foo, "bar");
		t.assert_equal(lr.result.count, 7);
	});
});
