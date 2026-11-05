let t = require('harness');
let fs = require('fs');
let state_dir_real = require('state_dir');
let write_journal = require('write_journal');

t.describe('write_journal', () => {
	const DIR = "/tmp/uapi-test-write-journal";
	const SELF = 424242;
	const DEAD = 99999999;

	function rm_rf(p) {
		if (fs.lstat(p)?.type == "directory") {
			for (let n in fs.lsdir(p) ?? []) rm_rf(p + "/" + n);
			fs.rmdir(p);
		} else if (fs.lstat(p) != null) {
			fs.unlink(p);
		}
	}

	function fresh() {
		rm_rf(DIR);
		fs.mkdir(DIR, 0o700);
	}

	function load_wj() {
		return t.load_with({
			fs: { ...fs,
				readlink: (p) => (p == "/proc/self") ? "" + SELF : fs.readlink(p),
				stat: (p) => {
					if (p == sprintf("/proc/%d", SELF)) return { type: "directory" };
					if (p == sprintf("/proc/%d", DEAD)) return null;
					return fs.stat(p);
				},
			},
			state_dir: { ...state_dir_real,
				DIRS: { ...state_dir_real.DIRS, interrupted_writes: DIR } },
		}, ["write_journal"]);
	}

	function read_rec(pid) {
		let f = fs.open(sprintf("%s/%d.json", DIR, pid), "r");
		if (f == null) return null;
		let rec = json(f.read("all") ?? "null");
		f.close();
		return rec;
	}

	t.it('record_start writes one record named by pid, clear removes it', () => {
		fresh();
		let wj = load_wj();
		t.assert_true(wj.record_start(["network"], "req-1", ["wan", "lan"]));
		let rec = read_rec(SELF);
		t.assert_equal(rec.pid, SELF);
		t.assert_equal(rec.request_id, "req-1");
		t.assert_deep_equal(rec.packages, ["network"]);
		t.assert_deep_equal(rec.staged, ["wan", "lan"]);
		t.assert_equal(rec.reload_started, false);
		wj.clear();
		t.assert_equal(read_rec(SELF), null);
	});

	t.it('mark_reload_started updates the record', () => {
		fresh();
		let wj = load_wj();
		wj.record_start(["network"], "req-2", null);
		wj.mark_reload_started();
		t.assert_equal(read_rec(SELF).reload_started, true);
		wj.clear();
	});

	t.it('stale reports only records whose process is gone', () => {
		fresh();
		let wj = load_wj();
		wj.record_start(["network"], "req-3", null);
		fs.writefile(sprintf("%s/%d.json", DIR, DEAD),
			sprintf("%J", { pid: DEAD, request_id: "old", packages: ["dhcp"],
			                staged: null, started_at: 1, reload_started: true }));
		let out = wj.stale();
		t.assert_equal(length(out), 1);
		t.assert_equal(out[0].pid, DEAD);
		t.assert_equal(out[0].request_id, "old");
		t.assert_equal(out[0].reload_started, true);
		wj.clear();
	});

	t.it('stale reads nothing when the directory does not exist', () => {
		rm_rf(DIR);
		let wj = load_wj();
		t.assert_deep_equal(wj.stale(), []);
	});
});
