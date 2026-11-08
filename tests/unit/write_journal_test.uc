let t = require('harness');
let fs = require('fs');
let state_dir_real = require('state_dir');
let write_journal = require('write_journal');

t.describe('write_journal', () => {
	const DIR = "/tmp/uapi-test-write-journal";
	const SELF = 424242;
	const DEAD = 99999999;
	const REUSED = 424243;
	// /proc/<pid>/stat with a command name that holds spaces and a parenthesis, and the start time
	// in field 22.
	let stat_of = (pid, start) => sprintf("%d (uc (x) y) S %s %s 0 0\n", pid, join(" ", map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 ], (n) => "" + n)), start);

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
				readfile: (p) => {
					if (p == sprintf("/proc/%d/stat", SELF)) return stat_of(SELF, 777);
					if (p == sprintf("/proc/%d/stat", REUSED)) return stat_of(REUSED, 900);
					if (p == sprintf("/proc/%d/stat", DEAD)) return null;
					return fs.readfile(p);
				},
			},
			state_dir: { ...state_dir_real,
				DIRS: { ...state_dir_real.DIRS, interrupted_writes: DIR } },
		}, ["write_journal"]);
	}

	function read_rec(pid, start) {
		let f = fs.open(sprintf("%s/%d-%d.json", DIR, pid, start), "r");
		if (f == null) return null;
		let rec = json(f.read("all") ?? "null");
		f.close();
		return rec;
	}

	t.it('record_start writes one record named by pid and start time, clear removes it', () => {
		fresh();
		let wj = load_wj();
		t.assert_true(wj.record_start(["network"], "req-1", ["wan", "lan"]));
		let rec = read_rec(SELF, 777);
		t.assert_equal(rec.pid, SELF);
		t.assert_equal(rec.request_id, "req-1");
		t.assert_deep_equal(rec.packages, ["network"]);
		t.assert_deep_equal(rec.staged, ["wan", "lan"]);
		t.assert_equal(rec.reload_started, false);
		wj.clear();
		t.assert_equal(read_rec(SELF, 777), null);
	});

	t.it('mark_reload_started updates the record', () => {
		fresh();
		let wj = load_wj();
		wj.record_start(["network"], "req-2", null);
		wj.mark_reload_started();
		t.assert_equal(read_rec(SELF, 777).reload_started, true);
		wj.clear();
	});

	// A later process can reuse the pid of a killed request, and it would have hidden the record.
	t.it('stale reports the records whose process is gone, its pid reused by another included', () => {
		fresh();
		let wj = load_wj();
		wj.record_start(["network"], "req-3", null);
		let plant = (pid, start, request_id) => fs.writefile(sprintf("%s/%d-%d.json", DIR, pid, start),
			sprintf("%J", { pid, request_id, packages: ["dhcp"], staged: null, started_at: 1, reload_started: true }));
		plant(DEAD, 5, "dead");
		plant(REUSED, 500, "reused");
		let out = map(wj.stale(), (r) => r.request_id);
		t.assert_deep_equal(sort(out), [ "dead", "reused" ]);
		wj.clear();
	});

	t.it('stale reads nothing when the directory does not exist', () => {
		rm_rf(DIR);
		let wj = load_wj();
		t.assert_deep_equal(wj.stale(), []);
	});
});
