#!/usr/bin/ucode

// Structural checks over build/openapi.json that an OpenAPI validator does
// not make. Verified against openapi-spec-validator: a `required` naming a
// property the schema does not declare and an `if` with no `then` are both
// legal JSON Schema, so a conformance run passes them, yet each is a broken
// contract for the code generator the spec exists to feed. The NaN check is
// here because ucode's `+` on two arrays yields NaN rather than concatenating,
// which is how `enum: keys(X) + [null]` shipped an `enum` of "NaN".

import * as fs from 'fs';

function load_spec(path) {
	let f = fs.open(path, "r");
	if (!f) die(sprintf("cannot read %s", path));
	let raw = f.read("all") ?? "";
	f.close();
	return json(raw);
}

let spec = load_spec("build/openapi.json");
let problems = [];
let schemas_seen = 0, conditionals_seen = 0;

function note(path, msg) {
	push(problems, sprintf("%s: %s", path, msg));
}

// A schema node is anything that can carry `properties`/`required`/`if`. The
// walk is structural rather than driven by a list of known keywords, so a
// fragment nested inside allOf/oneOf/items is checked the same as a top-level
// component schema.
function check_schema(node, path) {
	schemas_seen++;

	// `required` is a list of property names on a Schema Object but a plain
	// boolean on a Parameter or Request Body Object, and both spellings are
	// correct in their own place, so the type picks the meaning.
	if (exists(node, "required") && type(node.required) == "array") {
		if (type(node.properties) == "object") {
			for (let i = 0; i < length(node.required); i++) {
				let r = node.required[i];
				if (type(r) != "string")
					note(sprintf("%s/required[%d]", path, i), "must be a string");
				else if (!exists(node.properties, r))
					note(sprintf("%s/required[%d]", path, i),
					     sprintf("names %J, which the schema does not declare", r));
			}
		}
	}
	else if (exists(node, "required") && type(node.required) != "bool")
		note(path + "/required", sprintf("must be a property list or a boolean, got %J", node.required));

	if (exists(node, "enum")) {
		if (type(node.enum) != "array")
			note(path + "/enum", sprintf("must be an array, got %J", node.enum));
		else if (length(node.enum) == 0)
			note(path + "/enum", "is empty, so nothing can validate against it");
	}

	// An `if` with no branch is silently inert: a generator reading it produces
	// no conditional requirement and the operator gets no hint either.
	if (exists(node, "if")) {
		conditionals_seen++;
		if (!exists(node, "then") && !exists(node, "else"))
			note(path + "/if", "has neither a then nor an else, so it constrains nothing");
	}
	if ((exists(node, "then") || exists(node, "else")) && !exists(node, "if"))
		note(path, "has a then/else with no if");
}

function walk(node, path) {
	if (type(node) == "array") {
		for (let i = 0; i < length(node); i++)
			walk(node[i], sprintf("%s[%d]", path, i));
		return;
	}
	if (type(node) != "object") {
		// ucode renders a NaN as the string "NaN" on encode, so an arithmetic
		// slip in a schema literal reaches the spec looking like a value.
		if (node === "NaN")
			note(path, "is the string \"NaN\", which means a ucode expression evaluated to NaN");
		return;
	}

	if (exists(node, "properties") || exists(node, "required") || exists(node, "enum")
	    || exists(node, "if") || exists(node, "then") || exists(node, "else"))
		check_schema(node, path);

	for (let k in node) {
		// The value of `properties` maps a property NAME to a schema, so it is
		// not itself a schema. Descending into it blindly would read a uci option
		// called "enum" or "required" as a keyword on the map and report a
		// contradiction that is not there.
		if (k == "properties" && type(node[k]) == "object") {
			for (let name in node[k])
				walk(node[k][name], sprintf("%s/properties/%s", path, name));
			continue;
		}
		walk(node[k], path + "/" + k);
	}
}

walk(spec, "");

if (length(problems) > 0) {
	for (let p in problems) print(p + "\n");
	printf("FAIL: %d structural problem(s) in build/openapi.json\n", length(problems));
	exit(1);
}

printf("OK: %d schema nodes checked, %d conditionals, no structural problems\n",
       schemas_seen, conditionals_seen);
