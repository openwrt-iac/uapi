let fs = require('fs');

// File-backed counter+histogram store under /tmp/uapi-metrics.
// Each series is one file with the bare integer count. Histograms are
// represented as one file per (series, le-bucket). Atomic increment uses
// read+1+atomic-rename to avoid losing increments under concurrent forks.
// Loss under hot races is acceptable - these are operational metrics, not a
// billing source.
const DIR = "/tmp/uapi-metrics";
const HIST_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10];
// Same charset uci package names follow; keeps label values from breaking the
// filename layout (label values become path components). HTTP method, status,
// path templates, and resource keys all fall safely inside this set.
const LABEL_RE = /^[A-Za-z0-9_:.\/-]+$/;

function _mkdir_p(path) {
	let parts = split(path, "/");
	let acc = "";
	for (let p in parts) {
		if (p == "") { acc = "/"; continue; }
		acc = (acc == "/" || acc == "") ? acc + p : acc + "/" + p;
		try { fs.mkdir(acc); } catch (_) {}
	}
}

function _safe_label(v) {
	if (v == null) return null;
	if (type(v) != "string") v = "" + v;
	if (v == "" || !match(v, LABEL_RE)) return null;
	return v;
}

function _series_dir(series) {
	return DIR + "/" + series;
}

// Label values may contain `/` (request paths, scope strings) so they get
// percent-encoded before becoming path components. The reverse is applied
// when reading.
function _path_safe(v) {
	let out = "";
	for (let i = 0; i < length(v); i++) {
		let c = substr(v, i, 1);
		out += (c == "/") ? "%2F" : c;
	}
	return out;
}

function _path_unsafe(v) {
	let out = "";
	let i = 0;
	while (i < length(v)) {
		if (i + 3 <= length(v) && substr(v, i, 3) == "%2F") { out += "/"; i += 3; }
		else { out += substr(v, i, 1); i++; }
	}
	return out;
}

function _label_path(series, labels) {
	let parts = [series];
	let keys_sorted = [];
	for (let k in labels) push(keys_sorted, k);
	sort(keys_sorted);
	for (let k in keys_sorted) {
		let safe_k = _safe_label(k);
		let safe_v = _safe_label(labels[k]);
		if (safe_k == null || safe_v == null) return null;
		push(parts, _path_safe(safe_k) + "=" + _path_safe(safe_v));
	}
	return DIR + "/" + join("/", parts) + ".txt";
}

function _read_counter(path) {
	let f = fs.open(path, "r");
	if (!f) return 0;
	let s = f.read("line") ?? "0";
	f.close();
	let n = int(trim(s));
	return n;
}

function _write_counter(path, value) {
	let dir_parts = split(path, "/");
	pop(dir_parts);
	_mkdir_p(join("/", dir_parts));
	let tmp = path + ".tmp";
	let f = fs.open(tmp, "w");
	if (!f) return false;
	f.write("" + value + "\n");
	f.close();
	try { return fs.rename(tmp, path); }
	catch (_) { try { fs.unlink(tmp); } catch (__) {} return false; }
}

function inc(series, labels, by) {
	let path = _label_path(series, labels ?? {});
	if (path == null) return;
	let n = _read_counter(path);
	_write_counter(path, n + (by ?? 1));
}

function observe(series, labels, value) {
	let bucket_labels;
	for (let i = 0; i < length(HIST_BUCKETS); i++) {
		let le = HIST_BUCKETS[i];
		if (value <= le) {
			bucket_labels = { ...labels, le: sprintf("%g", le) };
			inc(series + "_bucket", bucket_labels, 1);
		}
	}
	bucket_labels = { ...labels, le: "+Inf" };
	inc(series + "_bucket", bucket_labels, 1);
	inc(series + "_count", labels, 1);
}

// token_id is optional: null for pre-auth failures (401 invalid_token before
// authorize completes) and folds to "-" so the series row still aggregates.
// Cardinality stays bounded because token_id ranges over operator-configured
// tokens (a small set), not request paths.
function record_request(method, path_template, status, duration_ms, token_id) {
	let m = _safe_label(method);
	let p = _safe_label(path_template);
	let s = _safe_label("" + status);
	if (m == null || p == null || s == null) return;
	let tid = (token_id == null) ? "-" : (_safe_label(token_id) ?? "-");
	let labels = { method: m, path: p, status: s, token_id: tid };
	inc("uapi_requests_total", labels, 1);
	let no_status = { method: m, path: p };
	observe("uapi_request_duration_seconds", no_status, duration_ms / 1000.0);
}

function record_rate_limit_drop(token_id) {
	let id = _safe_label(token_id);
	if (id == null) return;
	inc("uapi_rate_limit_drops_total", { token_id: id }, 1);
}

function record_lock_contention(lock_type) {
	let lt = _safe_label(lock_type) ?? "unknown";
	inc("uapi_lock_contention_total", { lock_type: lt }, 1);
}

function record_validate_error(resource, code) {
	let r = _safe_label(resource);
	let c = _safe_label(code);
	if (r == null || c == null) return;
	inc("uapi_validate_errors_total", { resource: r, code: c }, 1);
}

function _walk(dir, into) {
	let entries;
	try { entries = fs.lsdir(dir); } catch (_) { return; }
	if (entries == null) return;
	for (let name in entries) {
		let p = dir + "/" + name;
		let st;
		try { st = fs.stat(p); } catch (_) { st = null; }
		if (st == null) continue;
		if (st.type == "directory") {
			_walk(p, into);
		} else if (st.type == "file" && substr(name, length(name) - 4) == ".txt") {
			push(into, p);
		}
	}
}

function _path_to_series_and_labels(path) {
	let stripped = substr(path, length(DIR) + 1);
	let no_ext = substr(stripped, 0, length(stripped) - 4);
	let parts = split(no_ext, "/");
	let series = parts[0];
	let labels = {};
	for (let i = 1; i < length(parts); i++) {
		let kv = split(parts[i], "=", 2);
		if (length(kv) != 2) continue;
		labels[_path_unsafe(kv[0])] = _path_unsafe(kv[1]);
	}
	return { series, labels };
}

function _format_labels(labels) {
	let keys_sorted = [];
	for (let k in labels) push(keys_sorted, k);
	sort(keys_sorted);
	let parts = [];
	for (let k in keys_sorted)
		push(parts, sprintf("%s=\"%s\"", k, labels[k]));
	if (length(parts) == 0) return "";
	return "{" + join(",", parts) + "}";
}

function format_prometheus() {
	let files = [];
	_walk(DIR, files);
	sort(files);
	let lines = [];
	for (let p in files) {
		let m = _path_to_series_and_labels(p);
		let val = _read_counter(p);
		push(lines, sprintf("%s%s %d", m.series, _format_labels(m.labels), val));
	}
	return join("\n", lines) + "\n";
}

return {
	inc, observe,
	record_request, record_rate_limit_drop,
	record_lock_contention, record_validate_error,
	format_prometheus,
};
