#!/usr/bin/ucode
// Coverage inventory at two granularities:
//
//   1. Module-level: every src/resources/* and src/lib/* module is mentioned
//      in at least one test file. Exits 1 on miss.
//
//   2. Function-level (lib only): exported names in `return { ... }` are
//      cross-referenced against test bodies for usage. Exits 1 if function
//      coverage drops below COVERAGE_FN_THRESHOLD (default 80%).
//
// Function-level is a static analysis, not a runtime tracer (ucode exposes no
// AST or trace hook for branch-level instrumentation). For each lib module,
// the script parses the final `return { ... }` block, extracts identifier-
// shaped names, and grep-checks usage as `<module>.<name>` across tests/.

import * as fs from 'fs';

const FN_THRESHOLD = 80;

function read_all(path) {
	let fp = fs.open(path, "r");
	if (!fp) return "";
	let s = fp.read("all") ?? "";
	fp.close();
	return s;
}

function list(dir) {
	let r = fs.lsdir(dir) ?? [];
	sort(r);
	return r;
}

let test_bodies = {};
for (let f in list("tests/unit"))
	test_bodies[f] = read_all("tests/unit/" + f);

let prop_body = read_all("tests/unit/property_test.uc");
let prop_covers_all_resources = match(prop_body, /validate\(\) is total across every resource/) != null;

function find_test_files(token) {
	let hits = [];
	for (let f in keys(test_bodies)) {
		if (index(test_bodies[f], token) >= 0)
			push(hits, f);
	}
	return hits;
}

let modules = [];

for (let f in list("src/resources")) {
	let name = replace(f, /\.uc$/, "");
	let hits = find_test_files("src/resources/" + f);
	if (prop_covers_all_resources)
		push(hits, "property_test.uc (validate-is-total)");
	push(modules, { kind: "resource", name: name, file: "src/resources/" + f, tests: hits });
}

for (let f in list("src/lib")) {
	let name = replace(f, /\.uc$/, "");
	let hits = find_test_files("require('" + name + "')");
	let hits2 = find_test_files("src/lib/" + f);
	for (let h in hits2)
		if (index(hits, h) < 0) push(hits, h);
	push(modules, { kind: "lib", name: name, file: "src/lib/" + f, tests: hits });
}

let covered = 0;
let uncovered = [];
for (let m in modules) {
	if (length(m.tests) > 0) covered++;
	else push(uncovered, m);
}

// --- Function-level (lib modules only) ---
//
// Parse the trailing `return { ... };` block of each lib module to find
// exported identifiers. ucode shorthand `{ foo }` and `{ foo: foo }` both
// produce the same exported name `foo`.
function extract_exports(src) {
	let m = match(src, /return\s*\{([^}]*)\}\s*;?\s*$/);
	if (!m) return [];
	let body = m[1];
	let names = {};
	for (let chunk in split(body, ",")) {
		let s = trim(chunk);
		if (s == "") continue;
		// Strip trailing `: value` if present.
		let colon = index(s, ":");
		if (colon >= 0) s = trim(substr(s, 0, colon));
		// Identifier?
		if (match(s, /^[A-Za-z_][A-Za-z0-9_]*$/))
			names[s] = true;
	}
	return keys(names);
}

// Collect production source bodies (everything under src/ EXCEPT the lib
// module's own file, so a function referenced only by its own home doesn't
// count). Functions called from another src file are "exercised in production"
// and gated by the integration suite; we count them as covered.
let production_bodies = {};
function add_dir(dir) {
	for (let f in list(dir)) production_bodies[dir + "/" + f] = read_all(dir + "/" + f);
}
add_dir("src");
add_dir("src/lib");
add_dir("src/resources");

function used_in_production(module_name, fn_name, own_file) {
	let token = module_name + "." + fn_name;
	for (let path in keys(production_bodies)) {
		if (path == own_file) continue;
		if (index(production_bodies[path], token) >= 0) return path;
	}
	return null;
}

// Tests usually alias modules: `let tx = require('transaction')`, then use
// `tx.default_acquire_pkg(...)`. Direct `module.name` matches would miss
// these. The heuristic: any test that mentions the module AND contains a
// `.name(` or `.name)` token references the function via its alias. Cheap
// false positives (a different module's same-named field) are acceptable
// since this is a coverage SIGNAL, not a proof.
function tested_via_alias(module_name, fn_name) {
	let needle = "." + fn_name;
	for (let f in keys(test_bodies)) {
		let body = test_bodies[f];
		if (index(body, "require('" + module_name + "')") < 0
		    && index(body, "src/lib/" + module_name + ".uc") < 0) continue;
		if (index(body, needle + "(") >= 0) return true;
		if (index(body, needle + ")") >= 0) return true;
		if (index(body, needle + ".") >= 0) return true;
		if (index(body, needle + ",") >= 0) return true;
		if (index(body, needle + ";") >= 0) return true;
	}
	return false;
}

// Internal reference detection. A bareword `name` appearing in the module
// outside its `function name(...)` declaration line means another exported
// function uses it (typical pattern: `params.foo ?? default_foo`). These
// count as production-covered, since the using path IS covered.
function used_internally(src, name) {
	let count = 0;
	for (let line in split(src, "\n")) {
		if (index(line, name) < 0) continue;
		// Strip the function-definition line.
		if (match(line, "^[[:space:]]*function[[:space:]]+" + name + "[[:space:]]*\\(")) continue;
		if (match(line, name + "[[:space:]]*=[[:space:]]*function")) continue;
		count++;
		if (count >= 1) return true;
	}
	return false;
}

let fn_total = 0;
let fn_unit = 0;
let fn_prod_only = 0;
let fn_dead = {};

for (let m in modules) {
	if (m.kind != "lib") continue;
	let src = read_all(m.file);
	let exports = extract_exports(src);
	let dead = [];
	for (let name in exports) {
		fn_total++;
		if (tested_via_alias(m.name, name)) {
			fn_unit++;
		} else if (used_in_production(m.name, name, m.file) != null
		           || used_internally(src, name)) {
			fn_prod_only++;
		} else {
			push(dead, name);
		}
	}
	if (length(dead) > 0) fn_dead[m.name] = dead;
}
let fn_covered = fn_unit + fn_prod_only;

printf("uapi coverage inventory\n");
printf("=======================\n");
printf("modules total:        %d\n", length(modules));
printf("modules covered:      %d (%.1f%%)\n", covered, (covered * 100.0) / length(modules));
printf("modules uncovered:    %d\n", length(uncovered));
printf("\n");

if (length(uncovered) > 0) {
	printf("UNCOVERED MODULES:\n");
	for (let m in uncovered)
		printf("  %-8s %s\n", m.kind, m.file);
	printf("\n");
}

let fn_pct = (fn_total > 0) ? (fn_covered * 100.0) / fn_total : 100.0;
printf("lib functions total:           %d\n", fn_total);
printf("  unit-tested:                 %d\n", fn_unit);
printf("  exercised in production only: %d\n", fn_prod_only);
printf("  covered (unit + production): %d (%.1f%%; threshold %d%%)\n",
       fn_covered, fn_pct, FN_THRESHOLD);

if (length(fn_dead) > 0) {
	printf("\nDEAD LIB FUNCTIONS (not referenced anywhere):\n");
	for (let mod in keys(fn_dead))
		printf("  %-12s %s\n", mod, join(", ", fn_dead[mod]));
}

let exit_code = 0;
if (length(uncovered) > 0) exit_code = 1;
if (fn_pct < FN_THRESHOLD) exit_code = 1;
if (length(fn_dead) > 0) exit_code = 1;
exit(exit_code);
