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

// `runtime` is derived from ubus and toUci ignores it, so it is never writable
// on any resource. An un-annotated `type: object` reads to a code generator as
// an ordinary writable free-form map, which is how 42 of 45 schemas came to
// advertise a writable runtime: the annotation was applied where the shape was
// documented rather than everywhere the property is emitted. There is no
// resource for which the rule needs an exception, so it needs no allowlist.
let runtime_seen = 0;
let schemas = spec.components?.schemas ?? {};
for (let name in schemas) {
	let rt = schemas[name].properties?.runtime;
	if (type(rt) != "object") continue;
	runtime_seen++;
	if (rt.readOnly !== true)
		note(sprintf("/components/schemas/%s/properties/runtime", name),
		     "must be readOnly: a generator reads an un-annotated object as writable, and no resource accepts a runtime");
}

// A collection segment names a set, so it reads plural, and every curated one
// is the plural of its uci section type. The exceptions below are decisions,
// not oversights, and each became load-bearing the moment it shipped: the path,
// the scope name and the schema name all appear in released clients. A new
// singular collection that is not listed here is a mistake, which is the point
// of failing rather than warning.
//
// A collection is identified structurally, by having a sibling {id} path, so
// this needs no guesswork about what a resource is called.
const SINGULAR_COLLECTIONS = {
	"/firewall/nat": "\"nats\" reads badly; `nat` matches the uci section type and LuCI",
	"/dhcp/leases6": "\"leases\" plus a family suffix; already plural",
	"/raw/{package}": "passthrough, not a curated collection",
};

let paths = spec.paths ?? {};
let collections = 0;
for (let p in paths) {
	if (!exists(paths, p + "/{id}")) continue;
	collections++;
	if (exists(SINGULAR_COLLECTIONS, p)) continue;
	let seg = split(p, "/")[-1];
	if (substr(seg, -1) != "s")
		note(p, sprintf("collection segment %J is singular; make it plural, or add it to SINGULAR_COLLECTIONS with the reason", seg));
}

// Emitted headers have to be declared on the responses that can carry them and nowhere
// else. Three of them were emitted by the code and declared nowhere at all, which a
// generated client cannot see; the opposite error is just as invisible, and the tree
// already carries one (`X-Reload-Status` is declared on raw, non-uci and batch writes,
// which never reach the reload machinery). Both rules below are derived from the sources
// rather than from a list kept by hand, so a fourth header cannot be added quietly.
//
// The four transaction headers travel together and reach only curated-resource writes.
// The curated path set is derived from the generator's own ENDPOINTS catalog, so a new
// resource is covered automatically and a header attached to the wrong block is caught in
// both directions: declared where it cannot be emitted, or missing where it is.
//
// The over-declaration half is not hypothetical. `X-Reload-Status` was declared on 15 raw,
// batch and non-uci write responses that emit nothing, which is as invisible to a generated
// client as the opposite error.
const TX_HEADERS = [ "X-Reload-Status", "X-Reload-Services", "X-Kernel-Status", "X-Kernel-Applied" ];

let gen = "";
let gh = fs.open("build/gen_openapi.uc", "r");
if (gh) { gen = gh.read("all") ?? ""; gh.close(); }
let cat_start = index(gen, "const ENDPOINTS = [");
let cat_end = index(gen, "\n];", cat_start);
if (cat_start < 0 || cat_end < 0)
	note("build/gen_openapi.uc", "cannot find the ENDPOINTS catalog, so the transaction-header scope is unchecked");
let catalog = substr(gen, cat_start, cat_end - cat_start);
let curated = {};
for (let line in split(catalog, "\n")) {
	let m = match(line, /path:[ \t]*"([^"]+)"/);
	if (m) curated[m[1]] = true;
}

function is_curated(p) {
	for (let base in keys(curated)) {
		if (p == base || p == base + "/{id}" || p == base + "/{id}/adopt") return true;
	}
	return false;
}

let tx_responses = 0;
for (let p in paths) {
	for (let verb in paths[p]) {
		if (verb == "parameters" || verb == "get") continue;
		for (let code in paths[p][verb]?.responses ?? {}) {
			if (substr(code, 0, 1) != "2") continue;
			let h = paths[p][verb].responses[code]?.headers ?? {};
			let present = [];
			for (let n in TX_HEADERS) if (exists(h, n)) push(present, n);
			let where = sprintf("%s %s %s", uc(verb), p, code);
			if (is_curated(p)) {
				if (length(present) == 0)
					note(where, "a curated-resource write declares none of the transaction headers; it emits all four");
				else if (length(present) != length(TX_HEADERS))
					note(where, sprintf("declares only %J of the four transaction headers, which attach_reload_headers sets together", present));
				else tx_responses++;
			} else if (length(present) > 0) {
				note(where, sprintf("declares %J, but this is not a curated-resource write and never reaches attach_reload_headers", present));
			}
		}
	}
}
if (length(keys(curated)) == 0)
	note("build/gen_openapi.uc", "the ENDPOINTS catalog parsed to zero paths, so the check above proved nothing");

// X-Mgmt-Path-Warning is per-resource and per-verb: only an item write on a resource whose
// module sets `mgmt_path_guard` can move the interface the request arrived through.
let guarded = 0;
for (let f in fs.lsdir("src/resources", "*.uc") ?? []) {
	let fh = fs.open("src/resources/" + f, "r");
	if (!fh) continue;
	let text = fh.read("all") ?? "";
	fh.close();
	if (index(text, "mgmt_path_guard") >= 0) guarded++;
}
let mgmt_paths = {};
for (let p in paths) {
	for (let verb in paths[p]) {
		if (verb == "parameters") continue;
		for (let code in paths[p][verb]?.responses ?? {}) {
			if (!exists(paths[p][verb].responses[code]?.headers ?? {}, "X-Mgmt-Path-Warning")) continue;
			if (mgmt_paths[p] == null) mgmt_paths[p] = [];
			push(mgmt_paths[p], sprintf("%s %s", verb, code));
		}
	}
}
if (length(keys(mgmt_paths)) != guarded)
	note("X-Mgmt-Path-Warning",
	     sprintf("%d resource(s) set mgmt_path_guard but the header is declared on %d path(s)",
	             guarded, length(keys(mgmt_paths))));
for (let p in mgmt_paths) {
	let got = join(", ", sort(mgmt_paths[p]));
	if (got != "delete 204, patch 200, put 200")
		note(p, sprintf("declares X-Mgmt-Path-Warning on %J; attach_mgmt_warning reaches only PUT 200, PATCH 200 and DELETE 204", got));
}

if (length(problems) > 0) {
	for (let p in problems) print(p + "\n");
	printf("FAIL: %d structural problem(s) in build/openapi.json\n", length(problems));
	exit(1);
}

printf("OK: %d schema nodes checked, %d conditionals, %d read-only runtimes, %d collections, %d transaction-header responses, no structural problems\n",
       schemas_seen, conditionals_seen, runtime_seen, collections, tx_responses);
