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

// Other daemons of the box run as other users.
t.describe('idempotency.store keeps its entries private and bounded', () => {
	let dir = "/tmp/uapi-idempotency";
	let resp = { status: 200, headers: {}, body: { token: "uapi_secret" } };
	let mode = (p) => fs.stat(p).mode & 511;
	let entries = () => filter(fs.lsdir(dir) ?? [], (n) => !match(n, /^\.|\.tmp$/));

	t.it('writes the directory 0700 and each entry 0600, also over a directory that an older uapi made 0755', () => {
		wipe();
		fs.mkdir(dir);
		fs.chmod(dir, 493);
		t.assert_equal(mode(dir), 493);
		t.assert_true(idem.store("test_token", "key_p", "{}", resp));
		t.assert_equal(mode(dir), 448);
		let files = entries();
		t.assert_equal(length(files), 1);
		t.assert_equal(mode(dir + "/" + files[0]), 384);
	});

	t.it('keeps the entries younger than the TTL and removes the older ones', () => {
		wipe();
		let now = time();
		idem.store("test_token", "key_old", "{}", resp, now);
		idem.store("test_token", "key_mid", "{}", resp, now + 43200);
		t.assert_equal(idem.lookup("test_token", "key_old", "{}", now).state, "hit");
		idem.store("test_token", "key_new", "{}", resp, now + 86400 + 60);
		t.assert_equal(idem.lookup("test_token", "key_old", "{}", now).state, "miss");
		t.assert_equal(idem.lookup("test_token", "key_new", "{}", now).state, "hit");
		t.assert_equal(length(entries()), 1);
	});

	t.it('stores and finds nothing when the path is not a directory that this process owns', () => {
		let elsewhere = "/tmp/uapi-idempotency-elsewhere";
		if (fs.lstat(dir)?.type == "link") { fs.unlink(dir); fs.rename(elsewhere, dir); }
		wipe();
		t.assert_true(idem.store("test_token", "key_l", "{}", resp));
		fs.rename(dir, elsewhere);
		fs.symlink(elsewhere, dir);
		let before = length(fs.lsdir(elsewhere));
		t.assert_equal(idem.lookup("test_token", "key_l", "{}", time()).state, "miss");
		t.assert_false(idem.store("test_token", "key_l2", "{}", resp));
		t.assert_equal(length(fs.lsdir(elsewhere)), before);
		fs.unlink(dir);
		fs.rename(elsewhere, dir);
	});
});
