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
