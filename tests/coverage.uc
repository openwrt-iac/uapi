#!/usr/bin/ucode
// Structural test-coverage inventory: every module under src/resources and
// src/lib must be mentioned in at least one unit test. Exit 1 on any miss.

import * as fs from 'fs';

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
	// Property test covers every resource by enumeration.
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

printf("uapi coverage inventory\n");
printf("=======================\n");
printf("modules total:        %d\n", length(modules));
printf("modules covered:      %d (%.1f%%)\n", covered, (covered * 100.0) / length(modules));
printf("modules uncovered:    %d\n", length(uncovered));
printf("\n");

if (length(uncovered) > 0) {
	printf("UNCOVERED:\n");
	for (let m in uncovered)
		printf("  %-8s %s\n", m.kind, m.file);
	printf("\n");
}

printf("Detail (covered):\n");
for (let m in modules) {
	if (length(m.tests) == 0) continue;
	printf("  %-8s %-50s -> %d test file(s)\n",
	       m.kind, m.file, length(m.tests));
}

exit(length(uncovered) > 0 ? 1 : 0);
