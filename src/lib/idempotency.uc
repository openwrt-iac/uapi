let fs = require('fs');

const DIR = "/tmp/uapi-idempotency";
const TTL_SECONDS = 86400;
const KEY_RE = /^[A-Za-z0-9_-][A-Za-z0-9_.:-]{0,127}$/;

let _digest = null;
try { _digest = require('digest'); } catch (_) {}

function _fp_inputs(token_name, key, body_text) {
	let payload = (token_name ?? "-") + "|" + key + "|" + (body_text ?? "");
	if (_digest != null) return _digest.sha256(payload);
	// Non-crypto fallback for test environments lacking ucode-mod-digest.
	let h1 = 5381, h2 = 7919;
	for (let i = 0; i < length(payload); i++) {
		let c = ord(substr(payload, i, 1));
		h1 = ((h1 * 33) + c) % 4294967296;
		h2 = ((h2 * 65599) + c) % 4294967296;
	}
	return sprintf("%08x%08x", h1, h2);
}

function _key_path(token_name, key) {
	let cache_key;
	if (_digest != null) {
		cache_key = _digest.sha256((token_name ?? "-") + "|" + key);
	} else {
		let h = 5381;
		let s = (token_name ?? "-") + "|" + key;
		for (let i = 0; i < length(s); i++) {
			let c = ord(substr(s, i, 1));
			h = ((h * 33) + c) % 4294967296;
		}
		cache_key = sprintf("%08x", h);
	}
	return DIR + "/" + cache_key + ".json";
}

function validate_key(key) {
	if (type(key) != "string") return false;
	return !!match(key, KEY_RE);
}

function lookup(token_name, key, body_text, now_epoch) {
	let path = _key_path(token_name, key);
	let st;
	try { st = fs.stat(path); } catch (_) { st = null; }
	if (st == null) return { state: "miss" };
	if (now_epoch != null && st.mtime != null && (now_epoch - st.mtime) > TTL_SECONDS) {
		try { fs.unlink(path); } catch (_) {}
		return { state: "miss" };
	}
	let f;
	try { f = fs.open(path, "r"); } catch (_) { f = null; }
	if (!f) return { state: "miss" };
	let raw = f.read("all") ?? "";
	f.close();
	let entry;
	try { entry = json(raw); } catch (_) { return { state: "miss" }; }
	if (type(entry) != "object" || entry.fingerprint == null)
		return { state: "miss" };
	let fp = _fp_inputs(token_name, key, body_text);
	if (entry.fingerprint != fp) return { state: "conflict" };
	return { state: "hit", response: {
		status: entry.status,
		headers: entry.headers,
		body: entry.body,
	}};
}

function store(token_name, key, body_text, response) {
	try { fs.mkdir(DIR); } catch (_) {}
	let path = _key_path(token_name, key);
	let entry = {
		fingerprint: _fp_inputs(token_name, key, body_text),
		status: response.status,
		headers: response.headers,
		body: response.body,
	};
	let tmp = path + ".tmp";
	let f = fs.open(tmp, "w");
	if (!f) return false;
	f.write(sprintf("%J", entry));
	f.close();
	try { return fs.rename(tmp, path); }
	catch (_) { try { fs.unlink(tmp); } catch (__) {} return false; }
}

return { validate_key, lookup, store };
