let t = require('harness');

t.describe('harness self-test', () => {
	t.it('assert_equal passes on equal', () => {
		t.assert_equal(1, 1);
		t.assert_equal("a", "a");
		t.assert_equal(null, null);
	});

	t.it('assert_deep_equal on nested structures', () => {
		t.assert_deep_equal({a: [1, 2, {b: 3}]}, {a: [1, 2, {b: 3}]});
	});

	t.it('assert_throws catches a throw', () => {
		t.assert_throws(() => die("nope"));
	});

	t.it('assert_match on regex', () => {
		t.assert_match("hello world", /world/);
	});

	t.it('assert_true and assert_false', () => {
		t.assert_true(1);
		t.assert_true("x");
		t.assert_false(0);
		t.assert_false("");
		t.assert_false(null);
	});
});
