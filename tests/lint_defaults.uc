#!/usr/bin/ucode

// Walks src/resources/*.uc and fails CI on three drift conditions in
// schema_properties annotations vs fromUci:
//
//   1. fromUci has an unconditional default for a field, but schema_properties
//      either lacks the field entirely OR has the field without `default: V`
//      matching the fromUci fallback. The terraform-provider-uapi reads
//      `default:` to keep the field Optional+Computed (sticky); a missing
//      annotation makes the provider treat the field as caller-owned, which
//      causes perpetual non-converging diffs on apply.
//
//   2. A field carries both `default: V` and `"x-uapi-clear-on-omit": true`.
//      The two are mutually exclusive: a defaulted field cannot be safely
//      cleared (apply clears uci, fromUci re-defaults, next plan diffs again).
//
//   3. Conditional defaults: a `fromUci` field defaulted inside an
//      `if (proto == ...)` block (assigned via `view.X = ...`) or wrapped in
//      a `(section.X != null) ? ... : null` ternary has no static literal
//      value, so it must NOT carry `default:` in schema_properties. The lint
//      anchors detection on dict-literal assignments (`<jsonkey>: <expr>`),
//      which naturally excludes both `view.X = ...` and the ternary form
//      (because the ternary's left-hand expression starts with `(` not
//      `normalize_bool`).
//
// Patterns detected (in fromUci's returned dict literal):
//   - <jsonkey>: normalize_bool(section.<ucikey>, true|false)
//   - <jsonkey>: normalize_bool(section["<ucikey>"], true|false)
//   - <jsonkey>: section.<ucikey> ?? "literal"
//
// Captures the JSON-side key (the schema property name), not the uci-side
// key. Some resources name them differently (e.g. dropbear's password_auth
// JSON key maps to uci's PascalCase PasswordAuth option).
//
// Patterns NOT detected (silently skipped; authors of new code must remember
// to annotate manually):
//   - out[<dynvar>] = normalize_bool(...)   -- dynamic key (collector loop)
//   - <jsonkey>: section.<ucikey> ?? <numeric|bool>   -- non-string ?? defaults
//   - Multi-line normalize_bool across line breaks

import * as fs from 'fs';

const ALLOWLIST = {
	// fromUci field not exposed in schema_properties (not a managed input).
	"dhcp.hosts.uc:dns": "fromUci-internal, not surfaced in schema_properties",
};

function read_file(path) {
	let f = fs.open(path, "r");
	if (!f) return "";
	let raw = f.read("all") ?? "";
	f.close();
	return raw;
}

function basename(path) {
	let parts = split(path, "/");
	return parts[length(parts) - 1];
}

function escape_regex(s) {
	let out = "";
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		if (c == "." || c == "(" || c == ")" || c == "[" || c == "]")
			out += "\\" + c;
		else
			out += c;
	}
	return out;
}

function find_fromuci_defaults(content) {
	let defaults = {};
	// Anchor on the dict-literal assignment shape inside fromUci. This
	// captures the JSON-side key (the schema property name) and naturally
	// excludes conditional `view.X = ...` blocks (different LHS shape) and
	// `(section.X != null) ? ... : null` ternaries (RHS starts with `(`).
	let bool_dot_re     = regexp('([a-zA-Z_][a-zA-Z0-9_]*):\\s*normalize_bool\\(section\\.[a-zA-Z_][a-zA-Z0-9_]*,\\s*(true|false)\\)');
	let bool_bracket_re = regexp('([a-zA-Z_][a-zA-Z0-9_]*):\\s*normalize_bool\\(section\\["[a-zA-Z_][a-zA-Z0-9_]*"\\],\\s*(true|false)\\)');
	let str_re          = regexp('([a-zA-Z_][a-zA-Z0-9_]*):\\s*section\\.[a-zA-Z_][a-zA-Z0-9_]*\\s*\\?\\?\\s*"([^"]+)"');

	for (let line in split(content, "\n")) {
		let m;
		if (m = match(line, bool_dot_re))     defaults[m[1]] = m[2];
		if (m = match(line, bool_bracket_re)) defaults[m[1]] = m[2];
		if (m = match(line, str_re))          defaults[m[1]] = sprintf('"%s"', m[2]);
	}
	return defaults;
}

function check_schema_default(content, field, expected) {
	let in_sp = regexp(sprintf('\\b%s:[^a-zA-Z_]*\\{', field));
	if (!match(content, in_sp)) return "missing-from-schema";
	let default_re = regexp(sprintf('\\b%s:[^{}]*\\{[^{}]*default:\\s*%s', field, escape_regex(expected)));
	if (!match(content, default_re)) return "missing-default";
	return null;
}

function check_mutex(content) {
	// A field cannot carry both default: and "x-uapi-clear-on-omit": true.
	// Two orderings to cover; both match the same dict entry by avoiding {}.
	let a = regexp('\\{[^{}]*"x-uapi-clear-on-omit":\\s*true[^{}]*default:');
	let b = regexp('\\{[^{}]*default:[^{}]*"x-uapi-clear-on-omit":\\s*true');
	return !!(match(content, a) || match(content, b));
}

function lint_file(path) {
	let content = read_file(path);
	let base = basename(path);
	let defaults = find_fromuci_defaults(content);
	let errors = [];

	for (let field in defaults) {
		let key = base + ":" + field;
		if (ALLOWLIST[key]) continue;
		let expected = defaults[field];
		let problem = check_schema_default(content, field, expected);
		if (problem == "missing-from-schema") {
			push(errors, sprintf("  %s: field '%s' has fromUci default %s but is absent from schema_properties (annotate it, or add to ALLOWLIST if the field is intentionally response-only)",
				base, field, expected));
		} else if (problem == "missing-default") {
			push(errors, sprintf("  %s: field '%s' has fromUci default %s but schema_properties.%s missing 'default: %s'",
				base, field, expected, field, expected));
		}
	}

	if (check_mutex(content))
		push(errors, sprintf("  %s: a schema_properties entry carries both 'default:' and '\"x-uapi-clear-on-omit\": true'; they are mutually exclusive (a defaulted field cannot be safely cleared without producing perpetual non-converging diffs)",
			base));

	return errors;
}

let resources = fs.lsdir("src/resources") ?? [];
let all_errors = [];
let count = 0;
for (let fname in resources) {
	if (substr(fname, length(fname) - 3) != ".uc") continue;
	count++;
	let errs = lint_file("src/resources/" + fname);
	for (let e in errs) push(all_errors, e);
}

if (length(all_errors) > 0) {
	printf("FAIL: schema_properties annotations drift:\n");
	for (let e in all_errors) printf("%s\n", e);
	printf("\nFix the resource module, or document the exception in tests/lint_defaults.uc::ALLOWLIST.\n");
	exit(1);
}

printf("OK: %d resources checked, schema_properties annotations consistent\n", count);
