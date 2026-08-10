#!/usr/bin/ucode
// Two-granularity coverage: module presence in tests, and per-export
// function reference. Identifier matching is tokenized (non-identifier
// boundary on each side) to avoid `default_acquire` being "found" inside
// `default_acquire_pkg`. Production callers are scanned across src/ AND
// cli/; an export referenced only inside its own home file counts as
// internal-use coverage. Exit 1 on any uncovered module, any unit-test
// percentage below FN_THRESHOLD, or any dead export.

import * as fs from 'fs';

const FN_THRESHOLD = 80;
const IDENT = "A-Za-z0-9_";

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

// Regex-quote a name into a tokenized pattern: not preceded or followed by
// another identifier character. Matches the exact name only.
function token_re(name) {
	return regexp("(^|[^" + IDENT + "])" + name + "([^" + IDENT + "]|$)");
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

function extract_exports(src) {
	let m = match(src, /return\s*\{([^}]*)\}\s*;?\s*$/);
	if (!m) return [];
	let names = {};
	for (let chunk in split(m[1], ",")) {
		let s = trim(chunk);
		if (s == "") continue;
		let colon = index(s, ":");
		if (colon >= 0) s = trim(substr(s, 0, colon));
		if (match(s, /^[A-Za-z_][A-Za-z0-9_]*$/))
			names[s] = true;
	}
	return keys(names);
}

let production_bodies = {};
function add_dir(dir) {
	for (let f in list(dir)) {
		let path = dir + "/" + f;
		let body = read_all(path);
		if (body != "") production_bodies[path] = body;
	}
}
function add_file(path) {
	let body = read_all(path);
	if (body != "") production_bodies[path] = body;
}
add_dir("src");
add_dir("src/lib");
add_dir("src/resources");
add_file("cli/uapi-token");

function used_in_production(module_name, fn_name, own_file) {
	let re = token_re(module_name + "\\." + fn_name);
	for (let path in keys(production_bodies)) {
		if (path == own_file) continue;
		if (match(production_bodies[path], re)) return path;
	}
	return null;
}

// A test that uses `let alias = require('module')` then `alias.name(...)`
// counts as direct test coverage. The `.` is the left token boundary (any
// identifier char preceding it is part of the alias, not the name); we
// require non-identifier on the right only.
function tested_via_alias(module_name, fn_name) {
	let re = regexp("\\." + fn_name + "([^" + IDENT + "]|$)");
	for (let f in keys(test_bodies)) {
		let body = test_bodies[f];
		if (index(body, "require('" + module_name + "')") < 0
		    && index(body, "src/lib/" + module_name + ".uc") < 0) continue;
		if (match(body, re)) return true;
	}
	return false;
}

// An export referenced inside its own module outside its declaration line
// (`function name(...)` or `name = function(...)`) is internally used.
// The module's own export block names every export, so scanning it counts a declaration
// as a use and no export can ever look dead. That made the dead-export gate below
// unreachable: exit_code was set on a list that was always empty. Strip the block first.
// Line-scanned rather than regexed: ucode matches POSIX ERE, where `\s` is not a class,
// so a `[\s\S]` pattern here silently matched nothing and left the block in place.
function without_export_block(src) {
	let lines = split(src, "\n");
	let cut = -1;
	for (let i = 0; i < length(lines); i++)
		if (match(lines[i], /^return[ \t]*\{/)) cut = i;
	if (cut < 0) return src;
	let kept = [];
	for (let i = 0; i < cut; i++) push(kept, lines[i]);
	return join("\n", kept);
}

function used_internally(src, name) {
	let token_in_line = regexp("(^|[^" + IDENT + "])" + name + "([^" + IDENT + "]|$)");
	let def_lhs = regexp("^[[:space:]]*function[[:space:]]+" + name + "[[:space:]]*\\(");
	let def_assign = regexp("^[[:space:]]*(let[[:space:]]+|const[[:space:]]+)?" + name + "[[:space:]]*=[[:space:]]*function");
	for (let line in split(src, "\n")) {
		if (!match(line, token_in_line)) continue;
		if (match(line, def_lhs)) continue;
		if (match(line, def_assign)) continue;
		return true;
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
		           || used_internally(without_export_block(src), name)) {
			fn_prod_only++;
		} else {
			push(dead, name);
		}
	}
	if (length(dead) > 0) fn_dead[m.name] = dead;
}

let unit_pct = (fn_total > 0) ? (fn_unit * 100.0) / fn_total : 100.0;
let fn_covered = fn_unit + fn_prod_only;
let fn_pct = (fn_total > 0) ? (fn_covered * 100.0) / fn_total : 100.0;

printf("uapi coverage inventory\n");
printf("=======================\n");
printf("modules total:        %d\n", length(modules));
printf("modules covered:      %d (%.1f%%)\n", covered, (covered * 100.0) / length(modules));
printf("modules uncovered:    %d\n\n", length(uncovered));

if (length(uncovered) > 0) {
	printf("UNCOVERED MODULES:\n");
	for (let m in uncovered)
		printf("  %-8s %s\n", m.kind, m.file);
	printf("\n");
}

printf("lib exports total:                %d\n", fn_total);
printf("  unit-tested directly:           %d (%.1f%%; threshold %d%%)\n",
       fn_unit, unit_pct, FN_THRESHOLD);
printf("  exercised via production calls: %d\n", fn_prod_only);
printf("  total covered:                  %d (%.1f%%)\n", fn_covered, fn_pct);

if (length(fn_dead) > 0) {
	printf("\nDEAD LIB EXPORTS (not referenced anywhere):\n");
	for (let mod in keys(fn_dead))
		printf("  %-12s %s\n", mod, join(", ", fn_dead[mod]));
}

// The module-local counterpart of the check above. A file that stops using a helper keeps
// importing it, and nothing notices: removing `mwan3/globals.rtmon_interval` in 3.0.0 left
// `as_int` bound and unread. A major that deletes fields produces this rot in bulk, and the
// binding is the only surviving evidence of a field that no longer exists.
let dead_imports = {};
for (let dir in [ "src/resources", "src/lib" ]) {
	for (let f in list(dir)) {
		if (!match(f, /\.uc$/)) continue;
		let path = dir + "/" + f;
		let body = read_all(path);
		let dead = [];
		for (let line in split(body, "\n")) {
			let m = match(line, /^let[ \t]+([A-Za-z0-9_]+)[ \t]*=[ \t]*[A-Za-z0-9_]+\.[A-Za-z0-9_]+;/);
			if (m == null) continue;
			let uses = 0;
			for (let l2 in split(body, "\n"))
				if (l2 != line && match(l2, token_re(m[1]))) uses++;
			if (uses == 0) push(dead, m[1]);
		}
		if (length(dead) > 0) dead_imports[path] = dead;
	}
}

if (length(dead_imports) > 0) {
	printf("\nDEAD MODULE IMPORTS (bound, never read):\n");
	for (let p in keys(dead_imports))
		printf("  %-46s %s\n", p, join(", ", dead_imports[p]));
}

let exit_code = 0;
if (length(uncovered) > 0) exit_code = 1;
if (unit_pct < FN_THRESHOLD) exit_code = 1;
if (length(fn_dead) > 0) exit_code = 1;
if (length(dead_imports) > 0) exit_code = 1;
exit(exit_code);
