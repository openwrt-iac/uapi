let t = require('harness');
let fs = require('fs');
let non_uci = require('non_uci');

function ctx() { return { request_id: "01hxnonuci0000000000000000" }; }
const LOCK_STUB = { acquire: function() { return {}; }, release: function() {} };

t.describe('non_uci.with_lock_translated', () => {
	t.it('lock contention yields locked envelope', () => {
		let lr = non_uci.with_lock_translated(ctx(),
			function() { return { ok: true }; }, {},
			{ acquire: function() { return null; }, release: function() {} });
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 423);
		t.assert_equal(lr.envelope.body.code, "locked");
	});

	t.it('lock_unavailable yields internal_error envelope', () => {
		let lr = non_uci.with_lock_translated(ctx(),
			function() { return { ok: true }; }, {},
			{ acquire: function() { return { unavailable: "/no/such" }; },
			  release: function() {} });
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 500);
	});

	t.it('translates kind=conflict to envelope when message provided', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "conflict" };
		}, { conflict: "thing already exists" }, LOCK_STUB);
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 409);
		t.assert_equal(lr.envelope.body.code, "conflict");
		t.assert_equal(lr.envelope.body.message, "thing already exists");
	});

	t.it('translates kind=not_found to 404', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "not_found" };
		}, { not_found: "gone" }, LOCK_STUB);
		t.assert_equal(lr.envelope.status, 404);
		t.assert_equal(lr.envelope.body.code, "not_found");
	});

	t.it('translates kind=io_error to 500 internal_error', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "io_error" };
		}, { io_error: "disk full" }, LOCK_STUB);
		t.assert_equal(lr.envelope.status, 500);
		t.assert_equal(lr.envelope.body.code, "internal_error");
	});

	t.it('translates kind=gone to 404', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "gone" };
		}, { gone: "vanished" }, LOCK_STUB);
		t.assert_equal(lr.envelope.status, 404);
	});

	t.it('unmapped kind falls through as result (caller handles)', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "weird_custom_kind", payload: 42 };
		}, {}, LOCK_STUB);
		t.assert_true(lr.envelope == null);
		t.assert_equal(lr.result.kind, "weird_custom_kind");
		t.assert_equal(lr.result.payload, 42);
	});

	t.it('mapped kind WITHOUT a caller-supplied message still produces an envelope', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: false, kind: "conflict" };
		}, {}, LOCK_STUB);
		t.assert_true(lr.envelope != null);
		t.assert_equal(lr.envelope.status, 409);
		t.assert_equal(lr.envelope.body.code, "conflict");
		t.assert_true(match(lr.envelope.body.message, /operation failed: conflict/) != null);
	});

	t.it('success result passes through with all fields', () => {
		let lr = non_uci.with_lock_translated(ctx(), function() {
			return { ok: true, info: { foo: "bar" }, count: 7 };
		}, {}, LOCK_STUB);
		t.assert_true(lr.envelope == null);
		t.assert_true(lr.result.ok);
		t.assert_equal(lr.result.info.foo, "bar");
		t.assert_equal(lr.result.count, 7);
	});
});

t.describe('non_uci.read_file_if_present', () => {
	t.it('reads a file', () => {
		t.assert_match(non_uci.read_file_if_present("VERSION"), /^[0-9]+\.[0-9]+\.[0-9]+/);
	});

	t.it('answers null for a file that is not there', () => {
		t.assert_equal(non_uci.read_file_if_present("tests/no-such-file"), null);
	});

	t.it('fails on a path that exists but cannot be read, rather than reading it as empty', () => {
		t.assert_throws(() => non_uci.read_file_if_present("tests/unit"));
	});
});

// ulimit -f fails a write to a regular file as a full filesystem does: 0 leaves the temp file
// empty, and 1 cuts it short after one block. close() reports neither.
t.describe('non_uci.replace_private_file', () => {
	const PATH = '/tmp/uapi-test-private';
	const SCRIPT = '/tmp/uapi-test-private.uc';

	t.it('replaces the file and leaves no temp file', () => {
		fs.writefile(PATH, 'old\n');
		t.assert_true(non_uci.replace_private_file(PATH, 'new\n'));
		t.assert_equal(fs.readfile(PATH), 'new\n');
		t.assert_equal(fs.stat(PATH + '.uapi.tmp'), null);
	});

	t.it('keeps the file and leaves no temp file when the filesystem cannot hold the new one', () => {
		for (let c in [ [ 0, 'new\n' ], [ 1, sprintf('%5000s\n', '') ] ]) {
			fs.writefile(PATH, 'old\n');
			fs.writefile(SCRIPT, sprintf("print(require('non_uci').replace_private_file(%J, %J));\n", PATH, c[1]));
			let p = fs.popen(sprintf("trap '' XFSZ; ulimit -f %d; exec ucode -L src/lib %s", c[0], SCRIPT));
			t.assert_equal(p.read('all'), 'false', sprintf('ulimit -f %d', c[0]));
			p.close();
			t.assert_equal(fs.readfile(PATH), 'old\n');
			t.assert_equal(fs.stat(PATH + '.uapi.tmp'), null);
		}
		fs.unlink(SCRIPT);
		fs.unlink(PATH);
	});
});
