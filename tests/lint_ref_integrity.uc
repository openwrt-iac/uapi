#!/usr/bin/ucode

// Walk every $ref string in build/openapi.json and assert the target
// component exists. Catches dangling refs (e.g. renaming a header
// component on one side of the file without updating the other) that
// OpenAPI viewers silently render as empty.

import * as fs from 'fs';

function load_spec(path) {
	let f = fs.open(path, "r");
	if (!f) die(sprintf("cannot read %s", path));
	let raw = f.read("all") ?? "";
	f.close();
	return json(raw);
}

let spec = load_spec("build/openapi.json");
let components = spec.components ?? {};
let missing = [];

function walk(node, path) {
	if (type(node) == "array") {
		for (let i = 0; i < length(node); i++)
			walk(node[i], path + "[" + i + "]");
		return;
	}
	if (type(node) != "object") return;
	if (type(node["$ref"]) == "string") {
		let ref = node["$ref"];
		// Local component refs only; external $refs (URLs) are out of scope.
		const PREFIX = "#/components/";
		if (substr(ref, 0, length(PREFIX)) == PREFIX) {
			let parts = split(substr(ref, length(PREFIX)), "/");
			let target = components;
			for (let p in parts) {
				if (type(target) != "object" || target[p] == null) {
					target = null; break;
				}
				target = target[p];
			}
			if (target == null) push(missing, { ref, at: path });
		}
	}
	for (let k in node) walk(node[k], path + "." + k);
}

walk(spec, "$");

if (length(missing) > 0) {
	printf("FAIL: %d dangling $ref(s) in build/openapi.json\n\n", length(missing));
	for (let m in missing)
		printf("  %s -> %s\n", m.at, m.ref);
	printf("\nThe referenced component name does not exist under spec.components.\n");
	printf("Either fix the $ref string or add the missing component definition.\n");
	exit(1);
}

printf("OK: every $ref under #/components/ resolves\n");
