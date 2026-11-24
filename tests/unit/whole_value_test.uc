// The ucode of OpenWrt main matches ^ and $ at each line (docs/ucode-quirks.md), and the unit hosts
// run an older ucode. Each check here must refuse a value with a newline on both.
let t = require('harness');
let fs = require('fs');
let bus = require('bus');
let values = require('values');
let errors = require('errors');
let handler = require('handler');
let scope = require('scope');
let ids = require('ids');
let auth = require('auth');
let jsonpatch = require('jsonpatch');
let idempotency = require('idempotency');
let metrics = require('metrics');
let token_store = require('token_store');
let real_tx = require('transaction');

const quiet = { acquire: () => ({}), release: () => null, check_services: () => null, watch: () => null,
                reload: () => null };

function ctx() { return { request_id: "01hx0000000000000000000000", limits: { reload_budget_s: 5 } }; }

function no_popen(ran) {
	return { ...fs, popen: function(cmd) { push(ran, cmd); return null; } };
}

t.describe('values.whole_match', () => {
	t.it('matches a value without a newline as match() does', () => {
		t.assert_deep_equal(values.whole_match("ab12", /^([a-z]+)([0-9]+)$/), [ "ab12", "ab", "12" ]);
		t.assert_equal(values.whole_match("ab-12", /^[a-z0-9]+$/), null);
	});

	t.it('refuses a value with a newline in any position, and a value that is not a string', () => {
		for (let v in [ "abc\nxyz", "abc\n", "\nabc" ])
			t.assert_equal(values.whole_match(v, /^[a-z]+$/), null, v);
		t.assert_equal(values.whole_match(null, /^/), null);
		t.assert_equal(values.whole_match([ "abc" ], /^[a-z]+$/), null);
	});
});

t.describe('values checks of a whole value', () => {
	t.it('refuses a number, an address and a prefix that a newline extends', () => {
		t.assert_equal(values.as_int("5\nx"), null);
		t.assert_false(values.is_valid_ipv4("10.0.0.1\nx"));
		t.assert_false(values.is_valid_ipv6("fe80\n::1"));
		t.assert_false(values.is_valid_cidr("10.0.0.0/8\nx"));
		t.assert_false(values.is_valid_ipv6_cidr("::/0\nx"));
		t.assert_false(values.is_valid_cidr_any("10.0.0.0/8\n10.0.0.0/8"));
	});
});

t.describe('a request id with a newline', () => {
	t.it('is not taken from the header or the query', () => {
		for (let c in [ errors.request_context({ headers: { "x-request-id": "abcdefgh\nijklmnop" } }, {}),
		               errors.request_context({ headers: {} }, { request_id: "abcdefgh\nijklmnop" }) ]) {
			t.assert_equal(index(c.request_id, "\n"), -1);
			t.assert_equal(length(c.request_id), 26);
		}
		t.assert_equal(errors.request_context({ headers: { "x-request-id": "abcdefgh\nx" } },
		                                      { request_id: "fromquery1" }).request_id, "fromquery1");
	});
});

t.describe('packages, a name with a newline', () => {
	let ran = [];
	let pkg = t.load_with({ fs: no_popen(ran) }, [ "packages" ]);

	t.it('is refused', () => {
		t.assert_equal(pkg.get_installed(ctx(), "ucode\nx").status, 404);
		t.assert_equal(pkg.remove_installed(ctx(), "ucode\nx").status, 400);
		let r = pkg.install(ctx(), { name: "ucode\nx" });
		t.assert_deep_equal([ r.status, r.body.errors[0].field, r.body.errors[0].code ], [ 422, "name", "invalid_format" ]);
		t.assert_deep_equal(ran, []);
	});

	t.it('names no feed', () => {
		let r = pkg.create_feed(ctx(), { name: "a\nb", url: "https://feeds.example.invalid/x" });
		t.assert_deep_equal([ r.status, r.body.errors[0].field ], [ 422, "name" ]);
		t.assert_equal(pkg.get_feed(ctx(), "a\nb").status, 404);
		t.assert_equal(pkg.remove_feed(ctx(), "a\nb").status, 400);
		t.assert_deep_equal(ran, []);
	});
});

t.describe('system/password, a user with a newline', () => {
	t.it('is refused as invalid', () => {
		let ran = [];
		let sa = t.load_with({ fs: no_popen(ran) }, [ "system_access" ]);
		let r = sa.set_password(ctx(), { user: "root\nx", password: "long enough" });
		t.assert_deep_equal([ r.status, r.body.errors[0].field, r.body.errors[0].code ], [ 422, "user", "invalid_format" ]);
		t.assert_deep_equal(ran, []);
	});
});

t.describe('/raw, a name with a newline', () => {
	global.modules.transaction = { ...real_tx, transaction: (conn, p) => real_tx.transaction(conn, { ...p, ...quiet }) };
	let raw = loadfile('src/raw.uc')();
	global.modules.transaction = real_tx;
	let fw = () => bus.stub({ uci: { firewall: { r1: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT' } } } });
	let scopes = [ "*:rw" ];

	t.it('refuses an option name, a section id and a type, and writes nothing', () => {
		let c = fw();
		let r = raw.patch(c, ctx(), scopes, "firewall", "r1", { "x\ny": "v" });
		t.assert_equal(r.status, 422);
		r = raw.create(c, ctx(), scopes, "firewall", { ".type": "rule", id: "r2\nx" });
		t.assert_deep_equal([ r.status, r.body.errors[0].field ], [ 422, "id" ]);
		r = raw.create(c, ctx(), scopes, "firewall", { ".type": "rule\nzone" });
		t.assert_deep_equal([ r.status, r.body.errors[0].field ], [ 422, ".type" ]);
		t.assert_deep_equal(c._state.uci_ops, []);
		t.assert_deep_equal(keys(c._state.uci.firewall), [ "r1" ]);
	});
});

t.describe('a curated create, an id with a newline', () => {
	t.it('is refused on a resource that does not declare id', () => {
		let rules = handler.make(loadfile('src/resources/firewall.rules.uc')(), { tx: quiet });
		let c = bus.stub({ uci: { firewall: { z_wan: { '.type': 'zone', name: 'wan' } } } });
		let r = rules.create(c, ctx(), { id: "r1\nx", target: "ACCEPT", match: { src_zone: "wan" } });
		t.assert_deep_equal([ r.status, r.body.errors[0].field, r.body.errors[0].code ], [ 422, "id", "invalid_format" ]);
		t.assert_deep_equal(keys(c._state.uci.firewall), [ "z_wan" ]);
	});
});

t.describe('a schema pattern', () => {
	t.it('refuses a value with a newline as not matching it', () => {
		let errs = handler.check_schema_types({ f: { type: "string", pattern: "^[a-z]+$" } }, { f: "abc\nxyz" });
		t.assert_deep_equal(map(errs, (e) => [ e.field, e.code, e.message ]),
		                    [ [ "f", "invalid_format", "must match ^[a-z]+$" ] ]);
	});
});

t.describe('a list query with a newline', () => {
	let rules = handler.make(loadfile('src/resources/firewall.rules.uc')(), { tx: quiet });
	let c = bus.stub({ uci: { firewall: { r1: { '.type': 'rule', '.anonymous': false, target: 'ACCEPT' } } } });

	t.it('refuses a limit and a cursor', () => {
		t.assert_equal(rules.list(c, ctx(), { limit: "5\nx" }).status, 400);
		let r = rules.list(c, ctx(), { cursor: "c_r1\nx" });
		t.assert_deep_equal([ r.status, r.body.code, r.body.message ], [ 400, "invalid_cursor", "cursor is malformed" ]);
	});
});

t.describe('tokens, a value with a newline', () => {
	let mint = (body) => token_store.create(bus.stub({ uci: { uapi: {} } }), body, [ "*:rw" ], 1700000000,
	                                        { acquire: () => ({}), release: () => null, check_services: () => null });

	t.it('is refused in the name, a scope, an allowed CIDR and a rate', () => {
		let fields = (r) => map(r.errors ?? [], (e) => e.field);
		t.assert_deep_equal(fields(mint({ name: "abc\nxyz", scopes: [ "system:ro" ] })), [ "name" ]);
		t.assert_deep_equal(fields(mint({ name: "ok", scopes: [ "raw:foo\nbar:ro" ] })), [ "scopes[0]" ]);
		t.assert_deep_equal(fields(mint({ name: "ok", scopes: [ "system:ro" ], allowed_cidrs: [ "10.0.0.0/8\nx" ] })),
		                    [ "allowed_cidrs[0]" ]);
		t.assert_deep_equal(fields(mint({ name: "ok", scopes: [ "system:ro" ], rate: "5\nx" })), [ "rate" ]);
		t.assert_throws(() => scope.parse("network\nfoo:ro"));
	});

	t.it('does not authenticate in the Authorization header', () => {
		t.assert_equal(auth.authorize([], "Bearer abc\nxyz", (s, b) => b, {}).kind, "unauthorized");
	});
});

t.describe('other checks of a whole value', () => {
	t.it('refuse an Idempotency-Key, a JSON Patch index and an id with a newline', () => {
		t.assert_false(idempotency.validate_key("key\nx"));
		t.assert_false(jsonpatch.apply({ a: [ 1, 2 ] }, [ { op: "remove", path: "/a/0\nx" } ]).ok);
		t.assert_false(jsonpatch.apply({ a: [ 1, 2 ] }, [ { op: "add", path: "/a/0\nx", value: 3 } ]).ok);
		t.assert_false(ids.is_valid_id("u_0123456789abc\nx"));
		t.assert_false(ids.is_content_id("0123456789ab\nx"));
	});

	t.it('refuse a service and a package name with a newline', () => {
		t.assert_match(real_tx.default_check_services([ "network\nx" ]), /unsafe name/);
		t.assert_match(real_tx.default_reload([ "network\nx" ]), /unsafe name/);
		t.assert_true(real_tx.default_acquire_pkg(null, "network\nx").unavailable != null);
	});

	t.it('load no package whose name holds a newline', () => {
		let loads = [];
		let cursor = { load: function(p) { push(loads, p); return true; }, get_all: () => ({ '.type': 'x' }),
		               get: () => null, foreach: () => true, error: () => null };
		let c = bus.connect({ ubus: { connect: () => ({}), error: () => null },
		                      uci: { cursor: () => cursor }, fs: fs, config_dir: "/nonexistent" });
		t.assert_equal(c.uci_get("network\nx", "lan"), null);
		t.assert_deep_equal(loads, []);
	});

	t.it('record no metric label with a newline', () => {
		metrics.record_validate_error("raw.whole_value\nx", "invalid_format");
		t.assert_equal(index(metrics.format_prometheus(), "whole_value"), -1);
	});
});
