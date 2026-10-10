let t = require('harness');

let pkg = loadfile('src/lib/packages.uc')();

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

t.describe('packages module', () => {
	t.it('exports the expected handler set', () => {
		t.assert_equal(type(pkg.list_installed), "function");
		t.assert_equal(type(pkg.get_installed), "function");
		t.assert_equal(type(pkg.install), "function");
		t.assert_equal(type(pkg.remove_installed), "function");
		t.assert_equal(type(pkg.list_feeds), "function");
		t.assert_equal(type(pkg.get_feed), "function");
		t.assert_equal(type(pkg.create_feed), "function");
		t.assert_equal(type(pkg.remove_feed), "function");
	});
});

t.describe('packages.install validation', () => {
	t.it('rejects a non-object body with bad_request', () => {
		let r = pkg.install(ctx(), null);
		t.assert_equal(r.status, 400);
		t.assert_equal(r.body.code, "bad_request");
	});

	t.it('reports name as required when missing', () => {
		let r = pkg.install(ctx(), {});
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.code, "validation_failed");
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "required");
	});

	t.it('rejects shell-metacharacter names with invalid_format', () => {
		let r = pkg.install(ctx(), { name: "evil; rm -rf /" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects path-traversal names with invalid_format', () => {
		let r = pkg.install(ctx(), { name: "../../etc/passwd" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects names starting with - (would be parsed as apk flag)', () => {
		let r = pkg.install(ctx(), { name: "--allow-untrusted" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects names starting with . (path traversal)', () => {
		let r = pkg.install(ctx(), { name: ".bashrc" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});
});

t.describe('packages.remove_installed validation', () => {
	t.it('rejects unsafe names with bad_request', () => {
		let r = pkg.remove_installed(ctx(), "foo bar");
		t.assert_equal(r.status, 400);
		t.assert_equal(r.body.code, "bad_request");
	});
});

t.describe('packages.get_installed validation', () => {
	t.it('rejects unsafe names with not_found (without shelling out)', () => {
		let r = pkg.get_installed(ctx(), "foo;bar");
		t.assert_equal(r.status, 404);
		t.assert_equal(r.body.code, "not_found");
	});
});

t.describe('packages.create_feed validation', () => {
	t.it('rejects missing name and url together', () => {
		let r = pkg.create_feed(ctx(), {});
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.code, "validation_failed");
		let codes = {};
		for (let e in r.body.errors) codes[e.field] = e.code;
		t.assert_equal(codes.name, "required");
		t.assert_equal(codes.url, "required");
	});

	t.it('rejects non-http url with invalid_format', () => {
		let r = pkg.create_feed(ctx(), { name: "my-feed", url: "file:///etc/passwd" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "url");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	// A start-anchored pattern let a newline append a second repository line, which apk
	// trusts on the next install and which no read path showed, since both parse one line.
	// Confirmed on a box running 3.0.0-rc1: the file held 2 lines while GET reported 1.
	t.it('rejects a url carrying an embedded newline', () => {
		let r = pkg.create_feed(ctx(), { name: "inj",
		                                 url: "http://legit.invalid/f\nhttp://evil.invalid/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "url");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects other control characters and trailing whitespace in a url', () => {
		for (let bad in [ "http://a.invalid/x\ty", "http://a.invalid/x\r", "http://a.invalid/x z" ]) {
			let r = pkg.create_feed(ctx(), { name: "inj", url: bad });
			t.assert_equal(r.status, 422);
			t.assert_equal(r.body.errors[0].field, "url");
		}
	});

	t.it('rejects unsafe feed name with invalid_format', () => {
		let r = pkg.create_feed(ctx(), { name: "../etc/foo", url: "https://example.com/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
	});

	t.it('rejects feed name starting with . (directory escape)', () => {
		let r = pkg.create_feed(ctx(), { name: ".hidden", url: "https://example.com/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects feed name starting with - (would be parsed as apk flag)', () => {
		let r = pkg.create_feed(ctx(), { name: "-rf", url: "https://example.com/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});
});

t.describe('packages.remove_feed validation', () => {
	t.it('rejects unsafe id with bad_request', () => {
		let r = pkg.remove_feed(ctx(), "foo/bar");
		t.assert_equal(r.status, 400);
	});
});

t.describe('packages.add_with_refresh', () => {
	function fake(results) {
		let calls = [];
		return { calls: calls, exec: function(args) {
			push(calls, args);
			return { ok: shift(results), exit_code: 1, output: sprintf("%d:%s", length(calls), args) };
		} };
	}

	t.it('does not refresh when the first attempt works', () => {
		let f = fake([true]);
		t.assert_true(pkg.add_with_refresh("ethtool", f.exec).ok);
		t.assert_deep_equal(f.calls, ["add -- ethtool"]);
	});

	t.it('refreshes and tries once more when the cached index is stale', () => {
		let f = fake([false, true, true]);
		t.assert_true(pkg.add_with_refresh("ethtool", f.exec).ok);
		t.assert_deep_equal(f.calls, ["add -- ethtool", "update", "add -- ethtool"]);
	});

	t.it('reports the second failure when the refresh did not help', () => {
		let f = fake([false, true, false]);
		let r = pkg.add_with_refresh("ethtool", f.exec);
		t.assert_false(r.ok);
		t.assert_equal(r.output, "3:add -- ethtool");
	});

	t.it('keeps the first error and does not retry when the refresh fails', () => {
		let f = fake([false, false]);
		let r = pkg.add_with_refresh("ethtool", f.exec);
		t.assert_false(r.ok);
		t.assert_equal(r.output, "1:add -- ethtool");
		t.assert_deep_equal(f.calls, ["add -- ethtool", "update"]);
	});
});

t.describe('packages.version_of', () => {
	const QUERY = '[ { "name": "luci-app-uapi", "version": "1.1.1-r1" }, { "name": "uapi", "version": "3.0.0-r1" } ]';

	t.it('reads the full version, where splitting the apk info line kept only r1', () => {
		t.assert_equal(pkg.version_of("uapi", QUERY), "3.0.0-r1");
		t.assert_equal(pkg.version_of("luci-app-uapi", QUERY), "1.1.1-r1");
	});

	t.it('keeps a version with a tilde whole', () => {
		t.assert_equal(pkg.version_of("kernel",
			'[ { "name": "kernel", "version": "6.12.94~a7bc15f4-r1" } ]'), "6.12.94~a7bc15f4-r1");
	});

	t.it('answers null for a name the query did not return', () => {
		t.assert_equal(pkg.version_of("ethtool", QUERY), null);
		t.assert_equal(pkg.version_of("uapi", "[ ]"), null);
	});

	t.it('answers null when a warning on stderr broke the JSON', () => {
		t.assert_equal(pkg.version_of("uapi", "WARNING: opening from cache x: No such file or directory\n" + QUERY), null);
	});
});
