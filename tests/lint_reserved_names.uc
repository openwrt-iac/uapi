#!/usr/bin/ucode

// Walks build/openapi.json's component schemas and fails CI if any top-
// level property name collides with a Terraform reserved meta-argument or
// HCL block keyword. Reserved names cannot exist as top-level Terraform
// resource attributes; HCL block keywords work today but render the field
// quoted in HCL and trip code-gen tools.
//
// Allowlist intentionally empty. Anyone adding a reserved name has to
// either rename or add the field to the allowlist with a comment
// explaining the policy decision. The point is to make the choice
// deliberate.

import * as fs from 'fs';

const HARD = {
	"count": true,
	"for_each": true,
	"depends_on": true,
	"provider": true,
	"lifecycle": true,
	"connection": true,
	"provisioner": true,
};

const SOFT = {
	"output": true,
	"resource": true,
	"data": true,
	"module": true,
	"variable": true,
	"locals": true,
	"terraform": true,
};

// (schema_name, property_name) pairs we deliberately accept. Add entries
// with a comment naming the trade-off; reviewers should push back on any
// addition that isn't justified.
const ALLOWLIST = {};

function load_spec(path) {
	let f = fs.open(path, "r");
	if (!f) die(sprintf("cannot read %s", path));
	let raw = f.read("all") ?? "";
	f.close();
	return json(raw);
}

let spec = load_spec("build/openapi.json");
let schemas = spec.components?.schemas ?? {};
let hard_hits = [];
let soft_hits = [];

for (let name in schemas) {
	let s = schemas[name];
	let props = s.properties;
	if (type(props) != "object") continue;
	for (let prop in props) {
		let key = name + "." + prop;
		if (ALLOWLIST[key]) continue;
		if (HARD[prop])  push(hard_hits, key);
		else if (SOFT[prop]) push(soft_hits, key);
	}
}

if (length(hard_hits) > 0) {
	printf("FAIL: schema property names collide with Terraform meta-arguments\n");
	for (let h in hard_hits) printf("  %s\n", h);
	printf("\nThese names cannot exist as top-level Terraform resource attributes\n");
	printf("and will break a code-generated provider's schema validation.\n");
	printf("Rename the wire surface (uci option name can stay) and add a\n");
	printf("migration-guide entry under \"Wire-surface renames\".\n");
}

if (length(soft_hits) > 0) {
	printf("FAIL: schema property names collide with HCL block keywords\n");
	for (let h in soft_hits) printf("  %s\n", h);
	printf("\nThese names work as Terraform attributes but render quoted in\n");
	printf("HCL and trip linters. Either rename the wire surface or add the\n");
	printf("offender to tests/lint_reserved_names.uc::ALLOWLIST with a\n");
	printf("comment explaining the policy decision.\n");
}

let total = length(hard_hits) + length(soft_hits);
if (total > 0) exit(1);

printf("OK: %d schemas, no Terraform-reserved or HCL-keyword collisions\n",
       length(schemas));
