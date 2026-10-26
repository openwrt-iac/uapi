let t = require('harness');
let fs = require('fs');
let er = require('error_ring');

const DIR = "/var/run/uapi-error-ring";
const PATH = DIR + "/ring.json";

function wipe() {
	for (let n in fs.lsdir(DIR) ?? []) fs.unlink(DIR + "/" + n) || fs.rmdir(DIR + "/" + n);
}

let entry = (id, message) => ({ ts: 1, request_id: id, code: "locked", status: 423, message: message ?? "x" });

t.describe('error_ring', () => {
	t.it('read on missing file returns empty array', () => {
		wipe();
		t.assert_deep_equal(er.read(), []);
	});

	t.it('append + read round-trips a single entry', () => {
		wipe();
		er.append({ ts: 1, request_id: "r1", code: "bad_request", status: 400, message: "x" });
		let v = er.read();
		t.assert_equal(length(v), 1);
		t.assert_equal(v[0].request_id, "r1");
		t.assert_equal(v[0].code, "bad_request");
	});

	t.it('append silently drops non-object entries', () => {
		wipe();
		er.append("not an envelope");
		er.append(null);
		t.assert_deep_equal(er.read(), []);
	});

	t.it('trims to the most recent CAP entries on overflow', () => {
		wipe();
		for (let i = 0; i < er.CAP + 5; i++)
			er.append({ ts: i, request_id: "r" + i, code: "bad_request", status: 400, message: "x" });
		let v = er.read();
		t.assert_equal(length(v), er.CAP);
		t.assert_equal(v[0].request_id, "r5");
		t.assert_equal(v[length(v) - 1].request_id, "r" + (er.CAP + 4));
	});

	t.it('clips a long message, since a 400 before auth can name a key of any length', () => {
		wipe();
		let exact = "";
		for (let i = 0; i < er.MAX_MESSAGE; i++) exact += "a";
		er.append({ ts: 1, request_id: "r1", code: "bad_request", status: 400, message: exact });
		er.append({ ts: 2, request_id: "r2", code: "bad_request", status: 400, message: exact + "b" });
		let v = er.read();
		t.assert_equal(v[0].message, exact);
		t.assert_equal(v[1].message, exact + "...");
	});

	t.it('clips a long message before a character that the limit would cut', () => {
		wipe();
		let head = "";
		for (let i = 0; i < er.MAX_MESSAGE - 1; i++) head += "a";
		er.append({ ts: 1, request_id: "r1", code: "bad_request", status: 400, message: head + "é" + "b" });
		t.assert_equal(er.read()[0].message, head + "...");
	});

	t.it('survives garbage on disk by returning empty', () => {
		wipe();
		try { fs.mkdir("/var/run/uapi-error-ring"); } catch (_) {}
		let f = fs.open(PATH, "w");
		f.write("not json at all");
		f.close();
		t.assert_deep_equal(er.read(), []);
	});

	// The other append runs in a second process while this one holds its temp file open and has
	// not written yet. Under one shared name it truncated that file and wrote a longer ring through
	// its own offset, so this append's shorter ring left the tail of the other's behind it. The
	// later rename wins, so the other append's entry is lost, as for any two appends that cross.
	t.it('stays readable when another request appends at the same moment', () => {
		wipe();
		er.append(entry("r1"));
		let other = sprintf("require('error_ring').append(%J)", entry("r2", sprintf("%300s", "y")));
		let ran = false;
		let ring = t.load_with_fs({ ...fs, open: (p, m, perm) => {
			let f = fs.open(p, m, perm);
			if (m == "w" && !ran) {
				ran = true;
				system([ "ucode", "-L", "src/lib", "-e", other ]);
			}
			return f;
		} }, [ "state_dir", "error_ring" ]);
		ring.append(entry("r3"));
		t.assert_true(ran);
		t.assert_deep_equal(map(er.read(), (e) => e.request_id), [ "r1", "r3" ]);
	});

	t.it('does not use a directory that is not uapi\'s own', () => {
		wipe();
		er.append(entry("r1"));
		let held = fs.readfile(PATH);
		fs.chmod(DIR, 0o777);
		t.assert_deep_equal(er.read(), []);
		er.append(entry("r2"));
		t.assert_equal(fs.readfile(PATH), held);
		fs.chmod(DIR, 0o700);
		t.assert_deep_equal(map(er.read(), (e) => e.request_id), [ "r1" ]);
	});

	t.it('removes its temp file when the rename fails', () => {
		wipe();
		fs.mkdir(DIR);
		fs.mkdir(PATH);
		er.append(entry("r1"));
		let left = filter(fs.lsdir(DIR), (n) => n != "ring.json");
		wipe();
		t.assert_deep_equal(left, []);
	});
});
