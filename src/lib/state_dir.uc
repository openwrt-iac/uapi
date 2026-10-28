let fs = require('fs');

const EUID = match(fs.readfile("/proc/self/status") ?? "", /\nUid:\s+\d+\s+(\d+)/)?.[1];

// The request state under /var/run, which can carry a secret, is kept only in a directory that is
// this process's own and that no one else can write. One of its own with another mode, such as the
// 0755 of a plain mkdir, is narrowed to 0700, so that no one else reads it either. The uid is
// compared as text, so an euid that could not be read matches no directory.
function owned(dir) {
	fs.mkdir(dir, 0o700);
	let st = fs.lstat(dir);
	if (st?.type != "directory" || sprintf("%d", st.uid) !== EUID || (st.mode & 0o022)) return false;
	if ((st.mode & 0o777) != 0o700) fs.chmod(dir, 0o700);
	return true;
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

return { owned, replace };
