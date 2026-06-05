let t = require('harness');
let ids = require('ids');

t.describe('ids.new_ulid', () => {
	t.it('produces 26-char strings', () => {
		for (let i = 0; i < 100; i++)
			t.assert_equal(length(ids.new_ulid()), 26);
	});

	t.it('uses only Crockford base32 alphabet', () => {
		let id = ids.new_ulid();
		t.assert_match(id, /^[0-9a-hjkmnp-tv-z]{26}$/);
	});

	t.it('is unique across many calls', () => {
		let seen = {};
		for (let i = 0; i < 1000; i++) {
			let id = ids.new_ulid();
			t.assert_false(exists(seen, id), sprintf("collision on %s", id));
			seen[id] = true;
		}
	});

	t.it('is monotonic across rapid calls (timestamp portion non-decreasing)', () => {
		let prev = substr(ids.new_ulid(), 0, 10);
		for (let i = 0; i < 100; i++) {
			let cur = substr(ids.new_ulid(), 0, 10);
			t.assert_true(cur >= prev, sprintf("regressed: %s -> %s", prev, cur));
			prev = cur;
		}
	});
});

t.describe('ids.new_id', () => {
	t.it('defaults to u_ prefix', () => {
		t.assert_match(ids.new_id(), /^u_[0-9a-hjkmnp-tv-z]{26}$/);
	});

	t.it('accepts a custom prefix letter', () => {
		t.assert_match(ids.new_id("r"), /^r_[0-9a-hjkmnp-tv-z]{26}$/);
		t.assert_match(ids.new_id("i"), /^i_[0-9a-hjkmnp-tv-z]{26}$/);
	});

	t.it('accepts a 2- or 3-char prefix (wg, sqm, etc.)', () => {
		t.assert_match(ids.new_id("wg"), /^wg_[0-9a-hjkmnp-tv-z]{26}$/);
		t.assert_match(ids.new_id("sqm"), /^sqm_[0-9a-hjkmnp-tv-z]{26}$/);
	});

	t.it('rejects prefixes longer than 3 chars', () => {
		t.assert_throws(() => ids.new_id("abcd"));
	});

	t.it('rejects uppercase or digit prefixes', () => {
		t.assert_throws(() => ids.new_id("R"));
		t.assert_throws(() => ids.new_id("1"));
		t.assert_throws(() => ids.new_id("_"));
	});

	t.it('output starts with a letter (uci section-name compatible)', () => {
		for (let i = 0; i < 50; i++) {
			let id = ids.new_id();
			t.assert_match(id, /^[a-z_]/);
		}
	});

	// IFNAMSIZ-fit short form: rand_len suppresses the time prefix.
	t.it('rand_len=11 produces a 14-char `wg_<11-char>` id', () => {
		for (let i = 0; i < 50; i++) {
			let id = ids.new_id("wg", 11);
			t.assert_equal(length(id), 14);
			t.assert_match(id, /^wg_[0-9a-hjkmnp-tv-z]{11}$/);
		}
	});

	t.it('rand_len short form is unique across many draws', () => {
		let seen = {};
		for (let i = 0; i < 1000; i++) {
			let id = ids.new_id("wg", 11);
			t.assert_false(exists(seen, id), sprintf("collision on %s", id));
			seen[id] = true;
		}
	});

	t.it('rand_len out of range throws', () => {
		t.assert_throws(() => ids.new_id("wg", 0));
		t.assert_throws(() => ids.new_id("wg", 27));
		t.assert_throws(() => ids.new_id("wg", "11"));
	});
});

t.describe('ids.is_valid_id', () => {
	t.it('accepts generated IDs', () => {
		t.assert_true(ids.is_valid_id(ids.new_id()));
		t.assert_true(ids.is_valid_id(ids.new_id("r")));
	});

	t.it('rejects malformed strings', () => {
		t.assert_false(ids.is_valid_id(""));
		t.assert_false(ids.is_valid_id("abc"));
		t.assert_false(ids.is_valid_id("u_short"));
		t.assert_false(ids.is_valid_id("U_01HX01HX01HX01HX01HX01HX01"));
		t.assert_false(ids.is_valid_id("u_01HX01HX01HX01HX01HX01HX0i"));
	});

	t.it('rejects non-string input', () => {
		t.assert_false(ids.is_valid_id(null));
		t.assert_false(ids.is_valid_id(42));
		t.assert_false(ids.is_valid_id([]));
	});
});
