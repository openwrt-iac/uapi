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
		// burst=2 means the first two requests pass, third fails
		t.assert_true(ratelimit.check(tok, { now: 1000, rate: 1, burst: 2 }).allowed);
		t.assert_true(ratelimit.check(tok, { now: 1000, rate: 1, burst: 2 }).allowed);
		let r = ratelimit.check(tok, { now: 1000, rate: 1, burst: 2 });
		t.assert_false(r.allowed);
		t.assert_true(r.retry_after_seconds >= 1);
	});

	t.it('refills after enough time and allows again', () => {
		let tok = fresh_token();
		clean(tok);
		// rate=1/sec, burst=1 - consume immediately, then wait 1s
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
