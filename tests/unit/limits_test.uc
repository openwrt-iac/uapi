let t = require('harness');
let limits = require('limits');

function conn_with(sections) {
	return { uci_foreach: function(pkg, type, fn) {
		if (pkg != 'uapi' || type != 'limits') return;
		for (let s in sections) fn(s);
	} };
}

t.describe('limits.load', () => {
	t.it('returns the compiled defaults without a config section', () => {
		t.assert_deep_equal(limits.load(null), limits.DEFAULTS);
		t.assert_deep_equal(limits.load(conn_with([])), limits.DEFAULTS);
	});

	t.it('applies a valid override', () => {
		let cfg = limits.load(conn_with([{ max_body_bytes: "8192" }]));
		t.assert_equal(cfg.max_body_bytes, 8192);
		t.assert_equal(cfg.body_read_s, limits.DEFAULTS.body_read_s);
	});

	t.it('ignores values outside the accepted bounds', () => {
		let cfg = limits.load(conn_with([{ max_body_bytes: "10", body_read_s: "9999" }]));
		t.assert_equal(cfg.max_body_bytes, limits.DEFAULTS.max_body_bytes);
		t.assert_equal(cfg.body_read_s, limits.DEFAULTS.body_read_s);
	});

	t.it('ignores non-numeric values', () => {
		let cfg = limits.load(conn_with([{ max_body_containers: "abc" }]));
		t.assert_equal(cfg.max_body_containers, limits.DEFAULTS.max_body_containers);
	});

	t.it('reload_budget_ms converts seconds to milliseconds', () => {
		t.assert_equal(limits.reload_budget_ms(conn_with([{ reload_budget_s: "5" }])), 5000);
		t.assert_equal(limits.reload_budget_ms(null), limits.DEFAULTS.reload_budget_s * 1000);
	});
});
