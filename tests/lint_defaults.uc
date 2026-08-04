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

// Empty on purpose: its only entry excused dhcp.hosts.uc:dns as "not surfaced in
// schema_properties", which toUci contradicted by writing it. Kept as the seam for a
// field that genuinely is fromUci-internal.
const ALLOWLIST = {};

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

// Returns the list of field names carrying "x-uapi-clear-on-omit": true. The
// codebase format puts the field-name `<f>: {` and the flag on the same line;
// a future reformatter that splits the opening brace onto its own line would
// silently bypass this scan. Assumption documented in the resource module
// style; if it breaks, fix the resource file rather than complicate the lint.
function find_clear_on_omit_fields(content) {
	let fields = [];
	let entry_re = regexp('([a-zA-Z_][a-zA-Z0-9_]*):\\s*\\{');
	for (let line in split(content, "\n")) {
		if (index(line, '"x-uapi-clear-on-omit": true') < 0) continue;
		let m = match(line, entry_re);
		if (m) push(fields, m[1]);
	}
	return fields;
}

// The Terraform plugin-framework rejects an apply with "Provider produced
// inconsistent result after apply" when a plain Optional attribute (which
// clear-on-omit-enabled fields must be on the provider side) reads back any
// value for an absent uci option other than null. So `<jsonkey>: section.X ??
// null` is the only safe fromUci shape; as_list (returns []), derived
// expressions, ternaries, and `?? <non-null>` all break the contract.
function check_clear_on_omit_shape(content, fields) {
	let errors = [];
	for (let field in fields) {
		let safe_re = regexp(sprintf('\\b%s:\\s*section\\.[a-zA-Z_][a-zA-Z0-9_]*\\s*\\?\\?\\s*null', field));
		if (!match(content, safe_re))
			push(errors, sprintf("field '%s' has \"x-uapi-clear-on-omit\": true but its fromUci is not the safe `section.X ?? null` shape (Terraform plain-Optional reads back null only; as_list/derived/aliased values trip 'Provider produced inconsistent result')", field));
	}
	return errors;
}

// A clearable field must type-allow null. Provider sends explicit JSON null
// to clear; if the schema type is `"string"` (non-nullable), the wire payload
// fails the spec itself.
function check_clear_on_omit_type(content, fields) {
	let errors = [];
	let want = {};
	for (let f in fields) want[f] = true;
	let entry_open_re = regexp('([a-zA-Z_][a-zA-Z0-9_]*):\\s*\\{');
	for (let line in split(content, "\n")) {
		if (index(line, '"x-uapi-clear-on-omit": true') < 0) continue;
		let m = match(line, entry_open_re);
		if (!m || !want[m[1]]) continue;
		let has_null_in_list = !!match(line, regexp('type:\\s*\\[[^]]*"null"[^]]*\\]'));
		let is_null_scalar   = !!match(line, regexp('type:\\s*"null"'));
		if (!has_null_in_list && !is_null_scalar)
			push(errors, sprintf("field '%s' has \"x-uapi-clear-on-omit\": true but its type does not include \"null\" (provider sends JSON null to clear; non-nullable type rejects the wire payload)", m[1]));
	}
	return errors;
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

	let coo_fields = find_clear_on_omit_fields(content);
	for (let e in check_clear_on_omit_shape(content, coo_fields))
		push(errors, sprintf("  %s: %s", base, e));
	for (let e in check_clear_on_omit_type(content, coo_fields))
		push(errors, sprintf("  %s: %s", base, e));

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
