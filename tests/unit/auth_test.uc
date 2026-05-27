let t = require('harness');
let auth = require('auth');

let TOKENS = {
	"good_admin": { name: "admin", scopes: ["*:rw"] },
	"good_ro":    { name: "ro",    scopes: ["*:ro"] },
	"good_fw":    { name: "fw",    scopes: ["firewall:rw"] },
};

t.describe('auth.authorize, missing header', () => {
	t.it('returns unauthorized for null header', () => {
		let r = auth.authorize(TOKENS, null);
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "unauthorized");
	});

	t.it('returns unauthorized for empty string', () => {
		let r = auth.authorize(TOKENS, "");
		t.assert_equal(r.kind, "unauthorized");
	});

	t.it('returns unauthorized for non-string header', () => {
		t.assert_equal(auth.authorize(TOKENS, 42).kind, "unauthorized");
		t.assert_equal(auth.authorize(TOKENS, []).kind, "unauthorized");
	});
});

t.describe('auth.authorize, header parsing', () => {
	t.it('returns unauthorized for non-Bearer scheme', () => {
		t.assert_equal(auth.authorize(TOKENS, "Basic abc").kind, "unauthorized");
		t.assert_equal(auth.authorize(TOKENS, "good_admin").kind, "unauthorized");
	});

	t.it('accepts tab or multiple spaces between Bearer and token', () => {
		let r1 = auth.authorize(TOKENS, "Bearer good_admin");
		let r2 = auth.authorize(TOKENS, "Bearer    good_admin");
		let r3 = auth.authorize(TOKENS, "Bearer\tgood_admin");
		t.assert_true(r1.ok);
		t.assert_true(r2.ok);
		t.assert_true(r3.ok);
	});

	t.it('rejects header with invalid token chars', () => {
		t.assert_equal(auth.authorize(TOKENS, "Bearer abc!def").kind, "unauthorized");
		t.assert_equal(auth.authorize(TOKENS, "Bearer abc def").kind, "unauthorized");
	});

	t.it('is case-sensitive on the Bearer keyword', () => {
		t.assert_equal(auth.authorize(TOKENS, "bearer good_admin").kind, "unauthorized");
		t.assert_equal(auth.authorize(TOKENS, "BEARER good_admin").kind, "unauthorized");
	});
});

t.describe('auth.authorize, token lookup', () => {
	t.it('returns invalid_token for unknown bearer', () => {
		let r = auth.authorize(TOKENS, "Bearer not_a_token");
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "invalid_token");
	});

	t.it('returns the matching token record', () => {
		let r = auth.authorize(TOKENS, "Bearer good_fw");
		t.assert_true(r.ok);
		t.assert_equal(r.token.name, "fw");
		t.assert_deep_equal(r.token.scopes, ["firewall:rw"]);
	});

	t.it('returns the exact record by identity (not a copy)', () => {
		let r = auth.authorize(TOKENS, "Bearer good_admin");
		t.assert_true(r.token === TOKENS.good_admin);
	});
});

t.describe('auth.stub_token', () => {
	t.it('returns a *:rw admin-shaped token', () => {
		let tok = auth.stub_token();
		t.assert_equal(tok.name, "stub");
		t.assert_deep_equal(tok.scopes, ["*:rw"]);
	});
});
