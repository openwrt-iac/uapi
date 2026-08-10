// Property-test harness. Two contracts: (1) fromUci -> toUci -> fromUci is
// stable (drift-free for Terraform); (2) validate is total (never throws).
// ucode has no Math.random, so we thread a deterministic LCG state.

function lcg(seed) {
	let state = seed;
	return function() {
		state = (state * 1103515245 + 12345) % 2147483648;
		return state;
	};
}

function rint(rng, min, max) {
	return min + rng() % (max - min + 1);
}

const ALPHA  = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const TYPABLE = "abc 123 !@#$%^&*()_+-=[]{}|;:'\",.<>/?`~\n\r\t\0";

function rstring(rng, min, max, alphabet) {
	let n = rint(rng, min, max);
	let s = "";
	let abc = alphabet ?? ALPHA;
	for (let i = 0; i < n; i++) s = s + substr(abc, rng() % length(abc), 1);
	return s;
}

function rmac(rng) {
	let oct = function() { return sprintf("%02x", rng() % 256); };
	return oct() + ":" + oct() + ":" + oct() + ":" + oct() + ":" + oct() + ":" + oct();
}

function ripv4(rng) {
	return sprintf("%d.%d.%d.%d", rng() % 256, rng() % 256, rng() % 256, rng() % 256);
}

function ripv4_cidr(rng) {
	return ripv4(rng) + "/" + (rng() % 33);
}

function fuzz_any(rng) {
	let pick = rng() % 12;
	if (pick == 0) return null;
	if (pick == 1) return true;
	if (pick == 2) return false;
	if (pick == 3) return rint(rng, -2147483647, 2147483647);
	if (pick == 4) return rstring(rng, 0, 64, TYPABLE);
	if (pick == 5) return rstring(rng, 0, 4096, TYPABLE);  // big string
	if (pick == 6) {
		let n = rng() % 6;
		let a = [];
		for (let i = 0; i < n; i++) push(a, fuzz_any(rng));
		return a;
	}
	if (pick == 7) {
		let n = rng() % 6;
		let o = {};
		for (let i = 0; i < n; i++) o[rstring(rng, 1, 8, ALPHA)] = fuzz_any(rng);
		return o;
	}
	if (pick == 8) return rstring(rng, 1, 32, "\0\n\r;|<>$`\\");  // shell-meta
	if (pick == 9) return rmac(rng);
	if (pick == 10) return ripv4(rng);
	if (pick == 11) return ripv4_cidr(rng);
	return null;
}

function fuzz_object(rng) {
	// Force the top-level to be an object the way our validates expect.
	let o = {};
	let n = 1 + rng() % 12;
	for (let i = 0; i < n; i++)
		o[rstring(rng, 1, 12, ALPHA)] = fuzz_any(rng);
	return o;
}

function check_validate_total(resource, n_iterations, seed) {
	let rng = lcg(seed);
	let surprises = [];
	for (let i = 0; i < n_iterations; i++) {
		let body = fuzz_object(rng);
		let errs = null;
		let threw = null;
		try { errs = resource.validate(body, null, null); }
		catch (e) { threw = "" + e; }
		if (threw != null) {
			push(surprises, { iter: i, body: body, threw: threw });
			if (length(surprises) >= 3) break;  // cap the report
		} else if (type(errs) != "array") {
			push(surprises, { iter: i, body: body, returned: errs });
			if (length(surprises) >= 3) break;
		}
	}
	return surprises;
}

function json_eq(a, b) {
	if (a == null && b == null) return true;
	if (a == null || b == null) return false;
	if (type(a) != type(b)) return false;
	if (type(a) == "array") {
		if (length(a) != length(b)) return false;
		for (let i = 0; i < length(a); i++)
			if (!json_eq(a[i], b[i])) return false;
		return true;
	}
	if (type(a) == "object") {
		for (let k in a) if (!json_eq(a[k], b[k])) return false;
		for (let k in b) if (!json_eq(a[k], b[k])) return false;
		return true;
	}
	return a == b;
}

function synthesize_section_from_toUci(out, sec_type, sec_name) {
	let s = { ...out };
	s['.name'] = sec_name ?? "test_section";
	s['.anonymous'] = false;
	if (sec_type != null) s['.type'] = sec_type;
	return s;
}

function check_round_trip(resource, sections, opts) {
	let surprises = [];
	let ignore_keys = (opts != null && opts.ignore_keys != null) ? opts.ignore_keys : ["runtime"];
	let ignore = {};
	for (let k in ignore_keys) ignore[k] = true;
	for (let i = 0; i < length(sections); i++) {
		let s = sections[i];
		let v1 = resource.fromUci(s, null);
		let written = resource.toUci(v1);
		let s2 = synthesize_section_from_toUci(written, s['.type'], s['.name']);
		let v2 = resource.fromUci(s2, null);
		for (let k in v1) {
			if (ignore[k]) continue;
			if (!json_eq(v1[k], v2[k])) {
				push(surprises, { iter: i, key: k, before: v1[k], after: v2[k] });
				if (length(surprises) >= 5) return surprises;
			}
		}
	}
	return surprises;
}

return {
	check_validate_total, check_round_trip,
	json_eq,
};
