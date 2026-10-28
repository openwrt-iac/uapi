let t = require('harness');
let fs = require('fs');
let metrics = require('metrics');

// Each test isolates itself by writing to /var/run/uapi-metrics, then wiping it.
// We rely on metrics.uc using that exact path - if it changes, this breaks.
function wipe() {
	function rm_rf(p) {
		let st;
		try { st = fs.stat(p); } catch (_) { return; }
		if (st == null) return;
		if (st.type == "directory") {
			let entries;
			try { entries = fs.lsdir(p); } catch (_) { entries = []; }
			for (let n in entries ?? []) rm_rf(p + "/" + n);
			try { fs.rmdir(p); } catch (_) {}
		} else {
			try { fs.unlink(p); } catch (_) {}
		}
	}
	rm_rf("/var/run/uapi-metrics");
}

t.describe('metrics.inc', () => {
	t.it('creates a counter on first call', () => {
		wipe();
		metrics.inc("test_unit_counter", { a: "1" }, 1);
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "test_unit_counter") >= 0);
		t.assert_true(index(out, "a=\"1\"") >= 0);
	});

	t.it('accumulates across calls with the same labels', () => {
		wipe();
		metrics.inc("test_unit_counter", { a: "1" }, 1);
		metrics.inc("test_unit_counter", { a: "1" }, 2);
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "test_unit_counter{a=\"1\"} 3") >= 0);
	});

	t.it('keeps distinct buckets per label set', () => {
		wipe();
		metrics.inc("c", { x: "a" }, 1);
		metrics.inc("c", { x: "b" }, 5);
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "c{x=\"a\"} 1") >= 0);
		t.assert_true(index(out, "c{x=\"b\"} 5") >= 0);
	});

	t.it('removes its temp file when the rename fails', () => {
		wipe();
		fs.mkdir("/var/run/uapi-metrics");
		fs.mkdir("/var/run/uapi-metrics/c.txt");
		metrics.inc("c", {}, 1);
		let left = fs.stat("/var/run/uapi-metrics/c.txt.tmp") != null;
		wipe();
		t.assert_false(left);
	});
});

t.describe('metrics.record_request', () => {
	t.it('emits both _total and _duration series', () => {
		wipe();
		metrics.record_request("GET", "/firewall/rules", 200, 12);
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "uapi_requests_total") >= 0);
		t.assert_true(index(out, "uapi_request_duration_seconds_bucket") >= 0);
		t.assert_true(index(out, "uapi_request_duration_seconds_count") >= 0);
	});

	t.it('survives path templates containing slashes', () => {
		wipe();
		metrics.record_request("GET", "/firewall/rules/:id", 200, 5);
		let out = metrics.format_prometheus();
		// Round-trip: the path label decodes back to its original /-containing
		// form when format_prometheus reads files (path components are
		// percent-encoded on disk).
		t.assert_true(index(out, "path=\"/firewall/rules/:id\"") >= 0);
	});

	t.it('includes token_id label when supplied', () => {
		wipe();
		metrics.record_request("GET", "/firewall/rules", 200, 3, "ci_bot");
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "token_id=\"ci_bot\"") >= 0);
	});

	t.it('folds missing token_id to "-" so pre-auth failures still count', () => {
		wipe();
		metrics.record_request("GET", "/firewall/rules", 401, 1, null);
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "token_id=\"-\"") >= 0);
	});
});

t.describe('metrics.retire_tokens', () => {
	function requests_sum(out) {
		let n = 0;
		for (let l in split(out, "\n"))
			if (match(l, /^uapi_requests_total\{/)) n += int(split(l, " ")[1]);
		return n;
	}

	t.it('folds the series of a token that is not live into token_id="-retired"', () => {
		wipe();
		metrics.record_request("GET", "/firewall/rules", 200, 1, "run_1");
		metrics.record_request("GET", "/firewall/rules", 200, 1, "run_1");
		metrics.record_request("GET", "/firewall/rules", 200, 1, "run_2");
		metrics.record_request("GET", "/firewall/rules", 200, 1, "admin");
		metrics.record_request("GET", "/firewall/rules", 401, 1, null);
		metrics.record_rate_limit_drop("run_1");
		metrics.retire_tokens({ admin: true });
		let out = metrics.format_prometheus();
		t.assert_true(index(out, 'uapi_requests_total{method="GET",path="/firewall/rules",status="200",token_id="-retired"} 3\n') >= 0, out);
		t.assert_true(index(out, 'status="200",token_id="admin"} 1\n') >= 0, out);
		t.assert_true(index(out, 'status="401",token_id="-"} 1\n') >= 0, out);
		t.assert_true(index(out, 'uapi_rate_limit_drops_total{token_id="-retired"} 1\n') >= 0, out);
		t.assert_equal(index(out, "run_"), -1, out);
	});

	// A Prometheus counter may reset but must not fall, and a sum over token_id is what a
	// dashboard of all requests reads.
	t.it('keeps the sum over token_id across two folds', () => {
		wipe();
		metrics.record_request("POST", "/tokens", 201, 1, "run_1");
		metrics.record_request("POST", "/tokens", 201, 1, "run_1");
		metrics.retire_tokens({});
		metrics.record_request("POST", "/tokens", 201, 1, "run_2");
		metrics.retire_tokens({});
		let out = metrics.format_prometheus();
		t.assert_equal(requests_sum(out), 3, out);
		t.assert_true(index(out, 'token_id="-retired"} 3\n') >= 0, out);
	});

	// ulimit -f 0 fails every write as a full /tmp does, and the close that would report it
	// reports nothing. The rename then put an empty file over -retired, which read as 0.
	t.it('keeps the series of a token when its count cannot be added to -retired', () => {
		wipe();
		for (let i = 0; i < 5; i++) metrics.record_request("GET", "/system", 200, 1, "run_0");
		metrics.retire_tokens({});
		metrics.record_request("GET", "/system", 200, 1, "run_1");
		metrics.record_request("GET", "/system", 200, 1, "run_1");
		let dir = "/var/run/uapi-metrics/uapi_requests_total/method=GET/path=%2Fsystem/status=200/";
		let script = "/tmp/uapi-test-metrics-full.uc";
		fs.writefile(script, "require('metrics').retire_tokens({});\n");
		system("trap '' XFSZ; ulimit -f 0; exec ucode -L src/lib " + script + " >/dev/null 2>&1");
		fs.unlink(script);
		t.assert_equal(fs.readfile(dir + "token_id=-retired.txt"), "5\n");
		t.assert_equal(fs.readfile(dir + "token_id=run_1.txt"), "2\n");
		t.assert_equal(fs.stat(dir + "token_id=-retired.txt.tmp"), null);
		metrics.retire_tokens({});
		t.assert_equal(fs.readfile(dir + "token_id=-retired.txt"), "7\n");
		t.assert_equal(fs.stat(dir + "token_id=run_1.txt"), null);
	});
});

t.describe('metrics, a counter file that holds no count', () => {
	t.it('is left out of the scrape and starts again at the next increment', () => {
		wipe();
		metrics.inc("c", { x: "a" }, 4);
		fs.writefile("/var/run/uapi-metrics/c/x=a.txt", "NaN\n");
		t.assert_equal(index(metrics.format_prometheus(), "c{"), -1);
		metrics.inc("c", { x: "a" }, 1);
		t.assert_true(index(metrics.format_prometheus(), 'c{x="a"} 1\n') >= 0);
	});
});

t.describe('metrics, the modes on disk', () => {
	t.it('keeps every directory 0700 and every file 0600', () => {
		wipe();
		metrics.record_request("GET", "/firewall/rules/:id", 200, 1, "ci_bot");
		let wrong = [];
		function walk(p) {
			let st = fs.lstat(p);
			if ((st.mode & 0o777) != (st.type == "directory" ? 0o700 : 0o600))
				push(wrong, sprintf("%s %o", p, st.mode & 0o777));
			if (st.type == "directory")
				for (let n in fs.lsdir(p)) walk(p + "/" + n);
		}
		walk("/var/run/uapi-metrics");
		t.assert_deep_equal(wrong, []);
	});
});

t.describe('metrics, a directory that is not uapi\'s own', () => {
	// A fold unlinks a file that holds no count without adding anything, so the increment's own
	// check does not cover it.
	t.it('is not used: it takes no count, shows no series and folds none', () => {
		wipe();
		metrics.record_request("GET", "/system", 200, 1, "run_1");
		let file = "/var/run/uapi-metrics/uapi_requests_total/method=GET/path=%2Fsystem/status=200/token_id=run_1.txt";
		fs.writefile(file, "");
		fs.chmod("/var/run/uapi-metrics", 0o777);
		t.assert_false(metrics.inc("c", {}, 1));
		t.assert_equal(fs.stat("/var/run/uapi-metrics/c.txt"), null);
		t.assert_equal(metrics.format_prometheus(), "\n");
		metrics.retire_tokens({});
		t.assert_equal(fs.readfile(file), "");
		fs.chmod("/var/run/uapi-metrics", 0o700);
	});
});

t.describe('metrics.path_label', () => {
	let routes = {
		labels: { "/firewall/rules": true, "/firewall/rules/:id": true,
		          "/firewall/rules/:id/adopt": true, "/tokens/:id": true },
		raw_package: (p) => p == "firewall",
	};
	function label(path) {
		return metrics.path_label(filter(split(path, "/"), (s) => s != ""), routes);
	}

	t.it('labels a route with each of its parameters as :id', () => {
		t.assert_equal(label("/firewall/rules/r_01ABC"), "/firewall/rules/:id");
		t.assert_equal(label("/firewall/rules/r_01ABC/adopt"), "/firewall/rules/:id/adopt");
		t.assert_equal(label("/tokens/run_1"), "/tokens/:id");
		t.assert_equal(label("/raw/firewall/cfg01"), "/raw/firewall/:id");
	});

	t.it('records one label set for paths that no route serves', () => {
		wipe();
		for (let p in [ "/nope_1", "/nope_2/x", "/raw/nope/x", "/firewall/rules/x/y", "/tokens/a/b", "/" ])
			metrics.record_request("GET", label(p), 401, 1, null);
		let lines = filter(split(metrics.format_prometheus(), "\n"), (l) => match(l, /^uapi_requests_total\{/));
		t.assert_deep_equal(lines,
			[ 'uapi_requests_total{method="GET",path="unmatched",status="401",token_id="-"} 6' ]);
	});
});

t.describe('metrics.record_validate_error and record_lock_contention', () => {
	t.it('record_validate_error counts per (resource, code)', () => {
		wipe();
		metrics.record_validate_error("firewall.rules", "not_in_enum");
		metrics.record_validate_error("firewall.rules", "not_in_enum");
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "uapi_validate_errors_total{code=\"not_in_enum\",resource=\"firewall.rules\"} 2") >= 0);
	});

	t.it('record_lock_contention defaults the label to "unknown" if blank', () => {
		wipe();
		metrics.record_lock_contention(null);
		let out = metrics.format_prometheus();
		t.assert_true(index(out, "lock_type=\"unknown\"") >= 0);
	});
});
