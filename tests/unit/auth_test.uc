let t = require('harness');
let auth = require('auth');

function plain_hash(salt, bearer) {
	return salt + ":" + bearer;
}

let TOKENS = [
	{ name: "admin", salt: "saltA", hash: "saltA:good_admin", scopes: ["*:rw"] },
	{ name: "ro",    salt: "saltB", hash: "saltB:good_ro",    scopes: ["*:ro"] },
	{ name: "fw",    salt: "saltC", hash: "saltC:good_fw",    scopes: ["firewall:rw"] },
];

t.describe('auth.authorize, missing header', () => {
	t.it('returns unauthorized for null header', () => {
		let r = auth.authorize(TOKENS, null, plain_hash);
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "unauthorized");
	});

	t.it('returns unauthorized for empty string', () => {
		t.assert_equal(auth.authorize(TOKENS, "", plain_hash).kind, "unauthorized");
	});

	t.it('returns unauthorized for non-string header', () => {
		t.assert_equal(auth.authorize(TOKENS, 42, plain_hash).kind, "unauthorized");
		t.assert_equal(auth.authorize(TOKENS, [], plain_hash).kind, "unauthorized");
	});
});

t.describe('auth.authorize, header parsing', () => {
	t.it('returns unauthorized for non-Bearer scheme', () => {
		t.assert_equal(auth.authorize(TOKENS, "Basic abc", plain_hash).kind, "unauthorized");
		t.assert_equal(auth.authorize(TOKENS, "good_admin", plain_hash).kind, "unauthorized");
	});

	t.it('accepts tab or multiple spaces between Bearer and token', () => {
		t.assert_true(auth.authorize(TOKENS, "Bearer good_admin", plain_hash).ok);
		t.assert_true(auth.authorize(TOKENS, "Bearer    good_admin", plain_hash).ok);
		t.assert_true(auth.authorize(TOKENS, "Bearer\tgood_admin", plain_hash).ok);
	});

	t.it('rejects header with invalid token chars', () => {
		t.assert_equal(auth.authorize(TOKENS, "Bearer abc!def", plain_hash).kind, "unauthorized");
		t.assert_equal(auth.authorize(TOKENS, "Bearer abc def", plain_hash).kind, "unauthorized");
	});

	t.it('is case-sensitive on the Bearer keyword', () => {
		t.assert_equal(auth.authorize(TOKENS, "bearer good_admin", plain_hash).kind, "unauthorized");
	});
});

t.describe('auth.authorize, token lookup via hash', () => {
	t.it('returns invalid_token for unknown bearer', () => {
		t.assert_equal(auth.authorize(TOKENS, "Bearer not_a_token", plain_hash).kind, "invalid_token");
	});

	t.it('returns invalid_token when tokens is not an array', () => {
		t.assert_equal(auth.authorize(null, "Bearer x", plain_hash).kind, "invalid_token");
		t.assert_equal(auth.authorize({}, "Bearer x", plain_hash).kind, "invalid_token");
	});

	t.it('skips token records missing salt or hash', () => {
		let partial = [{ name: "broken", scopes: ["*:rw"] }];
		t.assert_equal(auth.authorize(partial, "Bearer anything", plain_hash).kind, "invalid_token");
	});

	t.it('returns the matching token record with name and scopes', () => {
		let r = auth.authorize(TOKENS, "Bearer good_fw", plain_hash);
		t.assert_true(r.ok);
		t.assert_equal(r.token.name, "fw");
		t.assert_deep_equal(r.token.scopes, ["firewall:rw"]);
	});

	t.it('defaults missing scopes to an empty array', () => {
		let scopeless = [{ name: "x", salt: "s", hash: "s:t" }];
		let r = auth.authorize(scopeless, "Bearer t", plain_hash);
		t.assert_true(r.ok);
		t.assert_deep_equal(r.token.scopes, []);
	});
});

t.describe('auth.authorize, expiry', () => {
	let WITH_EXPIRY = [{
		name: "shortlived", salt: "s1", hash: "s1:expiring",
		scopes: ["*:rw"], expires_at: 1000,
	}];

	t.it('accepts a token while it is still valid', () => {
		let r = auth.authorize(WITH_EXPIRY, "Bearer expiring", plain_hash,
			{ now: 999, remote_addr: "127.0.0.1" });
		t.assert_true(r.ok);
		t.assert_equal(r.token.expires_at, 1000);
	});

	t.it('rejects a token exactly at expiry second', () => {
		let r = auth.authorize(WITH_EXPIRY, "Bearer expiring", plain_hash,
			{ now: 1000, remote_addr: "127.0.0.1" });
		t.assert_false(r.ok);
		t.assert_equal(r.kind, "invalid_token");
		t.assert_equal(r.reason, "expired");
	});

	t.it('rejects a token past expiry', () => {
		let r = auth.authorize(WITH_EXPIRY, "Bearer expiring", plain_hash,
			{ now: 9999, remote_addr: "127.0.0.1" });
		t.assert_equal(r.reason, "expired");
	});

	t.it('skips expiry when now is not provided', () => {
		// Falling back to no-check is safer than failing closed: a clockless
		// router otherwise locks itself out of every token. Caller decides.
		let r = auth.authorize(WITH_EXPIRY, "Bearer expiring", plain_hash, {});
		t.assert_true(r.ok);
	});
});

t.describe('auth.authorize, IP scoping', () => {
	let CIDR_SCOPED = [{
		name: "lan", salt: "s2", hash: "s2:lanonly",
		scopes: ["*:rw"], allowed_cidrs: ["192.168.1.0/24"],
	}];

	t.it('accepts a request from inside the allowed CIDR', () => {
		let r = auth.authorize(CIDR_SCOPED, "Bearer lanonly", plain_hash,
			{ remote_addr: "192.168.1.42", now: 100 });
		t.assert_true(r.ok);
	});

	t.it('rejects a request from outside the allowed CIDRs', () => {
		let r = auth.authorize(CIDR_SCOPED, "Bearer lanonly", plain_hash,
			{ remote_addr: "10.0.0.5", now: 100 });
		t.assert_false(r.ok);
		t.assert_equal(r.reason, "ip_not_permitted");
	});

	t.it('accepts an IPv4-mapped IPv6 address inside the CIDR', () => {
		let r = auth.authorize(CIDR_SCOPED, "Bearer lanonly", plain_hash,
			{ remote_addr: "::ffff:192.168.1.99", now: 100 });
		t.assert_true(r.ok);
	});

	t.it('empty allowed_cidrs means any source', () => {
		let any_ip = [{ name: "open", salt: "s3", hash: "s3:open",
		                scopes: ["*:ro"], allowed_cidrs: [] }];
		let r = auth.authorize(any_ip, "Bearer open", plain_hash,
			{ remote_addr: "8.8.8.8", now: 100 });
		t.assert_true(r.ok);
	});
});


