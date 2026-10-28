let t = require('harness');
let fs = require('fs');
let state_dir = require('state_dir');

const DIR = "/tmp/uapi-test-state-dir";
const ELSEWHERE = DIR + "-elsewhere";

function rm_rf(p) {
	if (fs.lstat(p)?.type == "directory") {
		for (let n in fs.lsdir(p) ?? []) rm_rf(p + "/" + n);
		fs.rmdir(p);
	} else {
		fs.unlink(p);
	}
}

function fresh() {
	rm_rf(DIR);
	rm_rf(ELSEWHERE);
}

let mode = (p) => fs.lstat(p).mode & 0o777;

t.describe('state_dir.owned', () => {
	t.it('creates a missing directory with mode 0700', () => {
		fresh();
		t.assert_true(state_dir.owned(DIR));
		t.assert_equal(mode(DIR), 0o700);
	});

	t.it('narrows a directory of its own with mode 0755 to 0700', () => {
		fresh();
		fs.mkdir(DIR);
		fs.chmod(DIR, 0o755);
		t.assert_true(state_dir.owned(DIR));
		t.assert_equal(mode(DIR), 0o700);
	});

	t.it('does not use a directory that the group or others can write, and leaves its mode', () => {
		for (let m in [ 0o770, 0o707 ]) {
			fresh();
			fs.mkdir(DIR);
			fs.chmod(DIR, m);
			t.assert_false(state_dir.owned(DIR));
			t.assert_equal(mode(DIR), m);
		}
	});

	t.it('does not use a path that is not a directory', () => {
		fresh();
		fs.mkdir(ELSEWHERE, 0o700);
		fs.symlink(ELSEWHERE, DIR);
		t.assert_false(state_dir.owned(DIR));
		fs.unlink(DIR);
		fs.writefile(DIR, "");
		fs.chmod(DIR, 0o700);
		t.assert_false(state_dir.owned(DIR));
	});

	// A test cannot chown without root, so another owner is shown by an effective uid that is
	// not the real one.
	t.it('does not use a directory whose owner is not its effective uid', () => {
		fresh();
		fs.mkdir(DIR, 0o700);
		let uid = fs.lstat(DIR).uid;
		let status = sprintf("Name:\tucode\nUid:\t%d\t%d\t%d\t%d\n", uid, uid + 1, uid, uid);
		let other = t.load_with_fs({ ...fs,
			readfile: (p) => p == "/proc/self/status" ? status : fs.readfile(p) }, [ "state_dir" ]);
		t.assert_false(other.owned(DIR));
		t.assert_true(state_dir.owned(DIR));
	});

	t.it('does not use a directory of its own that it cannot narrow to 0700', () => {
		fresh();
		fs.mkdir(DIR);
		fs.chmod(DIR, 0o755);
		let other = t.load_with_fs({ ...fs, chmod: (p, m) => null }, [ "state_dir" ]);
		t.assert_false(other.owned(DIR));
		t.assert_true(state_dir.owned(DIR));
	});
});

t.describe('state_dir.replace', () => {
	t.it('writes the file with mode 0600 over a temp file with mode 0644', () => {
		fresh();
		state_dir.owned(DIR);
		fs.writefile(DIR + "/f.tmp", "stale");
		fs.chmod(DIR + "/f.tmp", 0o644);
		t.assert_true(state_dir.replace(DIR + "/f.tmp", DIR + "/f", "new\n"));
		t.assert_equal(fs.readfile(DIR + "/f"), "new\n");
		t.assert_equal(mode(DIR + "/f"), 0o600);
		t.assert_equal(fs.lstat(DIR + "/f.tmp"), null);
	});

	t.it('writes nothing outside the file it names, whatever the temp name holds', () => {
		fresh();
		state_dir.owned(DIR);
		fs.mkdir(ELSEWHERE, 0o700);
		fs.writefile(ELSEWHERE + "/target", "old\n");
		fs.symlink(ELSEWHERE + "/target", DIR + "/f.tmp");
		t.assert_true(state_dir.replace(DIR + "/f.tmp", DIR + "/f", "new\n"));
		t.assert_equal(fs.readfile(ELSEWHERE + "/target"), "old\n");
		t.assert_equal(fs.lstat(DIR + "/f").type, "file");
		t.assert_equal(fs.readfile(DIR + "/f"), "new\n");
	});

	// ulimit -f 0 fails every write as a full tmpfs does, and the close that would report it
	// reports nothing.
	t.it('keeps the file whole and leaves no temp file when the filesystem cannot hold the text', () => {
		fresh();
		state_dir.owned(DIR);
		fs.writefile(DIR + "/f", "old\n");
		fs.writefile(DIR + "/full.uc", sprintf("exit(require('state_dir').replace(%J, %J, 'new\\n') ? 0 : 1);\n",
		                                       DIR + "/f.tmp", DIR + "/f"));
		t.assert_equal(system("trap '' XFSZ; ulimit -f 0; exec ucode -L src/lib " + DIR + "/full.uc"), 1);
		t.assert_equal(fs.readfile(DIR + "/f"), "old\n");
		t.assert_equal(fs.lstat(DIR + "/f.tmp"), null);
	});
});

fresh();
