let fs = require('fs');
let errors = require('errors');
let transaction = require('transaction');
let log = require('log');

const KIND_TO_CODE = {
	conflict:  "conflict",
	not_found: "not_found",
	gone:      "not_found",
	io_error:  "internal_error",
};

const _LOGFMT_SAFE = /^[A-Za-z0-9_.\/@:+-]+$/;

function _logfmt_value(v) {
	let t = type(v);
	if (t == "int" || t == "double" || t == "bool") return sprintf("%J", v);
	if (v == null) return "null";
	if (t == "string" && v != "" && match(v, _LOGFMT_SAFE)) return v;
	return sprintf("%J", v);
}

function with_lock_translated(ctx, fn, kind_messages, lock_opts) {
	let params = { fn: fn };
	if (lock_opts != null) {
		if (lock_opts.acquire != null)   params.acquire   = lock_opts.acquire;
		if (lock_opts.release != null)   params.release   = lock_opts.release;
		if (lock_opts.lock_path != null) params.lock_path = lock_opts.lock_path;
	}
	let r = transaction.with_lock(params);

	if (r.kind == "locked")
		return { envelope: errors.locked_from(ctx, null, r) };
	if (r.kind == "lock_unavailable")
		return { envelope: errors.lock_unavailable(ctx, r.error) };

	// A known kind always becomes an envelope. A missing caller-supplied
	// message falls back to a generic line rather than silently treating
	// the failure as success (which would let the caller dereference a
	// payload that isn't there).
	if (r.kind != null && KIND_TO_CODE[r.kind] != null) {
		let msg = (kind_messages != null) ? kind_messages[r.kind] : null;
		if (msg == null) msg = sprintf("operation failed: %s", r.kind);
		return { envelope: errors.error(ctx, KIND_TO_CODE[r.kind], msg) };
	}

	return { result: r };
}

function _audit(ctx, level, action, fields) {
	let parts = [sprintf("uapi-%s %s", action, ctx.request_id)];
	if (type(fields) == "object") {
		for (let k in fields)
			push(parts, k + "=" + _logfmt_value(fields[k]));
	}
	log.syslog(level, join(" ", parts));
}

function audit_notice(ctx, action, fields) {
	_audit(ctx, log.LOG_NOTICE, action, fields);
}

function audit_warning(ctx, action, fields) {
	_audit(ctx, log.LOG_WARNING, action, fields);
}

// Same-directory temp file with mode 0600 set BEFORE the content is written, then a
// rename into place. This closes the window where the file would briefly hold the
// content under default umask perms, and the rename is symlink-safe: swapping the target
// for a symlink between write and chmod cannot make us truncate whatever it points at.
function replace_private_file(path, content) {
	let tmp = path + ".uapi.tmp";
	try { fs.unlink(tmp); } catch (e) {}
	let f = fs.open(tmp, "w");
	if (!f) return false;
	try { fs.chmod(tmp, 384); } catch (e) {}  // 0600
	let written = f.write(content);
	// ucode's close() drops fclose's result, so a write the filesystem cannot hold shows up
	// only here: without this check, the empty temp file was renamed over the original and
	// the request answered 200. A short count covers content too large for one buffer.
	let flushed = f.flush();
	f.close();
	if (written != length(content) || !flushed) {
		try { fs.unlink(tmp); } catch (e) {}
		return false;
	}
	let renamed = false;
	try { renamed = fs.rename(tmp, path); } catch (e) {}
	if (!renamed) {
		try { fs.unlink(tmp); } catch (e) {}
		return false;
	}
	return true;
}

// A file that exists but cannot be read is not an empty one: treating it as empty lets the
// next write replace every line in it with only its own, which for authorized_keys locks
// root out of SSH.
function read_file_if_present(path) {
	let content = fs.readfile(path);
	if (content != null) return content;
	let err = fs.error();
	if (fs.stat(path) == null) return null;
	die(sprintf("could not read %s: %s", path, err));
}

return { with_lock_translated, audit_notice, audit_warning, replace_private_file,
         read_file_if_present };
