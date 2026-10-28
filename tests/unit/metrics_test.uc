let t = require('harness');
let fs = require('fs');
let metrics = require('metrics');

// Each test isolates itself by writing to /tmp/uapi-metrics, then wiping it.
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
	rm_rf("/tmp/uapi-metrics");
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
		fs.mkdir("/tmp/uapi-metrics");
		fs.mkdir("/tmp/uapi-metrics/c.txt");
		metrics.inc("c", {}, 1);
		let left = fs.stat("/tmp/uapi-metrics/c.txt.tmp") != null;
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
