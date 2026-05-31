let t = require('harness');

let sa = loadfile('src/lib/system_access.uc')();

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

t.describe('system_access module', () => {
	t.it('exports the expected surface', () => {
		t.assert_equal(type(sa.set_password), "function");
		t.assert_equal(type(sa.list_keys), "function");
		t.assert_equal(type(sa.get_key), "function");
		t.assert_equal(type(sa.add_key), "function");
		t.assert_equal(type(sa.replace_keys), "function");
		t.assert_equal(type(sa.remove_key), "function");
		t.assert_equal(type(sa.parse_public_key), "function");
	});
});

t.describe('system_access.parse_public_key', () => {
	t.it('parses an ssh-ed25519 key with comment', () => {
		let r = sa.parse_public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9k user@host");
		t.assert_equal(r.type, "ssh-ed25519");
		t.assert_equal(r.blob, "AAAAC3NzaC1lZDI1NTE5AAAAIE9k");
		t.assert_equal(r.comment, "user@host");
		t.assert_equal(length(r.id), 12);
	});

	t.it('parses an ecdsa key without comment', () => {
		let r = sa.parse_public_key("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHA=");
		t.assert_equal(r.type, "ecdsa-sha2-nistp256");
		t.assert_equal(r.comment, "");
	});

	t.it('skips options and finds the key-type token', () => {
		let r = sa.parse_public_key('command="echo hi",no-pty ssh-rsa AAAAB3NzaC1yc2E= test');
		t.assert_equal(r.type, "ssh-rsa");
		t.assert_equal(r.blob, "AAAAB3NzaC1yc2E=");
		t.assert_equal(r.comment, "test");
	});

	t.it('returns null for unrecognized type', () => {
		t.assert_equal(sa.parse_public_key("ssh-dss AAAA..."), null);
	});

	t.it('returns null for missing blob', () => {
		t.assert_equal(sa.parse_public_key("ssh-ed25519"), null);
	});

	t.it('returns null for blob with shell metas', () => {
		t.assert_equal(sa.parse_public_key("ssh-ed25519 AAAA;rm-rf"), null);
	});

	t.it('returns null for comment-only / blank / empty lines', () => {
		t.assert_equal(sa.parse_public_key(""), null);
		t.assert_equal(sa.parse_public_key("# comment"), null);
		t.assert_equal(sa.parse_public_key(null), null);
	});

	t.it('canonical form drops options but keeps comment', () => {
		let r = sa.parse_public_key('no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 alice');
		t.assert_equal(r.canonical, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 alice");
	});

	t.it('id is stable for the same canonical content', () => {
		let a = sa.parse_public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9k user@host");
		let b = sa.parse_public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9k user@host");
		t.assert_equal(a.id, b.id);
	});
});

t.describe('system_access.set_password validation', () => {
	t.it('rejects non-object body', () => {
		let r = sa.set_password(ctx(), null);
		t.assert_equal(r.status, 400);
	});

	t.it('reports missing user and password together', () => {
		let r = sa.set_password(ctx(), {});
		t.assert_equal(r.status, 422);
		let codes = {};
		for (let e in r.body.errors) codes[e.field] = e.code;
		t.assert_equal(codes.user, "required");
		t.assert_equal(codes.password, "required");
	});

	t.it('rejects user with shell metacharacters', () => {
		let r = sa.set_password(ctx(), { user: "root;rm", password: "longenough" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "user");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects uppercase / odd-shaped user', () => {
		let r = sa.set_password(ctx(), { user: "Root", password: "longenough" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "user");
	});

	t.it('rejects passwords shorter than 8 chars', () => {
		let r = sa.set_password(ctx(), { user: "root", password: "short" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "password");
		t.assert_equal(r.body.errors[0].code, "out_of_range");
	});
});

t.describe('system_access.add_key validation', () => {
	t.it('rejects non-object body with bad_request', () => {
		t.assert_equal(sa.add_key(ctx(), null).status, 400);
	});

	t.it('rejects body without key string', () => {
		t.assert_equal(sa.add_key(ctx(), {}).status, 400);
	});

	t.it('rejects malformed key with validation_failed', () => {
		let r = sa.add_key(ctx(), { key: "not a key" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "key");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});
});

t.describe('system_access.remove_key validation', () => {
	t.it('rejects invalid id with 404', () => {
		t.assert_equal(sa.remove_key(ctx(), "not-an-id").status, 404);
	});
});

t.describe('system_access.get_key validation', () => {
	t.it('rejects invalid id with 404', () => {
		t.assert_equal(sa.get_key(ctx(), "AAAA").status, 404);
	});
});
