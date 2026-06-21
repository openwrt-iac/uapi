let t = require('harness');

let ac = loadfile('src/lib/apply_confirm.uc')();

// The build/unit environment has no /usr/sbin/apply-confirm, so ac_present() is
// false. That lets every guard path be reached: input validation runs before
// the presence check, and the presence check itself yields confirm_unavailable.

t.describe('apply_confirm.ac_present', () => {
	t.it('is false when the binary is not installed (unit env)', () => {
		t.assert_equal(ac.ac_present(), false);
	});
});

t.describe('apply_confirm.ac_stage validation', () => {
	t.it('rejects a non-positive timeout with bad_request', () => {
		let r = ac.ac_stage(["network"], ["network"], 0);
		t.assert_equal(r.kind, "bad_request");
	});

	t.it('rejects a non-integer timeout with bad_request', () => {
		let r = ac.ac_stage(["network"], ["network"], "60");
		t.assert_equal(r.kind, "bad_request");
	});

	t.it('rejects an empty package list with confirm_stage_failed', () => {
		let r = ac.ac_stage([], [], 60);
		t.assert_equal(r.kind, "confirm_stage_failed");
	});

	t.it('rejects an unsafe package name before it reaches the shell', () => {
		let r = ac.ac_stage(["net; rm -rf /"], [], 60);
		t.assert_equal(r.kind, "confirm_stage_failed");
	});

	t.it('rejects an unsafe service name', () => {
		let r = ac.ac_stage(["network"], ["svc;evil"], 60);
		t.assert_equal(r.kind, "confirm_stage_failed");
	});

	t.it('returns confirm_unavailable when inputs are valid but the binary is absent', () => {
		let r = ac.ac_stage(["network"], ["network"], 60);
		t.assert_equal(r.kind, "confirm_unavailable");
	});
});

t.describe('apply_confirm control verbs (token guard + presence)', () => {
	t.it('ac_ack rejects a malformed token with bad_request', () => {
		t.assert_equal(ac.ac_ack("not-a-token").kind, "bad_request");
	});

	t.it('ac_ack accepts a well-formed token shape but degrades to confirm_unavailable', () => {
		t.assert_equal(ac.ac_ack("ac_1718900000_a1b2c3d4").kind, "confirm_unavailable");
	});

	t.it('ac_rollback rejects a malformed token with bad_request', () => {
		t.assert_equal(ac.ac_rollback("../etc/passwd").kind, "bad_request");
	});

	t.it('ac_rollback degrades to confirm_unavailable for a valid token shape', () => {
		t.assert_equal(ac.ac_rollback("ac_1718900000_a1b2c3d4").kind, "confirm_unavailable");
	});

	t.it('ac_status rejects a malformed token with bad_request', () => {
		t.assert_equal(ac.ac_status("ac_BAD").kind, "bad_request");
	});

	t.it('ac_status degrades to confirm_unavailable for a valid token shape', () => {
		t.assert_equal(ac.ac_status("ac_1718900000_a1b2c3d4").kind, "confirm_unavailable");
	});

	t.it('ac_list degrades to confirm_unavailable when the binary is absent', () => {
		t.assert_equal(ac.ac_list().kind, "confirm_unavailable");
	});
});
