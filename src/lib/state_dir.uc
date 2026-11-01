let fs = require('fs');

let digest = null;
try { digest = require('digest'); } catch (_) {}

const EUID = match(fs.readfile("/proc/self/status") ?? "", /\nUid:\s+\d+\s+(\d+)/)?.[1];

const DIRS = {
	error_ring: "/var/run/uapi-error-ring",
	idempotency: "/var/run/uapi-idempotency",
	last_used: "/var/run/uapi-token-update",
	metrics: "/var/run/uapi-metrics",
	ratelimit: "/var/run/uapi-ratelimit",
};

// The request state under /var/run, which can carry a secret, is kept only in a directory that is
// this process's own and that no one else can write. One of its own with another mode, such as the
// 0755 of a plain mkdir, is narrowed to 0700, so that no one else reads it either. The uid is
// compared as text, so an euid that could not be read matches no directory.
function owned(dir) {
	fs.mkdir(dir, 0o700);
	let st = fs.lstat(dir);
	if (st?.type != "directory" || sprintf("%d", st.uid) !== EUID || (st.mode & 0o022)) return false;
	if ((st.mode & 0o777) != 0o700 && !fs.chmod(dir, 0o700)) return false;
	return true;
}

// A read reports what it finds, so it creates and narrows nothing, unlike owned(). null is a
// directory that the first write creates.
function used() {
	let out = {};
	for (let dir in sort(values(DIRS))) {
		let st = fs.lstat(dir);
		out[dir] = (st == null) ? null : (st.type == "directory" && sprintf("%d", st.uid) === EUID
		                                   && (st.mode & 0o777) == 0o700);
	}
	return out;
}

// uapi-token takes a name of any length, and a file name holds 255 bytes. A name longer than the 63
// characters that POST /tokens takes is named by its sha256, whose 64 characters no shorter name
// has. ucode-mod-digest is a dependency of the package, and the unit hosts lack it, so there such a
// name has no file.
function token_file(name) {
	if (match(name, /^[A-Za-z0-9_]{1,63}$/)) return name;
	return digest ? digest.sha256(name) : null;
}

// open() gives its mode only to a file that it creates, so the temp name is unlinked first. stdio
// buffers a small file, so a full tmpfs shows only at the close, which ucode does not report, and
// flush() answers inverted on the ucode that CI runs. The size on disk shows it.
function replace(tmp, path, text) {
	fs.unlink(tmp);
	let f = fs.open(tmp, "w", 0o600);
	if (!f) return false;
	f.write(text);
	f.close();
	if (fs.stat(tmp)?.size == length(text) && fs.rename(tmp, path)) return true;
	fs.unlink(tmp);
	return false;
}

return { DIRS, owned, used, token_file, replace };
