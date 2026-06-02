let fs = require('fs');

// File-backed token-bucket per token id.
//   /tmp/uapi-ratelimit/<token>.txt   "<tokens_float> <last_refill_ms>"
//
// Writes are racy across forks but bounded: at most one request worth of
// drift per worst-case race, and that drift is bounded by the burst size.
// Atomic-write (tmpfile + rename) prevents partial reads under reader/writer
// overlap. flock is avoided on the hot path because every authed request
// passes through here.
const DIR = "/tmp/uapi-ratelimit";
const DEFAULT_RATE = 100;
const DEFAULT_BURST = 200;
const SAFE_NAME_RE = /^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$/;

function _now_ms(now_epoch_seconds) {
	if (now_epoch_seconds == null) return null;
	return now_epoch_seconds * 1000;
}

function _read_state(token_id) {
	let path = DIR + "/" + token_id + ".txt";
	let f = fs.open(path, "r");
	if (!f) return null;
	let line = f.read("line") ?? "";
	f.close();
	let parts = split(trim(line), " ");
	if (length(parts) != 2) return null;
	let tokens = +parts[0];
	let last_ms = +parts[1];
	if (type(tokens) != "double" && type(tokens) != "int") return null;
	if (type(last_ms) != "double" && type(last_ms) != "int") return null;
	return { tokens, last_ms };
}

function _write_state(token_id, state) {
	try { fs.mkdir(DIR); } catch (_) {}
	let path = DIR + "/" + token_id + ".txt";
	let tmp  = path + ".tmp";
	let f = fs.open(tmp, "w");
	if (!f) return false;
	f.write(sprintf("%.4f %d\n", state.tokens, state.last_ms));
	f.close();
	let ok;
	try { ok = fs.rename(tmp, path); } catch (_) { ok = false; }
	if (!ok) try { fs.unlink(tmp); } catch (_) {}
	return ok;
}

// check(token_id, opts) returns { allowed, retry_after_seconds }.
//   opts.now        epoch seconds (caller supplies)
//   opts.rate       tokens per second (default 100)
//   opts.burst      bucket capacity (default 200)
//
// On the first request for a token the bucket starts full.
function check(token_id, opts) {
	let o = opts ?? {};
	let rate = o.rate ?? DEFAULT_RATE;
	let burst = o.burst ?? DEFAULT_BURST;
	let now_ms = _now_ms(o.now);
	if (token_id == null || !match(token_id, SAFE_NAME_RE) || now_ms == null)
		return { allowed: true, retry_after_seconds: 0 };

	let state = _read_state(token_id);
	if (state == null)
		state = { tokens: burst, last_ms: now_ms };

	let elapsed_ms = now_ms - state.last_ms;
	if (elapsed_ms < 0) elapsed_ms = 0;
	let refilled = state.tokens + (elapsed_ms * rate / 1000.0);
	if (refilled > burst) refilled = burst;

	let allowed = refilled >= 1.0;
	let new_tokens = allowed ? (refilled - 1.0) : refilled;
	let retry = 0;
	if (!allowed) {
		let deficit = 1.0 - refilled;
		retry = int((deficit * 1000.0 / rate) + 1);
		if (retry < 1) retry = 1;
	}
	_write_state(token_id, { tokens: new_tokens, last_ms: now_ms });
	return { allowed, retry_after_seconds: retry };
}

// load_config reads the optional `config ratelimit` section from /etc/config/uapi.
function load_config(conn) {
	let rate = DEFAULT_RATE;
	let burst = DEFAULT_BURST;
	conn.uci_foreach('uapi', 'ratelimit', function(s) {
		if (s.rate != null) {
			let n = +s.rate;
			if (n > 0) rate = n;
		}
		if (s.burst != null) {
			let n = +s.burst;
			if (n > 0) burst = n;
		}
	});
	return { rate, burst };
}

// override(rate, burst, token_record) lets a per-token override beat the
// global config. Returns the effective { rate, burst }.
function effective_limits(global, token_record) {
	let r = global.rate;
	let b = global.burst;
	if (token_record != null) {
		if (token_record.rate != null) {
			let n = +token_record.rate;
			if (n > 0) r = n;
		}
		if (token_record.burst != null) {
			let n = +token_record.burst;
			if (n > 0) b = n;
		}
	}
	return { rate: r, burst: b };
}

return { check, load_config, effective_limits };
