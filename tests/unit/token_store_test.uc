let t = require('harness');
let fs = require('fs');
let bus = require('bus');
let ratelimit = require('ratelimit');
let metrics = require('metrics');
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
		let r = token_store.remove(c, "admin", 1700000000, noop_tx());
		t.assert_true(r.ok);
		t.assert_equal(c._state.uci.uapi.admin, null);
	});

	t.it('returns not_found for unknown name', () => {
		let c = bus.stub({}); seed_tokens(c);
		let r = token_store.remove(c, "ghost", 1700000000, noop_tx());
		t.assert_equal(r.kind, "not_found");
	});

	// uci resolves `@token[0]` too. The stub does not, so this conn maps the position.
	t.it('deletes by position under the token name, which the rate-limit bucket is keyed by', () => {
		let c = bus.stub({}); seed_tokens(c);
		let get = c.uci_get;
		c.uci_get = (p, s, o) => get(p, s == "@token[0]" ? "admin" : s, o);
		t.assert_equal(token_store.get_public(c, "@token[0]").name, "admin");
		let r = token_store.remove(c, "@token[0]", 1700000000, noop_tx());
		t.assert_deep_equal(r.body, { deleted: "admin" });
		t.assert_equal(c._state.uci.uapi.admin, null);
	});
});

const BUCKETS = "/var/run/uapi-ratelimit/";
const MARKERS = "/var/run/uapi-token-update/";

function plant_state(names) {
	fs.mkdir(MARKERS, 0o700);
	for (let n in names) {
		ratelimit.check(n, { now: 1000 });
		metrics.record_request("GET", "/system", 200, 1, n);
		fs.writefile(MARKERS + n, "");
	}
}

function has_series(id) {
	return index(metrics.format_prometheus(), sprintf('token_id="%s"', id)) >= 0;
}

// /var/run/uapi-metrics is shared with the other suites, which leave -retired series behind, so
// this reads only the series that plant_state() writes.
function requests_of(id) {
	let s = sprintf('uapi_requests_total{method="GET",path="/system",status="200",token_id="%s"} ', id);
	for (let l in split(metrics.format_prometheus(), "\n"))
		if (substr(l, 0, length(s)) == s) return int(substr(l, length(s)));
	return 0;
}

t.describe('token_store, the tmpfs state of a token', () => {
	t.it('a revoke reaps the bucket, the series and the marker of the token after its commit', () => {
		let c = bus.stub({}); seed_tokens(c);
		plant_state([ "admin", "readonly" ]);
		let want = requests_of("-retired") + requests_of("admin");
		t.assert_true(token_store.remove(c, "admin", 1700000000, noop_tx()).ok);
		t.assert_equal(fs.stat(BUCKETS + "admin.txt"), null);
		t.assert_true(fs.stat(BUCKETS + "readonly.txt") != null);
		t.assert_false(has_series("admin"));
		t.assert_true(has_series("readonly"));
		t.assert_equal(requests_of("-retired"), want);
		t.assert_equal(fs.stat(MARKERS + "admin"), null);
		t.assert_true(fs.stat(MARKERS + "readonly") != null);
	});

	t.it('a revoke whose commit fails keeps the state of the token', () => {
		let c = bus.stub({}); seed_tokens(c);
		plant_state([ "admin" ]);
		c.uci_commit = function() { die("No space left on device"); };
		let err = null;
		try { token_store.remove(c, "admin", 1700000000, noop_tx()); } catch (e) { err = e; }
		t.assert_true(err != null);
		t.assert_true(fs.stat(BUCKETS + "admin.txt") != null);
		t.assert_true(has_series("admin"));
	});

	t.it('a mint reaps the state of a token that expired or is gone, and keeps a live one', () => {
		let c = bus.stub({}); seed_tokens(c);
		c._state.uci.uapi.old = { '.type': 'token', salt: 's', hash: 'h', scopes: [ '*:ro' ],
		                          expires_at: '1700000000' };
		plant_state([ "readonly", "old", "gone" ]);
		t.assert_true(token_store.create(c, { name: "run_3", scopes: [ "*:ro" ] },
		                                 [ "*:rw" ], 1700000000, noop_tx()).ok);
		t.assert_true(fs.stat(BUCKETS + "readonly.txt") != null);
		t.assert_equal(fs.stat(BUCKETS + "old.txt"), null);
		t.assert_equal(fs.stat(BUCKETS + "gone.txt"), null);
		t.assert_true(has_series("readonly"));
		t.assert_false(has_series("old"));
		t.assert_false(has_series("gone"));
		t.assert_true(fs.stat(MARKERS + "readonly") != null);
		t.assert_equal(fs.stat(MARKERS + "old"), null);
		t.assert_equal(fs.stat(MARKERS + "gone"), null);
	});

	t.it('reap_state keeps a token whose expiry is ahead, and one with no expiry', () => {
		plant_state([ "later", "never", "past" ]);
		token_store.reap_state([ { name: "later", expires_at: 1700000001 },
		                         { name: "never", expires_at: null },
		                         { name: "past", expires_at: 1699999999 } ], 1700000000);
		t.assert_true(fs.stat(BUCKETS + "later.txt") != null);
		t.assert_true(fs.stat(BUCKETS + "never.txt") != null);
		t.assert_equal(fs.stat(BUCKETS + "past.txt"), null);
		token_store.reap_state([], 1700000000);
	});
});

t.describe('token_store.update_last_used, the last-used marker', () => {
	let mode = (p) => fs.stat(p).mode & 0o777;

	t.it('writes the marker 0600 in a directory 0700, also over a marker with mode 0644', () => {
		let c = bus.stub({}); seed_tokens(c);
		let now = time();
		fs.unlink(MARKERS + "admin");
		token_store.update_last_used(c, "admin", null, now);
		t.assert_equal(mode(MARKERS), 0o700);
		t.assert_equal(mode(MARKERS + "admin"), 0o600);
		fs.chmod(MARKERS + "admin", 0o644);
		token_store.update_last_used(c, "admin", null, now + 120);
		t.assert_equal(mode(MARKERS + "admin"), 0o600);
		fs.unlink(MARKERS + "admin");
	});

	t.it('does not use a directory that is not uapi\'s own', () => {
		let c = bus.stub({}); seed_tokens(c);
		plant_state([ "gone" ]);
		fs.unlink(MARKERS + "admin");
		fs.chmod(MARKERS, 0o777);
		token_store.update_last_used(c, "admin", null, time());
		token_store.reap_state([], time());
		let written = fs.stat(MARKERS + "admin") != null, kept = fs.stat(MARKERS + "gone") != null;
		fs.chmod(MARKERS, 0o700);
		token_store.reap_state([], time());
		t.assert_false(written);
		t.assert_true(kept);
	});
});
