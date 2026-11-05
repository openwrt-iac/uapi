// Request bounds read from `config limits` in /etc/config/uapi. The compile-time
// defaults are what the options fall back to when the section or an option is
// absent, and BOUNDS keeps a typo from turning a bound into an OOM or a hang.
const DEFAULTS = {
	max_body_bytes: 262144,
	max_body_containers: 2000,
	body_read_s: 10,
	reload_budget_s: 20,
};

const BOUNDS = {
	max_body_bytes: [4096, 16777216],
	max_body_containers: [16, 65536],
	body_read_s: [1, 60],
	reload_budget_s: [1, 120],
};

function load(conn) {
	let cfg = { ...DEFAULTS };
	if (conn == null) return cfg;
	conn.uci_foreach('uapi', 'limits', function(s) {
		for (let k in DEFAULTS) {
			if (s[k] == null || !match(s[k], /^[0-9]+$/)) continue;
			let n = +s[k];
			let b = BOUNDS[k];
			if (n >= b[0] && n <= b[1]) cfg[k] = n;
		}
	});
	return cfg;
}

function reload_budget_ms(conn) {
	return load(conn).reload_budget_s * 1000;
}

return { load, reload_budget_ms, DEFAULTS };
