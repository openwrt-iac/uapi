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

	t.it('refuses a name that another section of the token store already holds', () => {
		let c = bus.stub({}); seed_tokens(c);
		c._state.uci.uapi.taken = { '.type': 'other', x: '1' };
		let r = token_store.create(c, { name: "taken", scopes: [ "*:ro" ] }, [ "*:rw" ], 1700000000, noop_tx());
		t.assert_equal(r.kind, "conflict");
		t.assert_deep_equal(c._state.uci.uapi.taken, { '.type': 'other', x: '1' });
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

// The first architectural principle: no write to /etc/config except through uci. A create created
// the file itself when it was missing, which the transaction refuses first.
t.describe('token_store, the config file', () => {
	t.it('a create opens nothing under /etc/config, also where /etc/config/uapi is missing', () => {
		let opened = [];
		let ts = t.load_with_fs({ ...fs,
			stat: (path) => (path == "/etc/config/uapi") ? null : fs.stat(path),
			open: function(path, ...rest) {
				if (substr(path, 0, 12) == "/etc/config/") { push(opened, path); return null; }
				return fs.open(path, ...rest);
			},
		}, [ "token_store" ]);
		let c = bus.stub({}); seed_tokens(c);
		t.assert_true(ts.create(c, { name: "fresh", scopes: [ "*:ro" ] }, [ "*:rw" ], 1700000000, noop_tx()).ok);
		t.assert_deep_equal(opened, []);
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

	t.it('a mint reaps before its commit, so that a kill during the reap cannot lose the bearer of a committed token', () => {
		let c = bus.stub({}); seed_tokens(c);
		plant_state([ "readonly", "gone" ]);
		let commit = c.uci_commit, at_commit = null;
		c.uci_commit = function(pkg) {
			at_commit = { bucket: fs.stat(BUCKETS + "gone.txt"), series: has_series("gone"),
			              marker: fs.stat(MARKERS + "gone") };
			return commit(pkg);
		};
		t.assert_true(token_store.create(c, { name: "run_4", scopes: [ "*:ro" ] },
		                                 [ "*:rw" ], 1700000000, noop_tx()).ok);
		t.assert_deep_equal(at_commit, { bucket: null, series: false, marker: null });
		t.assert_true(fs.stat(BUCKETS + "readonly.txt") != null);
	});

	t.it('a mint whose commit fails has reaped only the state of the tokens that no longer authenticate', () => {
		let c = bus.stub({}); seed_tokens(c);
		plant_state([ "admin", "readonly", "gone" ]);
		c.uci_commit = function() { die("No space left on device"); };
		let err = null;
		try {
			token_store.create(c, { name: "run_5", scopes: [ "*:ro" ] }, [ "*:rw" ], 1700000000, noop_tx());
		} catch (e) { err = e; }
		t.assert_true(err != null);
		t.assert_equal(fs.stat(BUCKETS + "gone.txt"), null);
		for (let n in [ "admin", "readonly" ]) {
			t.assert_true(fs.stat(BUCKETS + n + ".txt") != null, n);
			t.assert_true(has_series(n), n);
			t.assert_true(fs.stat(MARKERS + n) != null, n);
		}
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

// Only uapi-token can create such a token.
t.describe('token_store, a token whose name is longer than 63 characters', () => {
	t.it('stamps its last use, and its marker and bucket, named by the sha256 of its name, stay while it is live', () => {
		let ts = t.load_with({ digest: t.digest }, [ "state_dir", "ratelimit", "metrics", "token_store" ]);
		let rl = t.load_with({ digest: t.digest }, [ "state_dir", "ratelimit" ]);
		let c = bus.stub({}); seed_tokens(c);
		let long = sprintf("ts_unit_%070d", 0), now = time();
		c._state.uci.uapi[long] = { '.type': 'token', salt: 's', hash: 'h', scopes: [ '*:ro' ] };
		let marker = MARKERS + t.digest.sha256(long), bucket = BUCKETS + t.digest.sha256(long) + ".txt";
		fs.unlink(marker);
		ts.update_last_used(c, long, null, now);
		rl.check(long, { now: 1000 });
		t.assert_equal(c._state.uci.uapi[long].last_used_at, "" + now);
		ts.reap_state([ { name: long, expires_at: null } ], now);
		t.assert_true(fs.stat(marker) != null);
		t.assert_true(fs.stat(bucket) != null);
		ts.reap_state([], now);
		t.assert_equal(fs.stat(marker), null);
		t.assert_equal(fs.stat(bucket), null);
	});
});

// uapi-token writes through its own cursor, so this runs it in a child, with a stub of libuci found
// before the real module. Its locks go to /tmp, because the container of the unit job can lack
// /var/lock. No unit host holds /etc/config/uapi, which a create looks for first, so the child runs
// with an fs whose stat finds it. The stub's commit writes what it saw to <dir>/commit.
const ADMIN_ONLY = { admin: { '.type': 'token', salt: 's', hash: 'h', scopes: [ '*:rw' ] } };

function uapi_token(args, sections, commit) {
	let mk = fs.popen("mktemp -d /tmp/uapi-token-cli.XXXXXX");
	let dir = trim(mk.read("all") ?? "");
	mk.close();
	fs.writefile(dir + "/uci.uc", sprintf(`let fs = require('fs');
return { cursor: function() {
	let s = %J;
	return {
		foreach: function(p, t, fn) { for (let n, v in s) if (v['.type'] == t) fn({ ...v, '.name': n }); return true; },
		get_all: (p, n) => (n in s) ? { ...s[n], '.name': n } : null,
		set: function(p, n, o, v) { if (v == null) s[n] = { '.type': o }; else s[n][o] = v; return true; },
		delete: function(p, n) { delete s[n]; return true; },
		commit: function() {
			fs.writefile(%J, sprintf("%%J", { sections: s, gone_bucket: fs.stat(%J) != null }));
			return %s;
		},
		error: () => "No space left on device",
	};
} };`, sections, dir + "/commit", BUCKETS + "gone.txt", commit));
	fs.writefile(dir + "/digest.uc", "return { sha256: (s) => s };");
	fs.writefile(dir + "/transaction.uc", sprintf("let real = loadfile(%J)();\n" +
		"return { ...real, acquire_pkg_waiting: (pkg, ms) => real.acquire_pkg_waiting(pkg, ms, %J, %J) };\n",
		fs.getcwd() + "/src/lib/transaction.uc", dir + "/global.lock", dir + "/pkg."));
	fs.writefile(dir + "/run.uc", "let real = require('fs');\n" +
		"global.modules.fs = { ...real, stat: (p) => (p == '/etc/config/uapi') ? { type: 'file' } : real.stat(p) };\n" +
		"loadfile(shift(ARGV))();\n");
	let p = fs.popen(sprintf("ucode -L %s -L src/lib %s/run.uc cli/uapi-token %s >%s/out 2>%s/err; echo $?",
		dir, dir, join(" ", map(args, (a) => "'" + a + "'")), dir, dir));
	let code = trim(p.read("all") ?? "");
	p.close();
	let seen = fs.readfile(dir + "/commit");
	let r = { code, out: fs.readfile(dir + "/out") ?? "", err: fs.readfile(dir + "/err") ?? "",
	          locked: fs.stat(dir + "/pkg.uapi.lock") != null, at_commit: seen ? json(seen) : null };
	system([ "rm", "-rf", dir ]);
	return r;
}

t.describe('uapi-token revoke, a commit that libuci refuses', () => {
	// It printed that it revoked the token, exited 0, and reaped the state of a token that still
	// authenticates.
	t.it('exits non-zero, says that the token still authenticates, and keeps its state', () => {
		plant_state([ "admin" ]);
		let r = uapi_token([ "revoke", "admin" ], ADMIN_ONLY, "null");
		t.assert_true(r.code != "0", r.err);
		t.assert_match(r.err, /uapi-token revoke: cannot commit \/etc\/config\/uapi: No space left on device, so token "admin" still authenticates/);
		t.assert_true(index(r.err, "Revoked") < 0, r.err);
		t.assert_true(fs.stat(BUCKETS + "admin.txt") != null);
		t.assert_true(has_series("admin"));
	});

	t.it('a commit that works revokes and reaps, so the stub drives the command', () => {
		plant_state([ "admin" ]);
		let r = uapi_token([ "revoke", "admin" ], ADMIN_ONLY, "true");
		t.assert_equal(r.code, "0", r.err);
		t.assert_true(r.locked);
		t.assert_match(r.err, /Revoked token "admin"/);
		t.assert_equal(fs.stat(BUCKETS + "admin.txt"), null);
		t.assert_false(has_series("admin"));
	});
});

t.describe('uapi-token create', () => {
	t.it('reaps before its commit, then prints the bearer', () => {
		plant_state([ "admin", "gone" ]);
		let r = uapi_token([ "create", "--name", "fresh", "--scope", "*:ro" ], ADMIN_ONLY, "true");
		t.assert_equal(r.code, "0", r.err);
		t.assert_true(r.locked);
		t.assert_false(r.at_commit.gone_bucket);
		t.assert_equal(r.at_commit.sections.fresh['.type'], "token");
		t.assert_match(r.out, /^[0-9a-f]{32}\n$/);
		t.assert_true(fs.stat(BUCKETS + "admin.txt") != null);
	});

	t.it('prints no bearer when libuci refuses the commit', () => {
		let r = uapi_token([ "create", "--name", "fresh", "--scope", "*:ro" ], ADMIN_ONLY, "null");
		t.assert_true(r.code != "0", r.err);
		t.assert_equal(r.out, "");
		t.assert_match(r.err, /cannot commit \/etc\/config\/uapi: No space left on device, so token "fresh" does not exist/);
	});

	t.it('refuses a name that another section of the token store already holds', () => {
		let r = uapi_token([ "create", "--name", "taken", "--scope", "*:ro" ],
		                   { ...ADMIN_ONLY, taken: { '.type': 'other', x: '1' } }, "true");
		t.assert_true(r.code != "0", r.err);
		t.assert_match(r.err, /token name "taken" already exists in \/etc\/config\/uapi/);
		t.assert_equal(r.at_commit, null);
	});
});
