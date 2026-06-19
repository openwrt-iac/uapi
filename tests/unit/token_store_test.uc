let t = require('harness');
let bus = require('bus');
let token_store = require('token_store');

function seed_tokens(c) {
	c._state.uci.uapi = {
		admin: {
			'.type': 'token', '.anonymous': false,
			salt: 'sA', hash: 'hA', scopes: ['*:rw'],
		},
		readonly: {
			'.type': 'token', '.anonymous': false,
			salt: 'sB', hash: 'hB', scopes: ['*:ro'],
			expires_at: '2000000000', allowed_cidrs: ['192.168.1.0/24'],
			last_used_at: '1700000123', last_used_ip: '192.168.1.42',
		},
		broken: {
			'.type': 'token', '.anonymous': false,
			scopes: ['*:ro'],
		},
	};
}

function noop_tx() {
	return {
		acquire: function() { return {}; },
		release: function() {},
		check_services: function() { return null; },
	};
}

t.describe('token_store.list_for_auth', () => {
	t.it('returns every token with salt+hash, dropping broken records', () => {
		let c = bus.stub({}); seed_tokens(c);
		let out = token_store.list_for_auth(c);
		t.assert_equal(length(out), 2);
		let by_name = {};
		for (let r in out) by_name[r.name] = r;
		t.assert_equal(by_name.admin.hash, 'hA');
		t.assert_equal(by_name.readonly.expires_at, 2000000000);
		t.assert_deep_equal(by_name.readonly.allowed_cidrs, ['192.168.1.0/24']);
	});
});

t.describe('token_store.list_public', () => {
	t.it('does not expose salt or hash', () => {
		let c = bus.stub({}); seed_tokens(c);
		let out = token_store.list_public(c);
		t.assert_true(length(out) >= 2);
		for (let r in out) {
			t.assert_equal(r.salt, null);
			t.assert_equal(r.hash, null);
		}
	});

	t.it('surfaces expires_at / allowed_cidrs / last_used_* metadata', () => {
		let c = bus.stub({}); seed_tokens(c);
		let out = token_store.list_public(c);
		let ro = null;
		for (let r in out) if (r.name == 'readonly') ro = r;
		t.assert_equal(ro.expires_at, 2000000000);
		t.assert_equal(ro.last_used_ip, '192.168.1.42');
	});
});

t.describe('token_store.get_public', () => {
	t.it('returns one record by name without secrets', () => {
		let c = bus.stub({}); seed_tokens(c);
		let r = token_store.get_public(c, 'admin');
		t.assert_equal(r.name, 'admin');
		t.assert_equal(r.salt, null);
	});

	t.it('returns null for unknown name', () => {
		let c = bus.stub({}); seed_tokens(c);
		t.assert_equal(token_store.get_public(c, 'nope'), null);
	});
});

t.describe('token_store.create validation', () => {
	t.it('rejects body that is not an object', () => {
		let c = bus.stub({});
		let r = token_store.create(c, "not-an-object", ["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
	});

	t.it('rejects bad name shape', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "bad name", scopes: ["*:ro"] },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
		t.assert_true(length(r.errors) > 0);
		t.assert_equal(r.errors[0].field, "name");
	});

	t.it('rejects hyphenated names (uci section-name charset excludes -)', () => {
		// Hyphens slip past the wire as valid JSON strings but libuci's section-
		// name validator rejects them, and ucode-mod-uci's cursor.set silently
		// returns true on the rejection. Without this guard the caller gets a
		// fake bearer that never works.
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "smoke-rc1", scopes: ["*:ro"] },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
		t.assert_equal(r.errors[0].field, "name");
	});

	t.it('rejects missing scopes', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "ok_name", scopes: [] },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
	});

	t.it('rejects bad allowed_cidrs entries', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "ok_name", scopes: ["*:ro"], allowed_cidrs: ["not-a-cidr"] },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
	});

	t.it('rejects expires_in_seconds <= 0', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "ok_name", scopes: ["*:ro"], expires_in_seconds: 0 },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
	});

	t.it('rejects rate <= 0', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "ok_name", scopes: ["*:ro"], rate: 0 },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
	});

	t.it('rejects burst <= 0', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "ok_name", scopes: ["*:ro"], burst: -1 },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
	});

	t.it('rejects non-integer rate', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "ok_name", scopes: ["*:ro"], rate: "abc" },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "validation");
	});

	t.it('blocks scope escalation', () => {
		let c = bus.stub({});
		let r = token_store.create(c,
			{ name: "ok_name", scopes: ["*:rw"] },
			["firewall:ro"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "scope_escalation_blocked");
	});

	t.it('rejects duplicate name with conflict', () => {
		let c = bus.stub({}); seed_tokens(c);
		let r = token_store.create(c,
			{ name: "admin", scopes: ["*:ro"] },
			["*:rw"], 1700000000, noop_tx());
		t.assert_equal(r.kind, "conflict");
	});

	t.it('creates and returns a bearer on the happy path', () => {
		let c = bus.stub({}); seed_tokens(c);
		let r = token_store.create(c,
			{ name: "new_token", scopes: ["firewall:rules:ro"],
			  expires_in_seconds: 3600, allowed_cidrs: ["10.0.0.0/8"] },
			["*:rw"], 1700000000, noop_tx());
		t.assert_true(r.ok);
		t.assert_equal(r.body.name, "new_token");
		t.assert_true(length(r.body.bearer) >= 16);
		// verify uci side-effects
		let stored = c._state.uci.uapi.new_token;
		t.assert_equal(stored['.type'], 'token');
		t.assert_equal(stored.expires_at, "" + (1700000000 + 3600));
		t.assert_deep_equal(stored.allowed_cidrs, ["10.0.0.0/8"]);
	});

	t.it('persists per-token rate and burst overrides', () => {
		let c = bus.stub({}); seed_tokens(c);
		let r = token_store.create(c,
			{ name: "ratelimited", scopes: ["firewall:rules:ro"],
			  rate: 10, burst: 20 },
			["*:rw"], 1700000000, noop_tx());
		t.assert_true(r.ok);
		let stored = c._state.uci.uapi.ratelimited;
		t.assert_equal(stored.rate, "10");
		t.assert_equal(stored.burst, "20");
	});
});

t.describe('token_store.remove', () => {
	t.it('deletes an existing token', () => {
		let c = bus.stub({}); seed_tokens(c);
		let r = token_store.remove(c, "admin", noop_tx());
		t.assert_true(r.ok);
		t.assert_equal(c._state.uci.uapi.admin, null);
	});

	t.it('returns not_found for unknown name', () => {
		let c = bus.stub({}); seed_tokens(c);
		let r = token_store.remove(c, "ghost", noop_tx());
		t.assert_equal(r.kind, "not_found");
	});
});
