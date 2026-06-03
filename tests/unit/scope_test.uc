let t = require('harness');
let scope = require('scope');

t.describe('scope.parse', () => {
	t.it('parses two-segment scopes', () => {
		let p = scope.parse("firewall:rw");
		t.assert_deep_equal(p, { segments: ["firewall"], verb: "rw" });
	});

	t.it('parses three-segment scopes', () => {
		let p = scope.parse("firewall:rules:ro");
		t.assert_deep_equal(p, { segments: ["firewall", "rules"], verb: "ro" });
	});

	t.it('parses wildcard scopes', () => {
		t.assert_deep_equal(scope.parse("*:rw"), { segments: ["*"], verb: "rw" });
		t.assert_deep_equal(scope.parse("*:ro"), { segments: ["*"], verb: "ro" });
	});

	t.it('rejects missing verb', () => {
		t.assert_throws(() => scope.parse("firewall"));
	});

	t.it('rejects invalid verb', () => {
		t.assert_throws(() => scope.parse("firewall:write"));
		t.assert_throws(() => scope.parse("firewall:read"));
		t.assert_throws(() => scope.parse("firewall:RW"));
	});

	t.it('accepts mid-tree wildcards', () => {
		t.assert_deep_equal(scope.parse("firewall:*:rw"),
			{ segments: ["firewall", "*"], verb: "rw" });
		t.assert_deep_equal(scope.parse("*:rules:ro"),
			{ segments: ["*", "rules"], verb: "ro" });
	});

	t.it('rejects empty segments', () => {
		t.assert_throws(() => scope.parse(":rw"));
		t.assert_throws(() => scope.parse("firewall::rw"));
	});

	t.it('rejects uppercase or invalid chars in segments', () => {
		t.assert_throws(() => scope.parse("Firewall:rw"));
		t.assert_throws(() => scope.parse("fire wall:rw"));
	});

	t.it('rejects non-string input', () => {
		t.assert_throws(() => scope.parse(null));
		t.assert_throws(() => scope.parse(42));
	});
});

t.describe('scope.is_known_path', () => {
	t.it('accepts the documented v1 tree', () => {
		t.assert_true(scope.is_known_path(["*"]));
		t.assert_true(scope.is_known_path(["network"]));
		t.assert_true(scope.is_known_path(["network", "interfaces"]));
		t.assert_true(scope.is_known_path(["firewall", "rules"]));
		t.assert_true(scope.is_known_path(["system"]));
	});

	t.it('accepts raw:<any-package>', () => {
		t.assert_true(scope.is_known_path(["raw"]));
		t.assert_true(scope.is_known_path(["raw", "firewall"]));
		t.assert_true(scope.is_known_path(["raw", "obscure_package"]));
	});

	t.it('rejects unknown paths', () => {
		t.assert_false(scope.is_known_path(["bogus"]));
		t.assert_false(scope.is_known_path(["firewall", "made_up"]));
		t.assert_false(scope.is_known_path(["network", "interfaces", "extra"]));
	});
});

t.describe('scope.validate_against_known_tree', () => {
	t.it('passes for valid scopes', () => {
		scope.validate_against_known_tree("firewall:rules:rw");
		scope.validate_against_known_tree("*:ro");
		scope.validate_against_known_tree("raw:firewall:rw");
	});

	t.it('throws for unknown paths', () => {
		t.assert_throws(() => scope.validate_against_known_tree("bogus:rw"));
		t.assert_throws(() => scope.validate_against_known_tree("firewall:bogus:rw"));
	});
});

t.describe('scope.permits, deny by default', () => {
	t.it('empty token scopes denies everything', () => {
		t.assert_false(scope.permits([], ["firewall", "rules"], "ro"));
		t.assert_false(scope.permits([], ["firewall", "rules"], "rw"));
	});

	t.it('no matching scope denies', () => {
		t.assert_false(scope.permits(["network:rw"], ["firewall", "rules"], "ro"));
	});
});

t.describe('scope.permits, simple matches', () => {
	t.it('domain-level rw permits both verbs on the domain', () => {
		t.assert_true(scope.permits(["firewall:rw"], ["firewall"], "rw"));
		t.assert_true(scope.permits(["firewall:rw"], ["firewall"], "ro"));
		t.assert_true(scope.permits(["firewall:rw"], ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(["firewall:rw"], ["firewall", "rules"], "ro"));
	});

	t.it('domain-level ro permits ro, denies rw', () => {
		t.assert_true(scope.permits(["firewall:ro"], ["firewall", "rules"], "ro"));
		t.assert_false(scope.permits(["firewall:ro"], ["firewall", "rules"], "rw"));
	});

	t.it('subresource-level scope only matches that subresource', () => {
		let s = ["firewall:rules:rw"];
		t.assert_true(scope.permits(s, ["firewall", "rules"], "rw"));
		t.assert_false(scope.permits(s, ["firewall", "zones"], "rw"));
		t.assert_false(scope.permits(s, ["firewall"], "rw"));
	});
});

t.describe('scope.permits, wildcards', () => {
	t.it('*:rw permits everything', () => {
		t.assert_true(scope.permits(["*:rw"], ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(["*:rw"], ["network", "interfaces"], "rw"));
		t.assert_true(scope.permits(["*:rw"], ["system"], "ro"));
		t.assert_true(scope.permits(["*:rw"], ["raw", "firewall"], "rw"));
	});

	t.it('*:ro permits all reads, no writes', () => {
		t.assert_true(scope.permits(["*:ro"], ["firewall", "rules"], "ro"));
		t.assert_false(scope.permits(["*:ro"], ["firewall", "rules"], "rw"));
	});
});

t.describe('scope.permits, mid-tree wildcards', () => {
	t.it('firewall:*:ro permits ro on any firewall subresource', () => {
		t.assert_true(scope.permits(["firewall:*:ro"], ["firewall", "rules"], "ro"));
		t.assert_true(scope.permits(["firewall:*:ro"], ["firewall", "zones"], "ro"));
		t.assert_false(scope.permits(["firewall:*:ro"], ["firewall", "rules"], "rw"));
	});

	t.it('firewall:*:ro does not match the bare domain (path too short)', () => {
		t.assert_false(scope.permits(["firewall:*:ro"], ["firewall"], "ro"));
	});

	t.it('exact subresource wins over mid-tree wildcard at same depth', () => {
		let s = ["firewall:*:ro", "firewall:rules:rw"];
		t.assert_true(scope.permits(s, ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(s, ["firewall", "zones"], "ro"));
		t.assert_false(scope.permits(s, ["firewall", "zones"], "rw"));
	});

	t.it('mid-tree wildcard beats shallower domain scope', () => {
		let s = ["firewall:rw", "firewall:*:ro"];
		t.assert_false(scope.permits(s, ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(s, ["firewall", "rules"], "ro"));
	});
});

t.describe('scope.permits, deepest-match-wins', () => {
	t.it('deep ro overrides shallow rw', () => {
		let s = ["firewall:rw", "firewall:rules:ro"];
		t.assert_false(scope.permits(s, ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(s, ["firewall", "rules"], "ro"));
		t.assert_true(scope.permits(s, ["firewall", "zones"], "rw"));
	});

	t.it('deep rw overrides shallow ro', () => {
		let s = ["firewall:ro", "firewall:rules:rw"];
		t.assert_true(scope.permits(s, ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(s, ["firewall", "zones"], "ro"));
		t.assert_false(scope.permits(s, ["firewall", "zones"], "rw"));
	});

	t.it('domain scope overrides wildcard', () => {
		let s = ["*:rw", "firewall:ro"];
		t.assert_false(scope.permits(s, ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(s, ["network", "interfaces"], "rw"));
	});

	t.it('subresource overrides domain which overrides wildcard', () => {
		let s = ["*:ro", "firewall:rw", "firewall:rules:ro"];
		t.assert_false(scope.permits(s, ["firewall", "rules"], "rw"));
		t.assert_true(scope.permits(s, ["firewall", "rules"], "ro"));
		t.assert_true(scope.permits(s, ["firewall", "zones"], "rw"));
		t.assert_true(scope.permits(s, ["network"], "ro"));
		t.assert_false(scope.permits(s, ["network"], "rw"));
	});
});

t.describe('scope.permits, same-depth conflicts', () => {
	t.it('rw wins when ro and rw both match at the same depth', () => {
		let s = ["firewall:rules:ro", "firewall:rules:rw"];
		t.assert_true(scope.permits(s, ["firewall", "rules"], "rw"));
	});

	t.it('order does not matter for same-depth conflicts', () => {
		let s1 = ["firewall:rules:rw", "firewall:rules:ro"];
		let s2 = ["firewall:rules:ro", "firewall:rules:rw"];
		t.assert_equal(scope.permits(s1, ["firewall", "rules"], "rw"),
		               scope.permits(s2, ["firewall", "rules"], "rw"));
	});
});

t.describe('scope.permits, input validation', () => {
	t.it('rejects unknown verb', () => {
		t.assert_throws(() => scope.permits(["*:rw"], ["x"], "delete"));
	});

	t.it('rejects empty resource path', () => {
		t.assert_throws(() => scope.permits(["*:rw"], [], "ro"));
	});
});

t.describe('scope.subsumes', () => {
	t.it('*:rw subsumes any concrete scope', () => {
		t.assert_true(scope.subsumes(["*:rw"], "firewall:rules:rw"));
		t.assert_true(scope.subsumes(["*:rw"], "firewall:rules:ro"));
		t.assert_true(scope.subsumes(["*:rw"], "*:rw"));
		t.assert_true(scope.subsumes(["*:rw"], "*:ro"));
	});

	t.it('*:ro covers ro but not rw', () => {
		t.assert_true(scope.subsumes(["*:ro"], "firewall:rules:ro"));
		t.assert_false(scope.subsumes(["*:ro"], "firewall:rules:rw"));
		t.assert_true(scope.subsumes(["*:ro"], "*:ro"));
		t.assert_false(scope.subsumes(["*:ro"], "*:rw"));
	});

	t.it('domain-level scope covers descendant subresources', () => {
		t.assert_true(scope.subsumes(["firewall:rw"], "firewall:rules:rw"));
		t.assert_true(scope.subsumes(["firewall:ro"], "firewall:rules:ro"));
		t.assert_false(scope.subsumes(["firewall:ro"], "firewall:rules:rw"));
	});

	t.it('descendant scope does not cover its ancestor', () => {
		t.assert_false(scope.subsumes(["firewall:rules:rw"], "firewall:rw"));
	});

	t.it('unrelated scopes do not subsume', () => {
		t.assert_false(scope.subsumes(["firewall:rw"], "network:rw"));
	});
});

t.describe('scope.subsets', () => {
	t.it('returns true when every requested scope is covered', () => {
		t.assert_true(scope.subsets(["*:rw"], ["firewall:rules:rw", "network:ro"]));
	});

	t.it('returns false when one requested scope is not covered', () => {
		t.assert_false(scope.subsets(["firewall:rw"], ["firewall:rules:rw", "network:ro"]));
	});

	t.it('returns false for non-array input', () => {
		t.assert_false(scope.subsets(["*:rw"], null));
		t.assert_false(scope.subsets(["*:rw"], "firewall:ro"));
	});

	t.it('returns true for empty requested set (vacuously)', () => {
		t.assert_true(scope.subsets(["firewall:rw"], []));
	});
});

t.describe('scope.require_or_deny', () => {
	// Pass a thin errors stand-in so we don't need to require the real module
	// (which pulls in ids/fs); the helper only calls errors_mod.error(...).
	let stub_errors = { error: (ctx, code, msg) => ({ ctx, code, msg }) };

	t.it('returns null when scope permits', () => {
		let r = scope.require_or_deny(stub_errors, {req: 1}, ["*:rw"], ["firewall", "rules"], "rw", "test");
		t.assert_equal(r, null);
	});

	t.it('returns insufficient_scope envelope when denied', () => {
		let r = scope.require_or_deny(stub_errors, {req: 1}, ["network:ro"], ["firewall", "rules"], "rw", "writing firewall/rules");
		t.assert_equal(r.code, "insufficient_scope");
		t.assert_true(index(r.msg, "writing firewall/rules") >= 0);
	});

	t.it('falls back to verb-on-segments message when no description given', () => {
		let r = scope.require_or_deny(stub_errors, {req: 1}, [], ["firewall", "rules"], "rw");
		t.assert_true(index(r.msg, "rw on firewall:rules") >= 0);
	});
});
