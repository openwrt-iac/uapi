let t = require('harness');
let fs = require('fs');
let er = require('error_ring');

const PATH = "/tmp/uapi-error-ring/ring.json";

function wipe() {
	try { fs.unlink(PATH); } catch (_) {}
}

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

	t.it('survives garbage on disk by returning empty', () => {
		wipe();
		try { fs.mkdir("/tmp/uapi-error-ring"); } catch (_) {}
		let f = fs.open(PATH, "w");
		f.write("not json at all");
		f.close();
		t.assert_deep_equal(er.read(), []);
	});
});
