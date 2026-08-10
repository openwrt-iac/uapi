let fs = require('fs');

// Last 20 error envelopes surfaced via /diagnostics.
// Best-effort: any fs failure is swallowed because logging must never
// disrupt the actual response.
const DIR = "/tmp/uapi-error-ring";
const PATH = DIR + "/ring.json";
const CAP = 20;

function read() {
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
	if (type(entry) != "object") return;
	try {
		try { fs.mkdir(DIR); } catch (_) {}
		let existing = read();
		push(existing, entry);
		while (length(existing) > CAP) shift(existing);
		let tmp = PATH + ".tmp";
		let f = fs.open(tmp, "w");
		if (!f) return;
		f.write(sprintf("%J", existing));
		f.close();
		try { fs.rename(tmp, PATH); }
		catch (_) { try { fs.unlink(tmp); } catch (__) {} }
	} catch (_) {}
}

return { read, append, CAP };
