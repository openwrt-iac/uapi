let t = require('harness');
let bus = require('bus');
let handler = require('handler');

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

function fixture(over) {
	let res = {
		path: "packages/installed", type: "installed", id_noun: "<name>",
		list_fn:   function(ctx, conn) { return [{ name: "uapi" }]; },
		get_fn:    function(ctx, conn, id) { return { status: 200, body: { name: id } }; },
		create_fn: function(ctx, conn, body) { return { status: 200, body: body }; },
		remove_fn: function(ctx, conn, id) { return { status: 204, body: null }; },
	};
	for (let k in over) res[k] = over[k];
	return handler.make_nonuci(res);
}

t.describe('handler.make_nonuci', () => {
	let c = bus.stub();

	t.it('list returns the resource response', () => {
		let h = fixture({});
		let r = h.list(c, ctx(), {});
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body[0].name, "uapi");
	});

	t.it('get_one/create/remove dispatch to the declared verbs', () => {
		let h = fixture({});
		t.assert_equal(h.get_one(c, ctx(), "uapi").status, 200);
		t.assert_equal(h.create(c, ctx(), { name: "x" }).status, 200);
		t.assert_equal(h.remove(c, ctx(), "uapi").status, 204);
	});

	t.it('undeclared verbs come back null', () => {
		let h = fixture({});
		t.assert_equal(h.replace, null);
	});

	t.it('na reproduces the dispatch 405 message on the collection', () => {
		let h = fixture({});
		let r = h.na(ctx(), "PUT", null);
		t.assert_equal(r.status, 405);
		t.assert_equal(r.body.code, "method_not_allowed");
		t.assert_equal(r.body.message, "Method \"PUT\" not allowed on packages/installed");
	});

	t.it('na reproduces the dispatch 405 message on an item', () => {
		let h = fixture({});
		let r = h.na(ctx(), "POST", "foo");
		t.assert_equal(r.body.message, "Method \"POST\" not allowed on packages/installed/<name>");
	});

	t.it('id_noun <id> renders the item suffix', () => {
		let h = fixture({ path: "system/cron_jobs", id_noun: "<id>" });
		let r = h.na(ctx(), "PUT", "abc");
		t.assert_equal(r.body.message, "Method \"PUT\" not allowed on system/cron_jobs/<id>");
	});
});

t.describe('nonuci resource declarations', () => {
	let nonuci = require('nonuci');

	t.it('declares the five special endpoints', () => {
		t.assert_deep_equal(sort(keys(nonuci)), [
			"packages/feeds", "packages/installed", "system/authorized_keys",
			"system/cron_jobs", "system/password",
		]);
	});

	t.it('every declaration carries its path and an id_noun', () => {
		for (let k in nonuci) {
			t.assert_equal(nonuci[k].path, k);
			t.assert_true(type(nonuci[k].id_noun) == "string");
		}
	});

	t.it('password declares only create', () => {
		let p = nonuci["system/password"];
		t.assert_true(type(p.create_fn) == "function");
		t.assert_equal(p.list_fn, null);
		t.assert_equal(p.get_fn, null);
		t.assert_equal(p.remove_fn, null);
	});
});
