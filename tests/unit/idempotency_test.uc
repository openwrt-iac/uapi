let t = require('harness');
let fs = require('fs');
let idem = require('idempotency');

function wipe() {
	let dir = "/tmp/uapi-idempotency";
	let entries;
	try { entries = fs.lsdir(dir); } catch (_) { return; }
	for (let n in entries ?? []) {
		try { fs.unlink(dir + "/" + n); } catch (_) {}
	}
}

t.describe('idempotency.validate_key', () => {
	t.it('accepts well-formed keys', () => {
		t.assert_true(idem.validate_key("01HX1234567890ABCDEFGHJKMN"));
		t.assert_true(idem.validate_key("client-side-uuid_42"));
	});

	t.it('rejects ill-formed keys', () => {
		t.assert_false(idem.validate_key(""));
		t.assert_false(idem.validate_key("has spaces"));
		t.assert_false(idem.validate_key(null));
		t.assert_false(idem.validate_key(42));
	});
});

t.describe('idempotency.lookup + store round-trip', () => {
	t.it('miss when nothing was stored', () => {
		wipe();
		let r = idem.lookup("test_token", "key_a", "{}", 1700000000);
		t.assert_equal(r.state, "miss");
	});

	t.it('hit when same (token, key, body) repeats', () => {
		wipe();
		let resp = { status: 200, headers: { "Content-Type": "application/json" },
		             body: { id: "r_xyz", managed: true } };
		idem.store("test_token", "key_a", "{\"name\":\"x\"}", resp);
		let r = idem.lookup("test_token", "key_a", "{\"name\":\"x\"}", 1700000000);
		t.assert_equal(r.state, "hit");
		t.assert_equal(r.response.status, 200);
		t.assert_equal(r.response.body.id, "r_xyz");
	});

	t.it('conflict when same key reused with a different body', () => {
		wipe();
		let resp = { status: 200, headers: {}, body: {} };
		idem.store("test_token", "key_b", "{\"name\":\"orig\"}", resp);
		let r = idem.lookup("test_token", "key_b", "{\"name\":\"changed\"}", 1700000000);
		t.assert_equal(r.state, "conflict");
	});

	t.it('different tokens with same key are isolated', () => {
		wipe();
		let resp = { status: 201, headers: {}, body: { token: "alpha" } };
		idem.store("token_alpha", "shared_key", "{}", resp);
		let r = idem.lookup("token_beta", "shared_key", "{}", 1700000000);
		t.assert_equal(r.state, "miss");
	});
});
