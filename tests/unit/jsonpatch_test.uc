let t = require('harness');
let jp = require('jsonpatch');

t.describe('jsonpatch.apply, basic ops', () => {
	t.it('add inserts a new object key', () => {
		let r = jp.apply({ a: 1 }, [{ op: "add", path: "/b", value: 2 }]);
		t.assert_true(r.ok);
		t.assert_deep_equal(r.value, { a: 1, b: 2 });
	});

	t.it('add into an array at - appends', () => {
		let r = jp.apply({ arr: [1, 2] }, [{ op: "add", path: "/arr/-", value: 3 }]);
		t.assert_deep_equal(r.value.arr, [1, 2, 3]);
	});

	t.it('replace overwrites an existing key', () => {
		let r = jp.apply({ a: 1 }, [{ op: "replace", path: "/a", value: 9 }]);
		t.assert_deep_equal(r.value, { a: 9 });
	});

	t.it('remove deletes an object key', () => {
		let r = jp.apply({ a: 1, b: 2 }, [{ op: "remove", path: "/a" }]);
		t.assert_deep_equal(r.value, { b: 2 });
	});

	t.it('remove from array removes by index', () => {
		let r = jp.apply({ arr: ["a", "b", "c"] }, [{ op: "remove", path: "/arr/1" }]);
		t.assert_deep_equal(r.value.arr, ["a", "c"]);
	});

	t.it('move relocates a value', () => {
		let r = jp.apply({ a: 1, b: 2 }, [{ op: "move", from: "/a", path: "/c" }]);
		t.assert_deep_equal(r.value, { b: 2, c: 1 });
	});

	t.it('copy duplicates a value', () => {
		let r = jp.apply({ a: 1 }, [{ op: "copy", from: "/a", path: "/b" }]);
		t.assert_deep_equal(r.value, { a: 1, b: 1 });
	});
});

t.describe('jsonpatch.apply, test op', () => {
	t.it('passes when value matches', () => {
		let r = jp.apply({ a: 1 }, [{ op: "test", path: "/a", value: 1 }]);
		t.assert_true(r.ok);
	});

	t.it('returns precondition_failed when value differs', () => {
		let r = jp.apply({ a: 1 }, [{ op: "test", path: "/a", value: 2 }]);
		t.assert_false(r.ok);
		t.assert_equal(r.code, "precondition_failed");
	});

	t.it('returns precondition_failed when path is missing', () => {
		let r = jp.apply({}, [{ op: "test", path: "/missing", value: 1 }]);
		t.assert_equal(r.code, "precondition_failed");
	});
});

t.describe('jsonpatch.apply, validation', () => {
	t.it('rejects non-array body', () => {
		t.assert_equal(jp.apply({}, { op: "add", path: "/a", value: 1 }).code,
		               "validation_failed");
	});

	t.it('rejects unknown op', () => {
		let r = jp.apply({}, [{ op: "smash", path: "/a", value: 1 }]);
		t.assert_equal(r.code, "validation_failed");
	});

	t.it('rejects missing value on add/replace', () => {
		t.assert_equal(jp.apply({}, [{ op: "add", path: "/a" }]).code,
		               "validation_failed");
		t.assert_equal(jp.apply({a:1}, [{ op: "replace", path: "/a" }]).code,
		               "validation_failed");
	});

	t.it('rejects malformed pointer', () => {
		t.assert_equal(jp.apply({}, [{ op: "add", path: "no-leading-slash", value: 1 }]).code,
		               "validation_failed");
	});

	t.it('records which op failed in op_index', () => {
		let r = jp.apply({ a: 1 }, [
			{ op: "replace", path: "/a", value: 2 },
			{ op: "test", path: "/a", value: 99 },
		]);
		t.assert_equal(r.op_index, 1);
	});
});

t.describe('jsonpatch.apply, deep paths', () => {
	t.it('navigates nested objects', () => {
		let r = jp.apply({ outer: { inner: { v: 1 } } },
			[{ op: "replace", path: "/outer/inner/v", value: 42 }]);
		t.assert_equal(r.value.outer.inner.v, 42);
	});

	t.it('does not mutate the original target', () => {
		let target = { a: 1 };
		jp.apply(target, [{ op: "replace", path: "/a", value: 9 }]);
		t.assert_equal(target.a, 1);
	});
});
