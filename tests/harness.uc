let stack = [];
let passed = 0;
let failed = 0;
let failures = [];

function describe(name, fn) {
	push(stack, name);
	fn();
	pop(stack);
}

function context_label(name) {
	let parts = [];
	for (let s in stack) push(parts, s);
	push(parts, name);
	return join(" > ", parts);
}

function it(name, fn) {
	let label = context_label(name);
	try {
		fn();
		passed++;
		printf("  pass: %s\n", label);
	} catch (e) {
		failed++;
		let msg = type(e) == "object" ? (e.message ?? sprintf("%J", e)) : "" + e;
		push(failures, sprintf("%s: %s", label, msg));
		printf("  FAIL: %s\n        %s\n", label, msg);
	}
}

function deep_equal(a, b) {
	if (type(a) != type(b)) return false;
	if (type(a) == "array") {
		if (length(a) != length(b)) return false;
		for (let i = 0; i < length(a); i++)
			if (!deep_equal(a[i], b[i])) return false;
		return true;
	}
	if (type(a) == "object") {
		let ka = keys(a), kb = keys(b);
		if (length(ka) != length(kb)) return false;
		for (let k in ka)
			if (!deep_equal(a[k], b[k])) return false;
		return true;
	}
	return a === b;
}

function assert_equal(actual, expected, msg) {
	if (actual !== expected)
		die(sprintf("%s: expected %J, got %J",
		            msg ?? "assert_equal", expected, actual));
}

function assert_deep_equal(actual, expected, msg) {
	if (!deep_equal(actual, expected))
		die(sprintf("%s: expected %J, got %J",
		            msg ?? "assert_deep_equal", expected, actual));
}

function assert_true(actual, msg) {
	if (!actual)
		die(sprintf("%s: expected truthy, got %J",
		            msg ?? "assert_true", actual));
}

function assert_false(actual, msg) {
	if (actual)
		die(sprintf("%s: expected falsy, got %J",
		            msg ?? "assert_false", actual));
}

function assert_throws(fn, msg) {
	let threw = false;
	try { fn(); } catch (e) { threw = true; }
	if (!threw)
		die(msg ?? "assert_throws: expected throw, none happened");
}

function assert_match(str, pattern, msg) {
	if (!match(str, pattern))
		die(sprintf("%s: %J does not match %J",
		            msg ?? "assert_match", str, pattern));
}

function summary() {
	printf("\n%d passed, %d failed\n", passed, failed);
	if (failed > 0) {
		print("\nFailures:\n");
		for (let f in failures) printf("  - %s\n", f);
		exit(1);
	}
}

return {
	describe,
	it,
	assert_equal,
	assert_deep_equal,
	assert_true,
	assert_false,
	assert_throws,
	assert_match,
	summary,
};
