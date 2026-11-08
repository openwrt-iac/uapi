let fs = require('fs');
let state_dir = require('state_dir');

// One record per in-flight write, named by the pid of the request process and its start time: a
// fork-per-request process runs one recipe at a time, and a later process can reuse the pid, which
// every request and every reload forks through quickly on a router. Written before the commit,
// under the package lock, so the record and the commit are ordered together. Removed at the end
// of the recipe when it returns, and kept when it throws, as when uhttpd kills it (SIGKILL after
// the commit, or script_timeout): a record whose process is gone is stale by definition, and
// /diagnostics reports it as such.
const DIR = state_dir.DIRS.interrupted_writes;

let current = null, current_path = null;

// Field 22 of /proc/<pid>/stat, after the command name, which can hold spaces and parentheses.
function start_of(pid) {
	let stat = fs.readfile(sprintf("/proc/%s/stat", pid));
	if (stat == null) return null;
	return split(substr(stat, rindex(stat, ")") + 2), " ")[19];
}

function self_pid() {
	let p = fs.readlink("/proc/self");
	return (p != null && match(p, /^[0-9]+$/)) ? +p : null;
}

function write_rec() {
	return state_dir.replace(current_path + ".tmp", current_path, sprintf("%J", current));
}

function record_start(packages, request_id, staged) {
	let pid = self_pid();
	let start = (pid != null) ? start_of(pid) : null;
	if (start == null || !match(start, /^[0-9]+$/) || !state_dir.owned(DIR)) return false;
	current = { pid: pid, request_id: request_id, packages: packages,
	            staged: staged, started_at: time(), reload_started: false };
	current_path = sprintf("%s/%d-%s.json", DIR, pid, start);
	return write_rec();
}

function mark_reload_started() {
	if (current == null) return;
	current.reload_started = true;
	write_rec();
}

function clear() {
	if (current == null) return;
	current = null;
	fs.unlink(current_path);
}

// Read-only: does not create the directory. A record whose process still runs, the same pid with
// the same start time, is an in-flight write, not an interrupted one, and is not reported.
function stale() {
	let out = [];
	for (let name in fs.lsdir(DIR) ?? []) {
		let m = match(name, /^([0-9]+)-([0-9]+)\.json$/);
		if (m == null) continue;
		if (start_of(m[1]) == m[2]) continue;
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
