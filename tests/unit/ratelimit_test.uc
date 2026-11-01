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
	try { fs.unlink("/var/run/uapi-ratelimit/" + token + ".txt"); } catch (_) {}
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
	t.it('allows when there is no token id', () => {
		t.assert_true(ratelimit.check(null, { now: 1000 }).allowed);
	});

	t.it('keeps the bucket of a token id that is not a file name in the directory', () => {
		let rl = t.load_with({ digest: t.digest }, [ "state_dir", "ratelimit" ]);
		let id = "../rl_unit_escape";
		rl.check(id, { now: 1000 });
		t.assert_equal(fs.stat("/var/run/rl_unit_escape.txt"), null);
		t.assert_true(fs.stat("/var/run/uapi-ratelimit/" + t.digest.sha256(id) + ".txt") != null);
		clean(t.digest.sha256(id));
	});

	t.it('allows when now is null (clockless router)', () => {
		t.assert_true(ratelimit.check("any_tok", {}).allowed);
	});
});

t.describe('ratelimit, a directory that is not uapi\'s own', () => {
	t.it('is not used: no bucket is read, written or reaped', () => {
		let tok = fresh_token();
		t.assert_true(ratelimit.check(tok, { now: 1000, rate: 1, burst: 1 }).allowed);
		let bucket = "/var/run/uapi-ratelimit/" + tok + ".txt";
		let held = fs.readfile(bucket);
		fs.chmod("/var/run/uapi-ratelimit", 0o777);
		t.assert_true(ratelimit.check(tok, { now: 1000, rate: 1, burst: 1 }).allowed);
		ratelimit.reap({});
		t.assert_equal(fs.readfile(bucket), held);
		fs.chmod("/var/run/uapi-ratelimit", 0o700);
		t.assert_false(ratelimit.check(tok, { now: 1000, rate: 1, burst: 1 }).allowed);
		clean(tok);
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

t.describe('ratelimit, a token whose name is longer than 63 characters', () => {
	t.it('is limited, in a bucket named by the sha256 of its name, which the reap keeps while it is live', () => {
		let rl = t.load_with({ digest: t.digest }, [ "state_dir", "ratelimit" ]);
		let live = sprintf("rl_unit_live_%070d", 0), dead = sprintf("rl_unit_dead_%070d", 0);
		t.assert_true(rl.check(live, { now: 1000, rate: 1, burst: 1 }).allowed);
		t.assert_false(rl.check(live, { now: 1000, rate: 1, burst: 1 }).allowed);
		rl.check(dead, { now: 1000 });
		rl.reap({ [live]: true });
		t.assert_true(fs.stat("/var/run/uapi-ratelimit/" + t.digest.sha256(live) + ".txt") != null);
		t.assert_equal(fs.stat("/var/run/uapi-ratelimit/" + t.digest.sha256(dead) + ".txt"), null);
		clean(t.digest.sha256(live));
	});
});

t.describe('ratelimit.reap', () => {
	t.it('removes the bucket and the temp file of a token that is not live, and keeps the others', () => {
		let live = fresh_token(), dead = fresh_token();
		ratelimit.check(live, { now: 1000 });
		ratelimit.check(dead, { now: 1000 });
		let f = fs.open("/var/run/uapi-ratelimit/" + dead + ".txt.tmp", "w");
		f.close();
		ratelimit.reap({ [live]: true });
		t.assert_true(fs.stat("/var/run/uapi-ratelimit/" + live + ".txt") != null);
		t.assert_equal(fs.stat("/var/run/uapi-ratelimit/" + dead + ".txt"), null);
		t.assert_equal(fs.stat("/var/run/uapi-ratelimit/" + dead + ".txt.tmp"), null);
		clean(live);
	});
});
