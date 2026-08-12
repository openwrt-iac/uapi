let t = require('harness');
let fs = require('fs');
let ratelimit = require('ratelimit');

// Each test uses a unique token id so they don't share state via the on-disk
// bucket. /var/run is tmpfs on the build env too; clean what we touch.
let _counter = 0;
function fresh_token() {
	_counter++;
	return sprintf("rl_unit_%d", _counter);
}

function clean(token) {
	try { fs.unlink("/tmp/uapi-ratelimit/" + token + ".txt"); } catch (_) {}
}

t.describe('ratelimit.check, fresh bucket', () => {
	t.it('first request is always allowed (bucket starts full)', () => {
		let tok = fresh_token();
		clean(tok);
		let r = ratelimit.check(tok, { now: 1000, rate: 10, burst: 5 });
		t.assert_true(r.allowed);
		t.assert_equal(r.retry_after_seconds, 0);
	});
});

t.describe('ratelimit.check, exhausting the bucket', () => {
	t.it('returns not allowed once bucket is empty and refill window not elapsed', () => {
		let tok = fresh_token();
		clean(tok);
		t.assert_true(ratelimit.check(tok, { now: 1000, rate: 1, burst: 2 }).allowed);
		t.assert_true(ratelimit.check(tok, { now: 1000, rate: 1, burst: 2 }).allowed);
		let r = ratelimit.check(tok, { now: 1000, rate: 1, burst: 2 });
		t.assert_false(r.allowed);
		t.assert_true(r.retry_after_seconds >= 1);
	});

	t.it('refills after enough time and allows again', () => {
		let tok = fresh_token();
		clean(tok);
		t.assert_true(ratelimit.check(tok, { now: 1000, rate: 1, burst: 1 }).allowed);
		t.assert_false(ratelimit.check(tok, { now: 1000, rate: 1, burst: 1 }).allowed);
		t.assert_true(ratelimit.check(tok, { now: 1002, rate: 1, burst: 1 }).allowed);
	});
});

t.describe('ratelimit.check, malformed inputs', () => {
	t.it('allows when token id has unsafe shape (best-effort silently allow)', () => {
		t.assert_true(ratelimit.check("bad name", { now: 1000 }).allowed);
		t.assert_true(ratelimit.check(null, { now: 1000 }).allowed);
	});

	t.it('allows when now is null (clockless router)', () => {
		t.assert_true(ratelimit.check("any_tok", {}).allowed);
	});
});

t.describe('ratelimit.load_config', () => {
	t.it('returns defaults when no config section exists', () => {
		let stub_conn = {
			uci_foreach: function(_pkg, _type, _fn) {},
		};
		let cfg = ratelimit.load_config(stub_conn);
		t.assert_equal(cfg.rate, 100);
		t.assert_equal(cfg.burst, 200);
	});

	t.it('reads rate and burst from /etc/config/uapi when present', () => {
		let stub_conn = {
			uci_foreach: function(_pkg, _type, fn) {
				fn({ '.type': 'ratelimit', rate: "50", burst: "75" });
			},
		};
		let cfg = ratelimit.load_config(stub_conn);
		t.assert_equal(cfg.rate, 50);
		t.assert_equal(cfg.burst, 75);
	});
});

t.describe('ratelimit.effective_limits', () => {
	t.it('per-token override beats global', () => {
		let eff = ratelimit.effective_limits({ rate: 100, burst: 200 },
		                                     { rate: "10", burst: "20" });
		t.assert_equal(eff.rate, 10);
		t.assert_equal(eff.burst, 20);
	});

	t.it('falls back to global when token has no override', () => {
		let eff = ratelimit.effective_limits({ rate: 100, burst: 200 }, {});
		t.assert_equal(eff.rate, 100);
		t.assert_equal(eff.burst, 200);
	});
});

// The bucket file outlived its token: nothing swept /tmp/uapi-ratelimit, so one accumulated per
// token that ever authenticated and stayed until reboot. Measured 106 files against 4 live
// tokens, and the provider's ephemeral uapi_token mints one per Terraform run, so on a router
// with long uptime that is unbounded tmpfs, which is RAM.
t.describe('ratelimit.forget', () => {
	// Asserting only that a traversal name returns false proves nothing: unlink on a path that
	// does not exist returns false whether or not the name was checked. This plants a file the
	// traversal would actually delete and asserts it survives, which fails if the guard goes.
	t.it('refuses a name that could escape the directory', () => {
		let victim = "/tmp/uapi-rl-traversal-victim.txt";
		let f = fs.open(victim, "w");
		f.write("keep");
		f.close();
		t.assert_false(ratelimit.forget("../uapi-rl-traversal-victim"));
		t.assert_true(fs.stat(victim) != null);
		fs.unlink(victim);
		t.assert_false(ratelimit.forget("a/b"));
		t.assert_false(ratelimit.forget(null));
	});

	t.it('reports false for a token that has no bucket', () => {
		t.assert_false(ratelimit.forget("nonexistent_token_xyz"));
	});
});
