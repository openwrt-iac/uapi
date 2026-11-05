let fs = require('fs');
let state_dir = require('state_dir');

// One record per in-flight write, named by the pid of the request process: a fork-per-request
// process runs one recipe at a time, so pid is unique among live records. Written before the
// commit, under the package lock, so the record and the commit are ordered together. Removed
// at the end of the recipe on every path the request can still reach. A record whose pid no
// longer exists was left by a request that uhttpd killed (SIGKILL after the commit, or
// script_timeout), so it is stale by definition and /diagnostics reports it as such.
const DIR = state_dir.DIRS.interrupted_writes;

let current = null;

function path_for(pid) {
	return sprintf("%s/%d.json", DIR, pid);
}

function self_pid() {
	let p = fs.readlink("/proc/self");
	return (p != null && match(p, /^[0-9]+$/)) ? +p : null;
}

function write_rec(rec) {
	return state_dir.replace(path_for(rec.pid) + ".tmp", path_for(rec.pid), sprintf("%J", rec));
}

function record_start(packages, request_id, staged) {
	let pid = self_pid();
	if (pid == null || !state_dir.owned(DIR)) return false;
	let started_at = 0;
	try { started_at = time(); } catch (_) {}
	current = { pid: pid, request_id: request_id, packages: packages,
	            staged: staged, started_at: started_at, reload_started: false };
	return write_rec(current);
}

function mark_reload_started() {
	if (current == null) return;
	current.reload_started = true;
	write_rec(current);
}

function clear() {
	if (current == null) return;
	let pid = current.pid;
	current = null;
	fs.unlink(path_for(pid));
}

// Read-only: does not create the directory. A record whose pid is alive is an in-flight write,
// not an interrupted one, and is not reported.
function stale() {
	let out = [];
	for (let name in fs.lsdir(DIR) ?? []) {
		if (!match(name, /^[0-9]+\.json$/)) continue;
		let pid = int(substr(name, 0, length(name) - 5));
		if (fs.stat(sprintf("/proc/%d", pid)) != null) continue;
		let f = fs.open(DIR + "/" + name, "r");
		if (f == null) continue;
		let text = f.read("all") ?? "";
		f.close();
		let rec = null;
		try { rec = json(text); } catch (_) {}
		if (type(rec) == "object") push(out, rec);
	}
	return out;
}

return { record_start, mark_reload_started, clear, stale };
