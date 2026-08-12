#!/usr/bin/ucode

// A read answers null for any uci option the operator never set, so a response schema that
// declares a bare scalar type is claiming something the code does not do. 105 properties across
// 32 modules were doing exactly that: `firewall/defaults.synflood_rate` was `integer` while an
// unconfigured box returned null, and a client generated from the document could not parse the
// response it was handed. The array equivalents were widened by hand for 3.0.0 and the scalars
// were missed, which is the argument for deriving this from the code instead of a list.
//
// The check calls each resource's real fromUci on a bare section and demands that whatever comes
// back null is null-permitted in that resource's Response schema. It cannot see a property that
// is conditionally absent rather than null (network/interfaces omits its dhcp keys entirely for
// a static interface, so a bare section never produces them); those carry the marker on the
// evidence of live response bodies, and this gate only holds the line it can prove.

import * as fs from 'fs';

function read_all(path) {
	let f = fs.open(path, "r");
	if (!f) die(sprintf("cannot read %s", path));
	let s = f.read("all") ?? "";
	f.close();
	return s;
}

function pascal(s) {
	let out = "";
	for (let p in split(s, /[._-]/))
		if (length(p) > 0) out += uc(substr(p, 0, 1)) + substr(p, 1);
	return out;
}

function permits_null(prop) {
	if (type(prop) != "object") return false;
	let t = prop.type;
	if (t == null) return true;
	if (type(t) == "string") return t == "null";
	if (type(t) == "array") {
		for (let x in t) if (x == "null") return true;
		return false;
	}
	return true;
}

let spec = json(read_all("build/openapi.json"));
let schemas = spec.components.schemas;
let problems = [];
let checked = 0, resources = 0;

let files = fs.lsdir("src/resources") ?? [];
sort(files);
for (let f in files) {
	if (!match(f, /\.uc$/)) continue;
	let base = replace(f, /\.uc$/, "");
	let dot = index(base, ".");
	let name = pascal((dot >= 0) ? substr(base, 0, dot) : base)
	         + pascal((dot >= 0) ? substr(base, dot + 1) : "");

	let mod;
	try { mod = loadfile("src/resources/" + f)(); }
	catch (e) { push(problems, sprintf("%s: cannot load (%s)", f, e)); continue; }
	if (type(mod) != "object" || type(mod.fromUci) != "function") continue;

	let sname = name + "Response";
	let schema = schemas[sname];
	if (type(schema) != "object" || type(schema.properties) != "object") continue;
	resources++;

	let view;
	try { view = mod.fromUci({ '.name': "probe", '.type': mod.type ?? "probe", '.anonymous': false }, null); }
	catch (e) { push(problems, sprintf("%s: fromUci died on a bare section (%s)", f, e)); continue; }
	if (type(view) != "object") continue;

	for (let k in view) {
		if (view[k] != null) continue;
		let prop = schema.properties[k];
		if (type(prop) != "object") continue;
		checked++;
		if (!permits_null(prop))
			push(problems, sprintf("%s.%s reads null but %s declares type %J",
			                       f, k, sname, prop.type));
		// A null value does not satisfy an enum that omits null, so a widened type alone
		// still leaves the schema rejecting its own response body.
		if (type(prop.enum) == "array") {
			let has = false;
			for (let x in prop.enum) if (x == null) has = true;
			if (!has)
				push(problems, sprintf("%s.%s reads null but %s's enum omits null",
				                       f, k, sname));
		}
	}
}

if (length(problems) > 0) {
	printf("response nullability: %d problem(s)\n", length(problems));
	for (let p in problems) printf("  %s\n", p);
	exit(1);
}

printf("response nullability: %d null-valued reads across %d resources, all permitted\n",
       checked, resources);
