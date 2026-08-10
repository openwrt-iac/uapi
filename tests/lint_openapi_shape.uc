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

// `managed` is the same shape of mistake one field over: derived from uci's `.anonymous`,
// ignored by every toUci, and hardcoded to true on the write path, so a PUT sending
// `managed: false` answers 200 with `managed: true`. Emitted bare it reads as a writable
// boolean, so it lands in the request model of every generated client. It moves only
// through the adopt endpoint, so like `runtime` there is no resource needing an exception.
let managed_seen = 0;
for (let name in schemas) {
	let mg = schemas[name].properties?.managed;
	if (type(mg) != "object") continue;
	managed_seen++;
	if (mg.readOnly !== true)
		note(sprintf("/components/schemas/%s/properties/managed", name),
		     "must be readOnly: no toUci reads it and the write path forces it true, so a generator that puts it in the request model sends a field the server ignores");
}

// `deprecated: true` tells a generator THAT a field is going away; only the description can
// tell an operator why, and that text is what a provider surfaces in a plan warning. Eight
// fields shipped the flag with no reason attached, so the warning had nothing field-specific
// to say and downstream had to assemble a generic one from the changelog.
//
// Matched case-insensitively on purpose: `network/interfaces.name` opens "DEPRECATED in
// 2.2.0" and carries a perfectly good reason, so a literal-prefix rule would fail the one
// field that predates the convention.
let deprecated_seen = 0;
for (let name in schemas) {
	for (let prop in schemas[name].properties ?? {}) {
		let p = schemas[name].properties[prop];
		if (type(p) != "object" || p.deprecated !== true) continue;
		deprecated_seen++;
		let desc = p.description ?? "";
		let colon = index(desc, ":");
		if (substr(lc(desc), 0, 10) != "deprecated")
			note(sprintf("/components/schemas/%s/properties/%s", name, prop),
			     "is deprecated but its description does not open with \"Deprecated\": the flag says a field is going away, only the text says why");
		// The prefix alone satisfies the check above while telling an operator nothing, so
		// the reason after the colon is what is actually required. Every existing form has
		// one: "Deprecated, removed in v3: use macs" and "DEPRECATED in 2.2.0: use `id`".
		else if (colon < 0 || trim(substr(desc, colon + 1)) == "")
			note(sprintf("/components/schemas/%s/properties/%s", name, prop),
			     "is deprecated but states no reason: the description needs \"<notice>: <why>\", not the notice alone");
	}
}

// Every curated resource is described by two schemas, and a property a caller cannot write
// must not appear in the request half. Before v3 one schema served both directions, and the
// only way to keep `runtime` and `managed` out of a generated request model was a readOnly
// annotation the generator had to synthesise. The split states it structurally, and this is
// what keeps it stated: a request schema that regrows one of these is a request model that
// tells a client to send a field the server derives.
let halves = 0;
for (let name in schemas) {
	if (substr(name, -7) != "Request") continue;
	let base = substr(name, 0, length(name) - 7);
	if (!exists(schemas, base + "Response")) continue;
	halves++;
	let props = schemas[name].properties ?? {};
	for (let forbidden in [ "managed", "runtime" ])
		if (exists(props, forbidden))
			note(sprintf("/components/schemas/%s/properties/%s", name, forbidden),
			     "is derived by the server and must not appear in a request schema");
	for (let p in props)
		if (type(props[p]) == "object" && props[p].readOnly === true)
			note(sprintf("/components/schemas/%s/properties/%s", name, p),
			     "is readOnly, so it belongs in the response half only");

	// A `required` inside a conditional names keys on the instance and has no sibling
	// `properties`, so the structural walk above cannot check it and a request half can
	// require a field it does not declare. That shipped: the static-proto arm accepted
	// `ipaddr` alone, which is exactly the body the write path ignores, so a client
	// validating against the schema would send an address that never landed.
	for (let i = 0; i < length(schemas[name].allOf ?? []); i++) {
		let c = schemas[name].allOf[i];
		let groups = [];
		if (type(c.anyOf) == "array") push(groups, ...c.anyOf);
		if (type(c.then) == "object") {
			if (type(c.then.required) == "array") push(groups, c.then);
			if (type(c.then.anyOf) == "array") push(groups, ...c.then.anyOf);
		}
		for (let g in groups)
			for (let r in g.required ?? [])
				if (!exists(props, r))
					note(sprintf("/components/schemas/%s/allOf/%d", name, i),
					     sprintf("requires %J, which this half does not declare", r));
	}
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
	if (!m) continue;
	let k = match(line, /kind:[ \t]*"([^"]+)"/);
	curated[m[1]] = k ? k[1] : "crud";
}

function is_curated(p) {
	for (let base in keys(curated)) {
		if (p == base || p == base + "/{id}" || p == base + "/{id}/adopt") return true;
	}
	return false;
}

// The Request half is a codegen signal rather than decoration: a generated client reads a
// missing Request as "this resource is not writable, or has gone", which is what made the
// removal of vnstat/interfaces fail generation loudly instead of quietly. That inference only
// survives while both directions hold, so both are checked here.
function collect_refs(node, out) {
	if (type(node) != "object") return;
	if (type(node["$ref"]) == "string") {
		let m = match(node["$ref"], /^#\/components\/schemas\/(.+)$/);
		if (m) out[m[1]] = true;
	}
	for (let k in node) {
		let v = node[k];
		if (type(v) == "object") collect_refs(v, out);
		else if (type(v) == "array")
			for (let e in v) collect_refs(e, out);
	}
}

let body_refs = {};
let paths_for_body = spec.paths ?? {};
for (let p in paths_for_body)
	for (let verb in paths_for_body[p]) {
		let op = paths_for_body[p][verb];
		if (type(op) != "object" || type(op.requestBody) != "object") continue;
		collect_refs(op.requestBody, body_refs);
	}

let request_schemas = 0;
for (let name in schemas) {
	if (substr(name, -7) != "Request") continue;
	request_schemas++;
	if (!body_refs[name])
		note(sprintf("/components/schemas/%s", name),
		     "is a Request schema no request body references, so it describes a write that cannot happen");
}

// The reverse: a curated write that carries a body must name the Request half, or a client
// reading writability off the schema set sees a writable resource as read-only. Scoped to
// curated paths, since /raw/ and the auth and package endpoints have their own hand-written
// bodies, and only to verbs that actually take a body: `adopt` is a POST with none, which is
// correct rather than a gap.
let writable_bodies = 0;
for (let p in paths_for_body) {
	if (!is_curated(p)) continue;
	for (let verb in paths_for_body[p]) {
		if (verb != "post" && verb != "put" && verb != "patch") continue;
		let op = paths_for_body[p][verb];
		if (type(op) != "object" || type(op.requestBody) != "object") continue;
		writable_bodies++;
		let r = {}; collect_refs(op.requestBody, r);
		let named = false;
		for (let n in r) if (substr(n, -7) == "Request") named = true;
		if (!named)
			note(sprintf("/paths%s/%s/requestBody", p, verb),
			     "is a curated write body that references no *Request schema");
	}
}

// Direction is expressible as membership only while the Response is a superset of the Request:
// a generated client emits response-only fields as computed, so a request field the response
// omits would surface as an unsettable attribute, with no symptom in the document itself. This
// holds by construction for curated resources, whose request half is the response property map
// minus the response-only and readOnly entries, and this pins that rather than trusting it.
// The hand-written operation pairs are legitimately request-only in places (a token create
// sends scopes and gets back a token) and are not in the generator's endpoint catalog.
let superset_pairs = 0;
for (let name in schemas) {
	if (substr(name, -7) != "Request") continue;
	let base = substr(name, 0, length(name) - 7);
	if (!exists(schemas, base + "Response")) continue;
	if (!body_refs[name]) continue;
	let rq = schemas[name].properties ?? {};
	let rs = schemas[base + "Response"].properties ?? {};
	let generated = false;
	for (let p in curated) {
		let ref = paths_for_body[p]?.get?.responses?.["200"]?.content?.["application/json"]?.schema;
		let r = {};
		collect_refs(ref ?? {}, r);
		if (r[base + "Response"]) generated = true;
	}
	if (!generated) continue;
	superset_pairs++;
	for (let f in rq)
		if (!exists(rs, f))
			note(sprintf("/components/schemas/%s/properties/%s", name, f),
			     sprintf("is in the request half but not in %sResponse, so a generated client would emit it as computed and no one could set it", base));
}


// ETag comes from set_etag_header, which the curated CRUD and singleton handlers call and
// nothing else does. make_collection.get_one returns errors.ok bare, so a collection-kind
// resource is curated and still carries no ETag: "curated" alone is the wrong test, which
// is why this walks the catalog's `kind` rather than reusing is_curated().
function etag_expected(p, verb, code) {
	for (let base in keys(curated)) {
		let kind = curated[base];
		if (kind == "collection") {
			if (p == base || p == base + "/{id}") return false;
			continue;
		}
		if (kind == "singleton" && p == base)
			return (verb == "get") ? (code == "200" || code == "304")
			                       : (verb == "patch" && code == "200");
		if (kind != "crud") continue;
		if (p == base)
			return verb == "post" && code == "200";
		if (p == base + "/{id}")
			return (verb == "get") ? (code == "200" || code == "304")
			                       : ((verb == "put" || verb == "patch") && code == "200");
		if (p == base + "/{id}/adopt")
			return verb == "post" && code == "200";
	}
	return false;
}

let etag_responses = 0;
for (let p in paths) {
	for (let verb in paths[p]) {
		if (verb == "parameters") continue;
		for (let code in paths[p][verb]?.responses ?? {}) {
			let declared = exists(paths[p][verb].responses[code]?.headers ?? {}, "ETag");
			let want = etag_expected(p, verb, code);
			let where = sprintf("%s %s %s", uc(verb), p, code);
			if (declared && !want)
				note(where, "declares ETag, but set_etag_header is never reached on this response");
			else if (!declared && want)
				note(where, "emits an ETag and does not declare it");
			else if (declared) etag_responses++;
		}
	}
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
			// /batch commits and reloads once for the whole set, so its 207 carries the same
			// four headers, aggregated. It is not a curated-resource path, so it needs naming
			// here rather than falling into the "emits none of them" branch below.
			if (p == "/batch") {
				let want = (verb == "post" && code == "207");
				if (want && length(present) != length(TX_HEADERS))
					note(where, sprintf("the batch 207 declares %J; it emits all four, aggregated over the sub-writes", present));
				else if (!want && length(present) > 0)
					note(where, sprintf("declares %J, but only the batch 207 carries them", present));
			}
			else if (is_curated(p)) {
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

// X-Mgmt-Path-Warning is per-resource and per-verb: only a write on a resource whose module
// sets `mgmt_path_guard` can move the caller's own path. Each such resource declares it on
// its collection create and on all three item writes, which is what `attach_mgmt_warning`
// reaches. The create arm exists because a new section can claim the management device, and a
// bridge-vlan created on the management bridge is the write that took a box off the network
// with no warning at all.
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
// Two path keys per guarded resource: the collection carries the create, the item carries the
// three writes.
if (length(keys(mgmt_paths)) != guarded * 2)
	note("X-Mgmt-Path-Warning",
	     sprintf("%d resource(s) set mgmt_path_guard, so %d path(s) should declare the header; %d do",
	             guarded, guarded * 2, length(keys(mgmt_paths))));
for (let p in mgmt_paths) {
	let got = join(", ", sort(mgmt_paths[p]));
	let want = (substr(p, -5) == "/{id}") ? "delete 204, patch 200, put 200" : "post 200";
	if (got != want)
		note(p, sprintf("declares X-Mgmt-Path-Warning on %J; attach_mgmt_warning reaches %J on this path", got, want));
}

if (length(problems) > 0) {
	for (let p in problems) print(p + "\n");
	printf("FAIL: %d structural problem(s) in build/openapi.json\n", length(problems));
	exit(1);
}

printf("OK: %d schema nodes checked, %d conditionals, %d read-only runtimes, %d read-only managed, %d request/response pairs, %d deprecations with reasons, %d collections, %d transaction-header responses, %d etag responses, no structural problems\n",
       schemas_seen, conditionals_seen, runtime_seen, managed_seen, halves, deprecated_seen, collections, tx_responses, etag_responses);
