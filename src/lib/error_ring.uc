let fs = require('fs');
let state_dir = require('state_dir');

// Last 20 error envelopes surfaced via /diagnostics.
// Best-effort: any fs failure is swallowed because logging must never
// disrupt the actual response.
const DIR = "/var/run/uapi-error-ring";
const PATH = DIR + "/ring.json";
const CAP = 20;
// The ring outlives the request in tmpfs, and the 400 for a control character in a body
// names the key before authentication. Unclipped, any client could park its body here 20
// times over, and every later error re-reads and rewrites all of it.
const MAX_MESSAGE = 512;

function read() {
	if (!state_dir.owned(DIR)) return [];
	let f = fs.open(PATH, "r");
	if (!f) return [];
	let raw = f.read("all") ?? "";
	f.close();
	let v;
	try { v = json(raw); } catch (_) { return []; }
	if (type(v) != "array") return [];
	return v;
}

function append(entry) {
	if (type(entry) != "object" || !state_dir.owned(DIR)) return;
	try {
		let existing = read();
		let m = entry.message;
		if (length(m) > MAX_MESSAGE) {
			// A cut inside a UTF-8 sequence would make /diagnostics serve text that is not UTF-8.
			let cut = MAX_MESSAGE;
			while (cut > 0 && (ord(m, cut) & 0xC0) == 0x80) cut--;
			m = substr(m, 0, cut) + "...";
		}
		push(existing, { ...entry, message: m });
		while (length(existing) > CAP) shift(existing);
		// One name per request process. Appends that shared one wrote through their own offsets
		// into one file, which then held no JSON, and the ring read empty.
		state_dir.replace(PATH + "." + fs.readlink("/proc/self"), PATH, sprintf("%J", existing));
	} catch (_) {}
}

return { read, append, CAP, MAX_MESSAGE };
