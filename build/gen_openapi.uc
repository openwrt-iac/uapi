#!/usr/bin/ucode

'use strict';

push(REQUIRE_SEARCH_PATH, "./src/lib/*.uc");

let fs = require('fs');
let errors_mod = require('errors');

function read_version() {
	let f = fs.open("VERSION", "r");
	if (!f) die("VERSION file not found at repo root");
	let v = trim(f.read("all") ?? "");
	f.close();
	if (v == "") die("VERSION file is empty");
	return v;
}

const VERSION = read_version();

const ENDPOINTS = [
	{ path: "/firewall/rules",        file: "firewall.rules.uc",        kind: "crud", domain: "firewall", subresource: "rules" },
	{ path: "/firewall/zones",        file: "firewall.zones.uc",        kind: "crud", domain: "firewall", subresource: "zones" },
	{ path: "/firewall/redirects",    file: "firewall.redirects.uc",    kind: "crud", domain: "firewall", subresource: "redirects" },
	// Deliberately singular, and the only curated collection that is. Every
	// other segment is the plural of its uci section type, but "nats" reads
	// badly and "nat_rules" would diverge from `config nat`, which is also what
	// LuCI calls it. The path, the `firewall:nat` scope and the FirewallNat
	// schema all became load-bearing at 2.4.0, so this is not a wart to tidy up
	// later; lint_openapi_shape.uc allowlists it so the exception stays a
	// recorded decision rather than a thing someone renames on sight.
	{ path: "/firewall/nat",          file: "firewall.nat.uc",          kind: "crud", domain: "firewall", subresource: "nat" },
	{ path: "/firewall/forwardings",  file: "firewall.forwardings.uc",  kind: "crud", domain: "firewall", subresource: "forwardings" },
	{ path: "/firewall/defaults",     file: "firewall.defaults.uc",     kind: "singleton", domain: "firewall", subresource: "defaults" },
	{ path: "/network/interfaces",       file: "network.interfaces.uc",       kind: "crud", domain: "network", subresource: "interfaces" },
	{ path: "/network/devices",          file: "network.devices.uc",          kind: "crud", domain: "network", subresource: "devices" },
	{ path: "/network/routes",           file: "network.routes.uc",           kind: "crud", domain: "network", subresource: "routes" },
	{ path: "/network/rules",            file: "network.rules.uc",            kind: "crud", domain: "network", subresource: "rules" },
	{ path: "/network/bridge_vlans",     file: "network.bridge_vlans.uc",     kind: "crud", domain: "network", subresource: "bridge_vlans" },
	{ path: "/network/wireguard_peers",  file: "network.wireguard_peers.uc",  kind: "crud", domain: "network", subresource: "wireguard_peers" },
	{ path: "/wireless/devices",    file: "wireless.devices.uc",    kind: "crud", domain: "wireless", subresource: "devices" },
	{ path: "/wireless/interfaces", file: "wireless.interfaces.uc", kind: "crud", domain: "wireless", subresource: "interfaces" },
	{ path: "/dhcp/hosts",          file: "dhcp.hosts.uc",          kind: "crud", domain: "dhcp",     subresource: "hosts" },
	{ path: "/dhcp/leases",         file: "dhcp.leases.uc",         kind: "collection", domain: "dhcp", subresource: "leases" },
	{ path: "/dhcp/leases6",        file: "dhcp.leases6.uc",        kind: "collection", domain: "dhcp", subresource: "leases6" },
	{ path: "/dhcp/servers",        file: "dhcp.servers.uc",        kind: "crud",       domain: "dhcp", subresource: "servers" },
	{ path: "/dhcp/dnsmasq",        file: "dhcp.dnsmasq.uc",        kind: "singleton",  domain: "dhcp", subresource: "dnsmasq" },
	{ path: "/dhcp/odhcpd",         file: "dhcp.odhcpd.uc",         kind: "singleton",  domain: "dhcp", subresource: "odhcpd" },
	{ path: "/system",              file: "system.uc",              kind: "singleton", domain: "system" },
	{ path: "/system/timeservers",  file: "system.timeservers.uc",  kind: "crud",      domain: "system",   subresource: "timeservers" },
	{ path: "/dropbear/instances",  file: "dropbear.instances.uc",  kind: "crud",      domain: "dropbear", subresource: "instances" },
	{ path: "/uhttpd/instances",    file: "uhttpd.instances.uc",    kind: "crud",      domain: "uhttpd",   subresource: "instances" },
	{ path: "/uhttpd/certs",        file: "uhttpd.certs.uc",        kind: "crud",      domain: "uhttpd",   subresource: "certs" },
	{ path: "/unbound/server",      file: "unbound.server.uc",      kind: "singleton", domain: "unbound",  subresource: "server" },
	{ path: "/unbound/srv",         file: "unbound.srv.uc",         kind: "singleton", domain: "unbound",  subresource: "srv" },
	{ path: "/unbound/ext",         file: "unbound.ext.uc",         kind: "singleton", domain: "unbound",  subresource: "ext" },
	{ path: "/sqm/queues",          file: "sqm.queues.uc",          kind: "crud",      domain: "sqm",      subresource: "queues" },
	{ path: "/snmpd/agents",        file: "snmpd.agents.uc",        kind: "crud",      domain: "snmpd",    subresource: "agents" },
	{ path: "/snmpd/com2secs",      file: "snmpd.com2secs.uc",      kind: "crud",      domain: "snmpd",    subresource: "com2secs" },
	{ path: "/snmpd/groups",        file: "snmpd.groups.uc",        kind: "crud",      domain: "snmpd",    subresource: "groups" },
	{ path: "/snmpd/accesses",      file: "snmpd.accesses.uc",      kind: "crud",      domain: "snmpd",    subresource: "accesses" },
	{ path: "/snmpd/system",        file: "snmpd.system.uc",        kind: "singleton", domain: "snmpd",    subresource: "system" },
	{ path: "/lldpd/config",        file: "lldpd.config.uc",        kind: "singleton", domain: "lldpd",    subresource: "config" },
	{ path: "/prometheus_node_exporter_lua/config", file: "prometheus_node_exporter_lua.config.uc", kind: "singleton", domain: "prometheus_node_exporter_lua", subresource: "config" },
	{ path: "/vnstat/config",       file: "vnstat.config.uc",       kind: "singleton", domain: "vnstat",   subresource: "config" },
	{ path: "/mwan3/globals",       file: "mwan3.globals.uc",       kind: "singleton", domain: "mwan3",    subresource: "globals" },
	{ path: "/mwan3/interfaces",    file: "mwan3.interfaces.uc",    kind: "crud",      domain: "mwan3",    subresource: "interfaces" },
	{ path: "/mwan3/members",       file: "mwan3.members.uc",       kind: "crud",      domain: "mwan3",    subresource: "members" },
	{ path: "/mwan3/policies",      file: "mwan3.policies.uc",      kind: "crud",      domain: "mwan3",    subresource: "policies" },
	{ path: "/mwan3/rules",         file: "mwan3.rules.uc",         kind: "crud",      domain: "mwan3",    subresource: "rules" },
	{ path: "/usteer/config",       file: "usteer.config.uc",       kind: "singleton", domain: "usteer",   subresource: "config" },
	{ path: "/openvpn/instances",   file: "openvpn.instances.uc",   kind: "crud",      domain: "openvpn",  subresource: "instances" },
];

function load_resource(file) {
	return loadfile("./src/resources/" + file, { raw_mode: true })();
}

function pascal(s) {
	let parts = split(s, /[._-]/);
	let out = "";
	for (let p in parts) {
		if (length(p) > 0)
			out += uc(substr(p, 0, 1)) + substr(p, 1);
	}
	return out;
}

// One schema served both directions until v3, which is why `ipaddr` had to be described in
// prose rather than as readOnly, why `tag` kept `string` in its type for writers although
// responses were always an array, and why `runtime` and `managed` needed a readOnly annotation
// to stay out of a generated request model. Split, each half simply says what it is.
function schema_name(endpoint) {
	return pascal(endpoint.domain) + pascal(endpoint.subresource ?? "");
}

function request_name(endpoint) { return schema_name(endpoint) + "Request"; }
function response_name(endpoint) { return schema_name(endpoint) + "Response"; }

// A property a caller cannot write. Derived from uci or from ubus, ignored by every toUci, and
// present only so a reader can see it. `id` is deliberately not here: it is the section name at
// create, the universal input that replaced `network/interfaces.name`.
const RESPONSE_ONLY = { "runtime": true, "managed": true };

const READ_NULLABLE = "x-uapi-read-nullable";

function strip_marker(v) {
	if (type(v) != "object" || !exists(v, READ_NULLABLE)) return v;
	let out = { ...v };
	delete out[READ_NULLABLE];
	return out;
}

// The two halves disagree about null on purpose, because reading and writing a uci option are
// not symmetric: fromUci answers null for an option the operator never set, while the write
// contract still wants the value. A property marked READ_NULLABLE is one a read can answer
// null for, so only the response type admits it.
//
// The marker is deliberately not just `type: [..., "null"]` in schema_properties. That
// declaration feeds both halves, and 21 of the properties needing this are `required` on
// write while 26 carry an enum; widening there would make `{"target": null}` schema-valid on
// a create and leave resource.validate() as the only thing between that and a rule with no
// target. Response-only keeps the write surface exactly as it shipped.
function widen_null(v) {
		let w = strip_marker(v);
		if (type(w.type) == "string") {
			w.type = [ w.type, "null" ];
		} else if (type(w.type) == "array") {
			let t = [ ...w.type ];
			let has = false;
			for (let x in t) if (x == "null") has = true;
			if (!has) push(t, "null");
			w.type = t;
		}
		// A null value does not satisfy an enum that does not list it, so an enumerated
		// property needs both widened or the response schema still rejects its own body.
		if (type(w.enum) == "array") {
			let e = [ ...w.enum ];
			let has = false;
			for (let x in e) if (x == null) has = true;
			if (!has) push(e, null);
			w.enum = e;
		}
		return w;
}

function response_properties(properties) {
	let out = {};
	for (let k in properties) {
		let v = properties[k];
		out[k] = (type(v) == "object" && v[READ_NULLABLE] === true) ? widen_null(v) : v;
	}
	return out;
}

function request_properties(properties) {
	let out = {};
	for (let k in properties) {
		if (RESPONSE_ONLY[k]) continue;
		let v = properties[k];
		// readOnly loses its job here: the property is simply absent from this half.
		if (type(v) == "object" && v.readOnly === true) continue;
		// Both halves widen, because a read-modify-write sends the read view back: a live
		// firewall rule answers with ten null-valued keys, and a request schema that forbade
		// them described that round trip as invalid while the server answered 200 to it.
		// The type is not what guards a required field anyway; resource.validate() is, and it
		// answers 422 naming the field for a null `target` on a create.
		out[k] = (type(v) == "object" && v[READ_NULLABLE] === true) ? widen_null(v)
		                                                            : strip_marker(v);
	}
	return out;
}

function all_declared(names, props) {
	for (let n in names)
		if (!exists(props, n)) return false;
	return true;
}

function keep_arms(arms, props, where) {
	let out = [];
	for (let a in arms) {
		if (type(a) != "object" || type(a.required) != "array")
			die(sprintf("%s openapi_conditional: anyOf arms must be { required: [...] }", where));
		if (all_declared(a.required, props)) push(out, a);
	}
	return out;
}

// A `required` inside an `if`/`then` or a bare `anyOf` names keys on the instance and has no
// sibling `properties` to be checked against, which is why the shape lint cannot see it and why
// the request half inherited arms naming fields it does not declare. `proto: static` was
// satisfiable by `ipaddr` alone, so the request schema blessed the one body the write path
// ignores outright: a client validating against it would send an address that never lands.
// Nested requirements under a `properties` block are keyed inside that property, not on the
// instance, so they are left alone. Unrecognised shapes stop the build rather than being copied
// through unexamined.
function project_conditional(conditional, props, where) {
	let out = [];
	for (let c in conditional) {
		if (type(c.anyOf) == "array") {
			let arms = keep_arms(c.anyOf, props, where);
			if (length(arms) == 0) continue;
			push(out, { ...c, anyOf: arms });
			continue;
		}
		if (type(c.then) != "object")
			die(sprintf("%s openapi_conditional: entry needs a `then` object or a top-level `anyOf`, got %J", where, c));
		let t = c.then, kept;
		if (type(t.anyOf) == "array") {
			let arms = keep_arms(t.anyOf, props, where);
			// Every arm gone means nothing in the group is writable, so the whole
			// conditional goes: an empty anyOf validates nothing at all.
			if (length(arms) == 0) continue;
			kept = { ...t, anyOf: arms };
		}
		else if (type(t.required) == "array") {
			if (!all_declared(t.required, props)) continue;
			kept = t;
		}
		// Constrains a sub-object only. Those requirements are keyed inside that
		// property rather than on the instance, so this projection has no say over them.
		else if (type(t.properties) == "object") kept = t;
		else die(sprintf("%s openapi_conditional: unsupported `then` shape %J", where, t));
		push(out, { ...c, then: kept });
	}
	return out;
}

// uhttpd's CGI env forwards a hard-coded allowlist of headers, and `If-Match`, `If-None-Match`
// and `Idempotency-Key` are not on it, which is why each has a query-string fallback. The
// fallbacks were described in prose and declared nowhere, so a generated client sent the header,
// had it stripped before uapi saw it, and got no conditional write and no idempotency with no
// error to say so. Declaring them is what makes the features reachable without hand-written code.
const Q_IF_MATCH = {
	"name": "if_match", "in": "query", "required": false,
	"schema": { "type": "string" },
	"description": "ETag precondition, equivalent to the `If-Match` header. Required instead of the header when uapi is reached directly through uhttpd, whose CGI env strips it.",
};
const Q_IF_NONE_MATCH = {
	"name": "if_none_match", "in": "query", "required": false,
	"schema": { "type": "string" },
	"description": "Equivalent to the `If-None-Match` header, which uhttpd's CGI env strips. `*` matches any existing resource.",
};
const Q_IDEMPOTENCY_KEY = {
	"name": "idempotency_key", "in": "query", "required": false,
	"schema": { "type": "string" },
	"description": "Equivalent to the `Idempotency-Key` header, which uhttpd's CGI env strips. Replays the cached response for 24 h; the same key with a different body gives 409.",
};

function pretty(s) {
	let parts = split(s, /[._-]/);
	let out = [];
	for (let p in parts) {
		if (length(p) > 0) push(out, uc(substr(p, 0, 1)) + substr(p, 1));
	}
	return join(" ", out);
}

function tag_for(ep) {
	if (ep.subresource != null && ep.subresource != "")
		return pretty(ep.domain) + " / " + pretty(ep.subresource);
	return pretty(ep.domain);
}

function tag_ops(paths_dict, tag) {
	for (let p in paths_dict) {
		for (let verb in paths_dict[p]) {
			if (type(paths_dict[p][verb]) != "object") continue;
			paths_dict[p][verb].tags = [tag];
		}
	}
	return paths_dict;
}

const VALID_VERBS = { get: 1, post: 1, put: 1, patch: 1, delete: 1 };

function error_responses(verb) {
	if (!VALID_VERBS[verb])
		die(sprintf("error_responses: unknown verb %J", verb));
	let r = {
		"400": { "$ref": "#/components/responses/BadRequest" },
		"401": { "$ref": "#/components/responses/Unauthorized" },
		"403": { "$ref": "#/components/responses/Forbidden" },
		"404": { "$ref": "#/components/responses/NotFound" },
		"429": { "$ref": "#/components/responses/TooManyRequests" },
		"500": { "$ref": "#/components/responses/InternalError" },
		"503": { "$ref": "#/components/responses/ServiceUnavailable" },
	};
	if (verb != "get") {
		r["409"] = { "$ref": "#/components/responses/Conflict" };
		r["412"] = { "$ref": "#/components/responses/PreconditionFailed" };
		r["422"] = { "$ref": "#/components/responses/ValidationFailed" };
		r["423"] = { "$ref": "#/components/responses/Locked" };
	}
	return r;
}

function make_response(status, description, ref) {
	let resp = { "description": description };
	if (ref != null) {
		resp.content = {
			"application/json": { "schema": { "$ref": "#/components/schemas/" + ref } }
		};
	}
	return resp;
}

const SUCCESS_HEADERS_UNIVERSAL = {
	"X-Request-Id": { "$ref": "#/components/headers/XRequestId" },
};
// All four come from attach_reload_headers on a curated-resource write, and from the batch
// handler's own aggregation on a 207. Measured rather than reasoned: on a real box a curated
// write returns the reload pair on POST, PUT, PATCH and DELETE 204, while raw (all four
// verbs), packages, tokens and authorized_keys return none of them. A batch commits and
// reloads once for the whole set, so its 207 reports one outcome for the set rather than one
// per sub-write, which is the only place it can be reported: the results array carries
// `{status, body}` and drops sub-response headers.
const SUCCESS_HEADERS_UCI_TX = {
	"X-Reload-Status":   { "$ref": "#/components/headers/XReloadStatus" },
	"X-Reload-Services": { "$ref": "#/components/headers/XReloadServices" },
	"X-Kernel-Status":   { "$ref": "#/components/headers/XKernelStatus" },
	"X-Kernel-Applied":  { "$ref": "#/components/headers/XKernelApplied" },
};
const SUCCESS_HEADERS_POST = {
	"Idempotent-Replayed": { "$ref": "#/components/headers/IdempotentReplayed" },
};

// ETag comes from set_etag_header, whose four call sites are all in the curated CRUD and
// singleton handlers. make_collection.get_one returns errors.ok bare, so a collection-kind
// resource (the lease views) carries no ETag even though it is curated, and raw, packages,
// tokens, authorized_keys, whoami and diagnostics carry none either.
const UCI_TX = { uci_tx: true, etag: true };
const ETAG = { etag: true };

function attach_success_headers(resp, verb, status, opts) {
	let h = {};
	for (let k in SUCCESS_HEADERS_UNIVERSAL) h[k] = SUCCESS_HEADERS_UNIVERSAL[k];
	if (status >= 200 && status < 300 && verb != "get") {
		if (opts?.uci_tx)
			for (let k in SUCCESS_HEADERS_UCI_TX) h[k] = SUCCESS_HEADERS_UCI_TX[k];
		if (verb == "post")
			for (let k in SUCCESS_HEADERS_POST) h[k] = SUCCESS_HEADERS_POST[k];
		// Writes that return a body (PUT/PATCH/POST 200) carry the refreshed
		// ETag so clients can chain If-Match without a separate GET. DELETE
		// 204 has no body and no ETag.
		if (status == 200 && opts?.etag)
			h["ETag"] = { "$ref": "#/components/headers/ETag" };
		for (let k in opts?.extra) h[k] = opts.extra[k];
	}
	// The 304 carries the ETag too: maybe_304 rebuilds the response around it, and it only
	// fires on a 200 that had one, so the two are declared on exactly the same operations.
	if (verb == "get" && (status == 200 || status == 304) && opts?.etag)
		h["ETag"] = { "$ref": "#/components/headers/ETag" };
	if (resp.headers == null) resp.headers = {};
	for (let k in h)
		if (resp.headers[k] == null) resp.headers[k] = h[k];
	return resp;
}

// X-Mgmt-Path-Warning is the one emitted header that is per-resource and per-verb: only a
// write on a resource that can move the caller's own path carries it. Three do, and not only
// through `config interface`: a bridge-vlan on the bridge carrying the request turns on VLAN
// filtering and drops untagged traffic, and a device write can change that bridge's ports.
// Create is included because a new section can claim the management device just as a write to
// an existing one can. It rides the caller-supplied path rather than a global block.
function mgmt_headers(mod, opts) {
	if (!mod?.mgmt_path_guard) return opts;
	return { ...opts,
	         extra: { "X-Mgmt-Path-Warning": { "$ref": "#/components/headers/XMgmtPathWarning" } } };
}

function responses(verb, success, opts) {
	let r = {};
	for (let k in success) {
		let status = int(k);
		r[k] = attach_success_headers(success[k], verb, status, opts);
	}
	let errs = error_responses(verb);
	for (let k in errs) r[k] = errs[k];
	return r;
}

function build_crud_paths(ep) {
	let schema_ref = response_name(ep);
	let request_ref = request_name(ep);
	let mod = load_resource(ep.file);
	if (type(mod.openapi_singular) != "string" || mod.openapi_singular == "")
		die(sprintf("CRUD resource %s missing required `openapi_singular` declaration "
		            + "(used by the adopt operation summary)", ep.file));
	let singular = mod.openapi_singular;
	let id_param = {
		"name": "id", "in": "path", "required": true,
		"schema": { "type": "string" },
		"description": "Section identifier (uapi-generated ULID for managed sections, uci cfg-name for unmanaged)"
	};

	let paths = {};

	paths[ep.path] = {
		"get": {
			"summary": sprintf("List %s", ep.subresource),
			"parameters": [
				{ "name": "managed", "in": "query", "required": false,
				  "schema": { "type": "string", "enum": ["true", "false"] },
				  "description": "Filter by managed flag" },
			],
			"responses": responses("get", {
				"200": {
					"description": "OK",
					"headers": {
						"Link":          { "$ref": "#/components/headers/Link" },
						"X-Next-Cursor": { "$ref": "#/components/headers/XNextCursor" },
					},
					"content": { "application/json": {
						"schema": { "type": "array",
						            "items": { "$ref": "#/components/schemas/" + schema_ref } }
					} }
				},
			}),
		},
		"post": {
			"summary": sprintf("Create a %s", ep.subresource),
			"requestBody": {
				"required": true,
				"content": {
					"application/json": {
						"schema": { "$ref": "#/components/schemas/" + request_ref }
					}
				}
			},
			"parameters": [Q_IDEMPOTENCY_KEY],
			"responses": responses("post", { "200": make_response(200, "Created", schema_ref) },
			                        mgmt_headers(mod, UCI_TX)),
		},
	};

	paths[ep.path + "/{id}"] = {
		"parameters": [id_param],
		"get":    { "summary": sprintf("Get one %s", ep.subresource),
		            "description": "Supports conditional GET via `If-None-Match` (or `?if_none_match=` query param for clients behind uhttpd's strict CGI env). A matching ETag returns 304 with no body.",
		            "parameters": [Q_IF_NONE_MATCH],
		            "responses": responses("get", {
		              "200": make_response(200, "OK", schema_ref),
		              "304": { "description": "If-None-Match matched current ETag" },
		            }, ETAG) },
		"put":    { "summary": sprintf("Replace a %s", ep.subresource),
		            "description": "Honors `If-Match` and `If-None-Match` (header, or `?if_match=` / `?if_none_match=` for clients behind uhttpd's strict CGI env). A stale `If-Match`, or an `If-None-Match` that matches, gives 412 with nothing written.",
		            "parameters": [Q_IF_MATCH, Q_IF_NONE_MATCH],
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/" + request_ref } } } },
		            "responses": responses("put", { "200": make_response(200, "Replaced", schema_ref) },
		                                 mgmt_headers(mod, UCI_TX)) },
		"patch":  { "summary": sprintf("Partially update a %s", ep.subresource),
		            "parameters": [Q_IF_MATCH, Q_IF_NONE_MATCH],
		            "description": "Default content-type uses RFC 7396 merge-patch semantics (partial object). `application/json-patch+json` selects RFC 6902 JSON Patch with ops add/remove/replace/move/copy/test (the test op enables atomic compare-and-swap without If-Match).",
		            "requestBody": { "required": true, "content": {
		              "application/json":            { "schema": { "allOf": [ { "$ref": "#/components/schemas/" + request_ref } ],
		                                                            "description": "merge-patch partial body: any subset of the request schema" } },
		              "application/json-patch+json": { "schema": { "$ref": "#/components/schemas/JsonPatch" } },
		            } },
		            "responses": responses("patch", { "200": make_response(200, "Updated", schema_ref) },
		                                 mgmt_headers(mod, UCI_TX)) },
		"delete": { "summary": sprintf("Delete a %s", ep.subresource),
		            "parameters": [Q_IF_MATCH, Q_IF_NONE_MATCH],
		            "responses": responses("delete", { "204": { "description": "Deleted" } },
		                                   mgmt_headers(mod, UCI_TX)) },
	};

	paths[ep.path + "/{id}/adopt"] = {
		"parameters": [id_param],
		"post": {
			"summary": sprintf("Adopt an anonymous %s", singular),
			"description": sprintf(
				"Adopt an anonymous %s into uapi management. The section is renamed " +
				"to a uapi-generated ULID and `managed` flips to `true`; subsequent " +
				"writes (PUT, PATCH, DELETE) are then permitted. **The id changes**: " +
				"the response carries the new ULID; any client state pointing at the " +
				"original anonymous id (`cfgXXXXXX`) must be updated. Idempotent: " +
				"adopting an already-managed section returns 409 unmanaged_resource " +
				"(see error envelope).", singular),
			"responses": responses("post", { "200": make_response(200, "Adopted", schema_ref) }, UCI_TX)
		},
	};

	return paths;
}

function build_singleton_paths(ep) {
	let schema_ref = response_name(ep);
	let request_ref = request_name(ep);
	return {
		[ep.path]: {
			"get":   { "summary": sprintf("Get the %s singleton", ep.domain),
			           "parameters": [Q_IF_NONE_MATCH],
			           "description": "Conditional GET via If-None-Match (or ?if_none_match=).",
			           "responses": responses("get", {
			             "200": make_response(200, "OK", schema_ref),
			             "304": { "description": "If-None-Match matched current ETag" },
			           }, ETAG) },
			"patch": { "summary": sprintf("Update the %s singleton", ep.domain),
			           "description": "Merge-patch by default; `application/json-patch+json` selects RFC 6902 ops.",
			           "parameters": [Q_IF_MATCH, Q_IF_NONE_MATCH],
			           "requestBody": { "required": true, "content": {
			             "application/json":            { "schema": { "allOf": [ { "$ref": "#/components/schemas/" + request_ref } ],
			                                                           "description": "merge-patch partial body: any subset of the request schema" } },
			             "application/json-patch+json": { "schema": { "$ref": "#/components/schemas/JsonPatch" } },
			           } },
			           "responses": responses("patch", { "200": make_response(200, "Updated", schema_ref) }, UCI_TX) },
		},
	};
}

function build_collection_paths(ep) {
	let schema_ref = response_name(ep);
	let request_ref = request_name(ep);
	return {
		[ep.path]: {
			"get": {
				"summary": sprintf("List %s (read-only)", ep.subresource),
				"responses": responses("get", {
					"200": {
						"description": "OK",
						"content": { "application/json": {
							"schema": { "type": "array",
							            "items": { "$ref": "#/components/schemas/" + schema_ref } }
						} }
					},
				}),
			},
		},
		[ep.path + "/{id}"]: {
			"parameters": [{ "name": "id", "in": "path", "required": true,
			                 "schema": { "type": "string" } }],
			"get": { "summary": sprintf("Get one %s by id", ep.subresource),
			         "responses": responses("get", { "200": make_response(200, "OK", schema_ref) }) },
		},
	};
}

// Order matters: TAGS order drives the emitted tags[] order, and first-seen
// group order drives the x-tagGroups order.
const TAGS = [
	{ name: "Firewall / Zones",            group: "Firewall", description: "Firewall zones (`config zone`): input/output/forward policies, network lists, masq/mtu_fix toggles." },
	{ name: "Firewall / Rules",            group: "Firewall", description: "Firewall rules (`config rule`): nested `match` block for src/dest zone, IPs, ports, proto, family, mark, dscp, plus the MARK and DSCP targets and their `set_*` values. Cross-refs `firewall/zones`." },
	{ name: "Firewall / Redirects",        group: "Firewall", description: "Port forwards and NAT loopback (`config redirect`). Cross-refs `firewall/zones`." },
	{ name: "Firewall / Nat",              group: "Firewall", description: "Source NAT (`config nat`): SNAT, MASQUERADE, or exemption from address rewriting, keyed on the outbound zone. Cross-refs `firewall/zones`." },
	{ name: "Firewall / Forwardings",      group: "Firewall", description: "Zone-to-zone forwarding (`config forwarding`)." },
	{ name: "Firewall / Defaults",         group: "Firewall", description: "Global firewall defaults singleton: verdicts, syn_flood, tcp_syncookies, flow_offloading." },
	{ name: "Network / Interfaces",        group: "Network",  description: "Network interfaces (`config interface`). proto static/dhcp/dhcpv6/pppoe/wireguard/etc. `runtime` carries ubus state." },
	{ name: "Network / Devices",           group: "Network",  description: "Network devices (`config device`): bridges, VLAN (8021q/8021ad), macvlan, veth, tun/tap." },
	{ name: "Network / Routes",            group: "Network",  description: "Static routes (`config route`)." },
	{ name: "Network / Rules",             group: "Network",  description: "Policy routing rules (`config rule`)." },
	{ name: "Network / Bridge Vlans",      group: "Network",  description: "Bridge VLAN tagging (`config bridge-vlan`)." },
	{ name: "Network / Wireguard Peers",   group: "Network",  description: "WireGuard peers (dynamic uci type `wireguard_<iface>`); preshared_key write-only." },
	{ name: "Wireless / Devices",          group: "Wireless", description: "Wifi radios (`config wifi-device`): band, channel, htmode, country, txpower." },
	{ name: "Wireless / Interfaces",       group: "Wireless", description: "SSIDs (`config wifi-iface`). `key` write-only; runtime carries iwinfo state." },
	{ name: "Dhcp / Hosts",                group: "DHCP",     description: "Static DHCP leases (`config host`)." },
	{ name: "Dhcp / Servers",              group: "DHCP",     description: "Per-interface DHCP server config (`config dhcp`). runtime carries lease counts." },
	{ name: "Dhcp / Dnsmasq",              group: "DHCP",     description: "Global dnsmasq tuning singleton." },
	{ name: "Dhcp / Odhcpd",               group: "DHCP",     description: "odhcpd singleton." },
	{ name: "Dhcp / Leases",               group: "DHCP",     description: "IPv4 leases parsed from /tmp/dhcp.leases (read-only)." },
	{ name: "Dhcp / Leases6",              group: "DHCP",     description: "IPv6 leases from odhcpd statefile (read-only)." },
	{ name: "System",                      group: "System",   description: "Global system config singleton (`config system`): hostname, timezone, log_size, etc." },
	{ name: "System / Timeservers",        group: "System",   description: "NTP server list (`config timeserver`)." },
	{ name: "System / Password",           group: "System",   description: "Local Unix password (write-only; shells out to passwd).", path_prefix: "/system/password" },
	{ name: "System / SSH authorized keys", group: "System",  description: "Manage `/etc/dropbear/authorized_keys` entries by stable id.", path_prefix: "/system/authorized_keys" },
	{ name: "Dropbear / Instances",        group: "Other daemons", description: "Per-instance SSH config (`config dropbear`)." },
	{ name: "Uhttpd / Instances",          group: "Other daemons", description: "Per-instance HTTP server config (`config uhttpd`). Self-lockout protection on `main`." },
	{ name: "Uhttpd / Certs",              group: "Other daemons", description: "px5g certificate generation params (`config cert`)." },
	{ name: "Unbound / Server",            group: "Other daemons", description: "Recursive DNS server singleton (`config unbound`)." },
	{ name: "Unbound / Srv",               group: "Other daemons", description: "Directives rendered into unbound's `server:` clause (`config unbound_srv`). Requires the separate `unbound-uci-ext` package, which owns the uci-to-conf renderer and the init script this resource reloads; without it the first write returns `503 init_script_missing`." },
	{ name: "Unbound / Ext",               group: "Other daemons", description: "Clauses rendered outside `server:`, such as `forward-zone:` or `view:` (`config unbound_ext`). Same install dependency as Unbound / Srv: `unbound-uci-ext` provides the renderer and the init script, and without it the first write returns `503 init_script_missing`." },
	{ name: "Sqm / Queues",                group: "Other daemons", description: "Per-interface SQM shaping (`config queue`)." },
	{ name: "Snmpd / Agents",              group: "Other daemons", description: "SNMP listen addresses (`config agent`)." },
	{ name: "Snmpd / Com2secs",            group: "Other daemons", description: "community-to-security mapping (`config com2sec`)." },
	{ name: "Snmpd / Groups",              group: "Other daemons", description: "SNMP groups (`config group`)." },
	{ name: "Snmpd / Accesses",            group: "Other daemons", description: "group-to-view ACLs (`config access`)." },
	{ name: "Snmpd / System",              group: "Other daemons", description: "SNMPv2-MIB system.* singleton (sys_location, sys_contact, etc.)." },
	{ name: "Lldpd / Config",              group: "Other daemons", description: "LLDP/CDP/etc. toggles singleton." },
	{ name: "Prometheus Node Exporter Lua / Config", group: "Other daemons", description: "node_exporter listen + per-collector toggles singleton." },
	{ name: "Vnstat / Config",             group: "Other daemons", description: "Global vnstat singleton." },
	{ name: "Vnstat / Interfaces",         group: "Other daemons", description: "Per-iface vnstat enable." },
	{ name: "Mwan3 / Globals",             group: "Other daemons", description: "mwan3 multi-WAN tuning singleton (mark mask, logging, route-monitor interval)." },
	{ name: "Mwan3 / Interfaces",          group: "Other daemons", description: "Per-WAN tracking config: track_ip probes, failure/recovery thresholds, family." },
	{ name: "Mwan3 / Members",             group: "Other daemons", description: "(interface, metric, weight) tuples consumed by policies." },
	{ name: "Mwan3 / Policies",            group: "Other daemons", description: "Member groups with a last-resort fallback. Cross-refs `mwan3:members`." },
	{ name: "Mwan3 / Rules",               group: "Other daemons", description: "Traffic-match -> policy bindings. Cross-refs `mwan3:policies`." },
	{ name: "Usteer / Config",             group: "Other daemons", description: "Passive band-steering daemon singleton (signal thresholds, roam scan intervals, SSID filter)." },
	{ name: "Openvpn / Instances",         group: "Other daemons", description: "Per-tunnel OpenVPN config. Filesystem paths for ca/cert/dh; key/tls_auth/pkcs12 are write-only (reads return has_<field>)." },
	{ name: "Raw / Generic uci passthrough", group: "Generic uci passthrough", description: "Escape hatch for any uci section type uapi does not curate. Same atomic-transaction recipe, same auth model. Stable URL/verb/error contract; payload follows uci's moving target.", path_prefix: "/raw/" },
	{ name: "Packages / Installed",        group: "Packages", description: "Manage on-router apk packages (shells out to `apk add`/`del`).", path_prefix: "/packages/installed" },
	{ name: "Packages / Feeds",            group: "Packages", description: "Manage `/etc/apk/repositories.d/*.list` feed files.",          path_prefix: "/packages/feeds" },
	{ name: "Auth / Whoami",               group: "Auth & tokens", description: "Token introspection: read the calling bearer's own metadata.", path_prefix: "/auth/whoami" },
	{ name: "Auth / Tokens",               group: "Auth & tokens", description: "HTTP token rotation: list, mint, revoke. Mint enforces scope-subset (caller must hold every requested scope).", path_prefix: "/tokens" },
	{ name: "Operational / Healthz",       group: "Operational endpoints", description: "Liveness + subsystem checks. No auth. Treat `version` as the stable version-skew probe.", path_prefix: "/healthz" },
	{ name: "Operational / OpenAPI spec",  group: "Operational endpoints", description: "Self-describing endpoint serving this OpenAPI document. No auth.", path_prefix: "/openapi.json" },
	{ name: "Operational / Schema discovery", group: "Operational endpoints", description: "Per-resource schema_properties for dynamic clients without parsing the full spec. No auth.", path_prefix: "/schema" },
	{ name: "Operational / Metrics",       group: "Operational endpoints", description: "Prometheus 0.0.4 text. Path-template labels normalize concrete ids.", path_prefix: "/metrics" },
	{ name: "Operational / Diagnostics",   group: "Operational endpoints", description: "Lock state, uptime, loaded resources.",       path_prefix: "/diagnostics" },
	{ name: "Operational / Batch",         group: "Operational endpoints", description: "Multi-package atomic transaction (max 50 ops). 207 Multi-Status on success.", path_prefix: "/batch" },
];

function build_tags() {
	let out = [];
	for (let t in TAGS) push(out, { name: t.name, description: t.description });
	return out;
}

function build_tag_groups() {
	let order = [];
	let groups = {};
	for (let t in TAGS) {
		if (groups[t.group] == null) {
			groups[t.group] = { name: t.group, tags: [] };
			push(order, t.group);
		}
		push(groups[t.group].tags, t.name);
	}
	let out = [];
	for (let g in order) push(out, groups[g]);
	return out;
}

function build_static_path_tags() {
	let out = [];
	for (let t in TAGS)
		if (t.path_prefix != null) push(out, [t.path_prefix, t.name]);
	return out;
}

function build_paths() {
	let paths = {};
	for (let ep in ENDPOINTS) {
		let p;
		if (ep.kind == "crud") p = build_crud_paths(ep);
		else if (ep.kind == "singleton") p = build_singleton_paths(ep);
		else if (ep.kind == "collection") p = build_collection_paths(ep);
		tag_ops(p, tag_for(ep));
		// An endpoint being retired says so on every operation, not only in the ledger.
		// `deprecated` on the operation is what a code generator surfaces; prose in the
		// spec description reaches a human reading the document and nothing else.
		if (type(ep.deprecated) == "string") {
			for (let path in p) {
				for (let verb in p[path]) {
					if (verb == "parameters") continue;
					p[path][verb].deprecated = true;
					p[path][verb].description = ep.deprecated
						+ (p[path][verb].description != null ? "\n\n" + p[path][verb].description : "");
				}
			}
		}
		for (let k in p) paths[k] = p[k];
	}

	paths["/raw/{package}"] = {
		"parameters": [{ "name": "package", "in": "path", "required": true,
		                 "schema": { "type": "string" } }],
		"get": {
			"summary": "List raw uci sections for a package",
			"responses": responses("get", { "200": make_response(200, "OK", "RawSection") })
		},
		"post": {
			"summary": "Create a raw uci section",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/RawSection" } } } },
			"responses": responses("post", { "200": make_response(200, "Created", "RawWriteResult") })
		},
	};
	paths["/raw/{package}/{id}"] = {
		"parameters": [
			{ "name": "package", "in": "path", "required": true, "schema": { "type": "string" } },
			{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } },
		],
		"get":    { "summary": "Get a raw uci section",
		            "responses": responses("get", { "200": make_response(200, "OK", "RawSection") }) },
		"put":    { "summary": "Replace a raw uci section",
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/RawSection" } } } },
		            "responses": responses("put", { "200": make_response(200, "Replaced", "RawWriteResult") }) },
		"patch":  { "summary": "Partially update a raw uci section",
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object" } } } },
		            "responses": responses("patch", { "200": make_response(200, "Updated", "RawWriteResult") }) },
		"delete": { "summary": "Delete a raw uci section",
		            "responses": responses("delete", { "204": { "description": "Deleted" } }) },
	};

	paths["/packages/installed"] = {
		"get": {
			"summary": "List installed apk packages",
			"responses": responses("get", { "200": {
				"description": "OK",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/InstalledPackage" } } } },
			} })
		},
		"post": {
			"summary": "Install a package (apk add)",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PackageInstallRequest" } } } },
			"responses": responses("post", { "200": make_response(200, "Installed", "InstalledPackage") })
		},
	};
	paths["/packages/installed/{name}"] = {
		"parameters": [
			{ "name": "name", "in": "path", "required": true, "schema": { "type": "string" } },
		],
		"get":    { "summary": "Get info on an installed package",
		            "responses": responses("get", { "200": make_response(200, "OK", "InstalledPackage") }) },
		"delete": { "summary": "Remove a package (apk del)",
		            "responses": responses("delete", { "204": { "description": "Removed" } }) },
	};
	paths["/packages/feeds"] = {
		"get": {
			"summary": "List apk feeds under /etc/apk/repositories.d",
			"responses": responses("get", { "200": {
				"description": "OK",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/PackageFeed" } } } },
			} })
		},
		"post": {
			"summary": "Create a new apk feed file and run apk update",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PackageFeedCreateRequest" } } } },
			"responses": responses("post", { "200": make_response(200, "Created", "PackageFeed") })
		},
	};
	paths["/packages/feeds/{id}"] = {
		"parameters": [
			{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } },
		],
		"get":    { "summary": "Get one apk feed by id",
		            "responses": responses("get", { "200": make_response(200, "OK", "PackageFeed") }) },
		"delete": { "summary": "Delete an apk feed and re-run apk update",
		            "responses": responses("delete", { "204": { "description": "Removed" } }) },
	};

	paths["/system/password"] = {
		"post": {
			"summary": "Set the password for a local user (write-only; shells out to passwd)",
			"requestBody": { "required": true,
			                 "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SystemPasswordRequest" } } } },
			"responses": responses("post", { "204": { "description": "Password set" } })
		},
	};
	paths["/system/authorized_keys"] = {
		"get": {
			"summary": "List installed SSH public keys",
			"responses": responses("get", { "200": {
				"description": "OK",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/SSHAuthorizedKey" } } } },
			} })
		},
		"post": {
			"summary": "Add a single SSH public key",
			"requestBody": { "required": true,
			                 "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SSHKeyAddRequest" } } } },
			"responses": responses("post", { "200": make_response(200, "Added", "SSHAuthorizedKey") })
		},
		"put": {
			"summary": "Replace the authorized_keys list wholesale",
			"requestBody": { "required": true,
			                 "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SSHKeyReplaceRequest" } } } },
			"responses": responses("put", { "200": {
				"description": "Replaced",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/SSHAuthorizedKey" } } } },
			} })
		},
	};
	paths["/system/authorized_keys/{id}"] = {
		"parameters": [
			{ "name": "id", "in": "path", "required": true, "schema": { "type": "string", "pattern": "^[a-f0-9]{12}$" } },
		],
		"get":    { "summary": "Get a single SSH key by stable id",
		            "responses": responses("get", { "200": make_response(200, "OK", "SSHAuthorizedKey") }) },
		"delete": { "summary": "Remove a single SSH key by stable id",
		            "responses": responses("delete", { "204": { "description": "Removed" } }) },
	};

	paths["/healthz"] = {
		"get": {
			"summary": "Liveness check (no auth required)",
			"security": [],
			"responses": {
				"200": { "description": "All subsystems ok",
				          "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Healthz" } } } },
				"503": { "description": "At least one subsystem degraded",
				          "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Healthz" } } } },
			},
		},
	};

	paths["/openapi.json"] = {
		"get": {
			"summary": "Retrieve this OpenAPI document (no auth required)",
			"security": [],
			"responses": {
				"200": { "description": "OK",
				          "content": { "application/json": { "schema": { "type": "object" } } } },
			},
		},
	};

	paths["/schema"] = {
		"get": {
			"summary": "List every curated resource key (no auth)",
			"security": [],
			"responses": {
				"200": { "description": "OK",
				          "content": { "application/json": { "schema": {
				            "type": "object", "properties": { "resources": { "type": "array", "items": { "type": "string" } } } } } } },
			},
		},
	};
	paths["/schema/{package}"] = {
		"parameters": [{ "name": "package", "in": "path", "required": true, "schema": { "type": "string" } }],
		"get": { "summary": "Schemas for every resource in one package (no auth)", "security": [],
		         "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "type": "object" } } } }, "404": { "$ref": "#/components/responses/NotFound" } } },
	};
	paths["/schema/{package}/{resource}"] = {
		"parameters": [
			{ "name": "package", "in": "path", "required": true, "schema": { "type": "string" } },
			{ "name": "resource", "in": "path", "required": true, "schema": { "type": "string" } },
		],
		"get": { "summary": "Schema for one curated resource (no auth)", "security": [],
		         "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ResourceSchema" } } } }, "404": { "$ref": "#/components/responses/NotFound" } } },
	};

	paths["/auth/whoami"] = {
		"get": {
			"summary": "Introspection: the calling token's own metadata",
			"description": "No additional scope check. Any authenticated bearer can read its own metadata.",
			"responses": responses("get", {
				"200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/WhoamiResponse" } } } },
			}),
		},
	};

	paths["/tokens"] = {
		"get": {
			"summary": "List all tokens (no secrets surfaced)",
			"description": "Scope: uapi:tokens:ro (or *:ro). Each entry omits salt and hash.",
			"responses": responses("get", {
				"200": { "description": "OK", "content": { "application/json": { "schema": {
				  "type": "object",
				  "properties": { "tokens": { "type": "array", "items": { "$ref": "#/components/schemas/TokenMetadata" } } } } } } },
			}),
		},
		"post": {
			"summary": "Mint a new token over HTTP",
			"description": "Scope: uapi:tokens:rw (or *:rw). Requested scopes MUST be a strict subset of the caller's own; escalation returns 403 scope_escalation_blocked. The cleartext bearer is returned exactly once.",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TokenCreateRequest" } } } },
			"responses": responses("post", {
				"200": { "description": "Created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TokenCreateResponse" } } } },
			}),
		},
	};
	paths["/tokens/{id}"] = {
		"parameters": [{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }],
		"get":    { "summary": "Get one token's metadata",
		            "responses": responses("get", { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TokenMetadata" } } } } }) },
		"delete": { "summary": "Revoke a token",
		            "responses": responses("delete", { "204": { "description": "Revoked" } }) },
	};

	paths["/metrics"] = {
		"get": {
			"summary": "Prometheus 0.0.4 text exposition",
			"description": "Scope: uapi:metrics:ro (or *:ro). Series: uapi_requests_total, uapi_request_duration_seconds_bucket, uapi_request_duration_seconds_count, uapi_rate_limit_drops_total, uapi_lock_contention_total, uapi_validate_errors_total. Path-template labels normalize concrete ids to :id to keep cardinality bounded.",
			"responses": responses("get", {
				"200": { "description": "OK", "content": { "text/plain": { "schema": { "type": "string" }, "example": "uapi_requests_total{method=\"GET\",path=\"/firewall/rules\",status=\"200\"} 42\n" } } },
			}),
		},
	};

	paths["/diagnostics"] = {
		"get": {
			"summary": "Operational snapshot (lock state, uptime, loaded resources)",
			"description": "Scope: uapi:diagnostics:ro (or *:ro). With `?validate=1` the response also carries the validation sweep, which walks every section the token may read and reports the ones a write would reject. The sweep is opt-in because it reads the whole configuration and this endpoint is normally polled.",
			"parameters": [
				{ "name": "validate", "in": "query", "required": false,
				  "schema": { "type": "string", "enum": ["1"] },
				  "description": "Set to `1` to include the validation sweep. Any other value is ignored." },
			],
			"responses": responses("get", {
				"200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/DiagnosticsResponse" } } } },
			}),
		},
	};

	paths["/batch"] = {
		"post": {
			"summary": "Multi-package atomic transaction",
			"description": "Each sub-request is scope-checked independently. Pure-read batches acquire no lock. Writes acquire per-package EX locks in sorted order (deadlock-free) under one combined snapshot/restore. First sub-request failure aborts the batch and reverts all packages; success returns 207 Multi-Status with the per-sub-request results. Max 50 ops.",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/BatchRequest" } } } },
			"responses": responses("post", {
				"207": { "description": "Multi-Status: every sub-request succeeded", "headers": SUCCESS_HEADERS_UCI_TX, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/BatchResponse" } } } },
			}),
		},
	};

	// Tag non-curated paths. Longest-prefix-wins so /system/password doesn't
	// get the bare "System" tag.
	let static_path_tags = build_static_path_tags();
	for (let p in paths) {
		if (type(paths[p]) != "object") continue;
		let any_op = null;
		for (let v in paths[p]) {
			if (v == "parameters") continue;
			if (type(paths[p][v]) == "object") { any_op = paths[p][v]; break; }
		}
		if (any_op == null || type(any_op.tags) == "array") continue;
		let best_tag = null, best_len = -1;
		for (let pair in static_path_tags) {
			let prefix = pair[0], tag = pair[1];
			if (substr(p, 0, length(prefix)) == prefix && length(prefix) > best_len) {
				best_tag = tag;
				best_len = length(prefix);
			}
		}
		if (best_tag != null) {
			for (let v in paths[p]) {
				if (v == "parameters") continue;
				if (type(paths[p][v]) == "object") paths[p][v].tags = [best_tag];
			}
		}
	}

	// Every POST, not a per-endpoint decision: main.uc gates the idempotency cache on the
	// method alone, so any POST honours the key. Declared in one pass rather than at each
	// build site so a new POST endpoint carries it the day it is added, which is how the
	// hand-built ones came to be missing it while the generated ones had it.
	for (let p in paths) {
		let op = paths[p].post;
		if (type(op) != "object") continue;
		let declared = false;
		for (let prm in op.parameters ?? [])
			if (prm.name == "idempotency_key") declared = true;
		if (!declared)
			op.parameters = [ ...(op.parameters ?? []), Q_IDEMPOTENCY_KEY ];
	}

	return paths;
}

function build_schemas() {
	let schemas = {
		"ErrorEnvelope": {
			"type": "object",
			"required": ["code", "message", "request_id"],
			"properties": {
				"code": { "type": "string",
				          "enum": errors_mod.ALL_CODES,
				          "description": "Machine-readable error code. Stable within a major. Clients should branch on HTTP status first and treat unknown codes gracefully (the project's additive contract permits new codes within a major)." },
				"message": { "type": "string", "description": "Human-readable English. Do not parse." },
				"request_id": { "type": "string", "description": "ULID echoed in the X-Request-Id response header. Pair with audit log for server-side tracing." },
				"errors": { "type": "array",
				            "items": { "$ref": "#/components/schemas/FieldError" },
				            "description": "Per-field error list (validation_failed only)." },
				"reload_error":  { "type": "string", "description": "reload_failed_restored / reload_failed_unrecovered only." },
				"restore_error": { "type": "string", "description": "reload_failed_unrecovered only." },
				"aborted_at_index": { "type": "integer", "description": "batch_partial_failure only: 0-based index of the sub-request that failed." },
				"reverted": { "type": "boolean", "description": "batch_partial_failure only: true if all packages were restored." },
				"error": { "$ref": "#/components/schemas/ErrorEnvelope", "description": "batch_partial_failure only: the failing sub-request's envelope." },
			},
		},
		"FieldError": {
			"type": "object",
			"required": ["field", "code", "message"],
			"properties": {
				"field": { "type": "string" },
				"code": { "type": "string", "enum": keys(errors_mod.FIELD_CODES) },
				"message": { "type": "string" },
			},
		},
		"RawSection": {
			"type": "object",
			"required": [".type"],
			"properties": {
				"id": { "type": "string", "description": "Optional; generated if absent" },
				".type": { "type": "string" },
				"managed": { "type": "boolean", "readOnly": true },
			},
			"additionalProperties": true,
		},
		"RawWriteResult": {
			"allOf": [
				{ "$ref": "#/components/schemas/RawSection" },
				{ "type": "object", "properties": {
					"reloaded": { "type": "boolean" },
					"reload_services": { "type": "array", "items": { "type": "string" } },
					"reload_note": { "type": "string" },
				} },
			],
		},
		"InstalledPackage": {
			"type": "object",
			"required": ["id", "name", "installed"],
			"properties": {
				"id": { "type": "string", "description": "Package name (same as name)" },
				"managed": { "type": "boolean", "readOnly": true },
				"name": { "type": "string" },
				"version": { "type": ["string", "null"] },
				"installed": { "type": "boolean" },
				"runtime": { "type": "object", "readOnly": true },
			},
		},
		"PackageInstallRequest": {
			"type": "object",
			"required": ["name"],
			"properties": {
				"name": { "type": "string",
				          "description": "apk package name (^[A-Za-z0-9_+.-]+$)" },
			},
		},
		"PackageFeed": {
			"type": "object",
			"required": ["id", "url"],
			"properties": {
				"id": { "type": "string" },
				"managed": { "type": "boolean", "readOnly": true },
				"name": { "type": "string" },
				"filename": { "type": "string" },
				"url": { "type": "string" },
				"enabled": { "type": "boolean" },
				"update_status": { "type": "string" },
				"runtime": { "type": "object", "readOnly": true },
			},
		},
		"PackageFeedCreateRequest": {
			"type": "object",
			"required": ["name", "url"],
			"properties": {
				"name": { "type": "string",
				          "description": "Feed name (^[A-Za-z0-9_.-]+$); becomes <name>.list" },
				"url":  { "type": "string", "description": "HTTP(S) URL of the package repository" },
			},
		},
		"SystemPasswordRequest": {
			"type": "object",
			"required": ["user", "password"],
			"properties": {
				"user":     { "type": "string", "pattern": "^(root|[a-z][a-z0-9_-]*)$",
				              "description": "Local Unix user to update; usually 'root'" },
				"password": { "type": "string", "minLength": 8,
				              "writeOnly": true,
				              "description": "New password (min 8 chars). Never echoed back." },
			},
		},
		"SSHAuthorizedKey": {
			"type": "object",
			"required": ["id", "type"],
			"properties": {
				"id":      { "type": "string", "pattern": "^[a-f0-9]{12}$",
				             "description": "Stable id: sha256 prefix of the public-key blob (or non-crypto djb2 fallback in test environments)" },
				"type":    { "type": "string",
				             "description": "SSH key type (e.g. ssh-ed25519, ssh-rsa, ecdsa-sha2-nistp256)" },
				"comment": { "type": "string",
				             "description": "Optional comment (trailing text on the key line)" },
			},
		},
		"SSHKeyAddRequest": {
			"type": "object",
			"required": ["key"],
			"properties": {
				"key": { "type": "string",
				         "description": "Full SSH public key line: <type> <base64-blob> [comment]" },
			},
		},
		"SSHKeyReplaceRequest": {
			"type": "object",
			"required": ["keys"],
			"properties": {
				"keys": { "type": "array",
				          "items": { "type": "string" },
				          "description": "Full key lines; replaces /etc/dropbear/authorized_keys wholesale" },
			},
		},

		"Healthz": {
			"type": "object",
			"required": ["status", "version", "checks"],
			"properties": {
				"status":  { "type": "string", "enum": ["ok", "degraded"] },
				"version": { "type": "string",
				             "description": "Package version. STABLE: clients may rely on this for version-skew detection." },
				"checks":  { "type": "object",
				             "required": ["ubus", "uci", "lock_dir", "time_sync"],
				             "properties": {
				               "ubus":      { "type": "string", "enum": ["ok", "degraded"] },
				               "uci":       { "type": "string", "enum": ["ok", "degraded"] },
				               "lock_dir":  { "type": "string", "enum": ["ok", "degraded"] },
				               "time_sync": { "type": "string", "enum": ["ok", "degraded", "unknown"],
				                              "description": "unknown for first 60s after boot; degraded if wall-clock epoch < 2023-11-15 sanity floor" },
				             } },
				"errors":  { "type": "array", "items": { "type": "string" },
				             "description": "Present when status=degraded; one human-readable line per failing subsystem." },
			},
		},
		"ResourceSchema": {
			"type": "object",
			"required": ["id", "package", "type", "schema_properties"],
			"properties": {
				"id":      { "type": "string", "description": "<package>:<resource> key" },
				"package": { "type": "string" },
				"type":    { "type": "string", "description": "uci section type" },
				"schema_properties": { "type": "object", "description": "JSON-Schema fragment as the resource module declares it: every property, without the request and response split the OpenAPI document makes. A property marked readOnly here is absent from that resource's *Request schema, and `id`, `managed` and `runtime` are stamped by the framework rather than declared here. Use the *Request and *Response components when you need the two halves." },
			},
		},
		"WhoamiResponse": {
			"type": "object",
			"required": ["token_id", "scopes", "source_ip", "expires_at", "allowed_cidrs", "last_used_at", "last_used_ip"],
			"properties": {
				"token_id":    { "type": "string" },
				"scopes":      { "type": "array", "items": { "type": "string" } },
				"source_ip":   { "type": ["string", "null"] },
				"expires_at":  { "type": ["integer", "null"], "description": "Unix epoch seconds; null if never expires" },
				"allowed_cidrs": { "type": "array", "items": { "type": "string" } },
				"last_used_at": { "type": ["integer", "null"], "description": "Unix epoch seconds of last authed request; throttled to ~1/minute" },
				"last_used_ip": { "type": ["string", "null"] },
				// No minimum on the read shape: it surfaces what is stored in
				// uci, which may be hand-edited to a non-positive value.
				// TokenCreateRequest carries minimum: 1 as the policy boundary
				// on new mints.
				"rate":  { "type": ["integer", "null"], "description": "Per-token rate-limit override (req/s); null means use global" },
				"burst": { "type": ["integer", "null"], "description": "Per-token burst override; null means use global" },
			},
		},
		// Deliberately standalone rather than composed from WhoamiResponse. It used to be
		// `allOf` over it, which inherited that schema's `required` and so demanded
		// `token_id` and `source_ip` from every entry of `GET /tokens`, neither of which the
		// token endpoints return: the listing names the token `name`, and `source_ip` is the
		// caller's address, meaningful only for whoami. Every entry the live endpoint
		// returned therefore violated its own published schema, so a strict generated client
		// rejected the whole response.
		"TokenMetadata": {
			"type": "object",
			"required": ["name", "scopes", "expires_at", "allowed_cidrs", "last_used_at",
			             "last_used_ip", "rate", "burst"],
			"properties": {
				"name":   { "type": "string", "description": "The token's identifier, as passed to `uapi-token`" },
				"scopes": { "type": "array", "items": { "type": "string" } },
				"expires_at":    { "type": ["integer", "null"], "description": "Unix epoch seconds; null if never expires" },
				"allowed_cidrs": { "type": "array", "items": { "type": "string" } },
				"last_used_at":  { "type": ["integer", "null"], "description": "Unix epoch seconds of last authed request; throttled to ~1/minute" },
				"last_used_ip":  { "type": ["string", "null"] },
				"rate":  { "type": ["integer", "null"], "description": "Per-token rate-limit override (req/s); null means use global" },
				"burst": { "type": ["integer", "null"], "description": "Per-token burst override; null means use global" },
			},
		},
		"TokenCreateRequest": {
			"type": "object",
			"required": ["name", "scopes"],
			"properties": {
				"name":   { "type": "string", "pattern": "^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$" },
				"scopes": { "type": "array", "items": { "type": "string" }, "minItems": 1,
				            "description": "MUST be a strict subset of the caller's own scopes; escalation returns 403 scope_escalation_blocked" },
				"expires_in_seconds": { "type": ["integer", "null"], "minimum": 1 },
				"allowed_cidrs":      { "type": "array", "items": { "type": "string", "description": "IPv4 or IPv6 CIDR; a caller matches entries of its own family only" } },
				"rate":  { "type": ["integer", "null"], "minimum": 1,
				           "description": "Per-token rate limit: requests per second. Overrides the global rate (default 100). Absent or null inherits the global." },
				"burst": { "type": ["integer", "null"], "minimum": 1,
				           "description": "Per-token burst: token-bucket capacity. Overrides the global burst (default 200). Absent or null inherits the global." },
			},
		},
		"TokenCreateResponse": {
			"type": "object",
			"required": ["bearer", "name"],
			"properties": {
				"bearer": { "type": "string", "writeOnly": true,
				            "description": "Cleartext bearer token. Shown exactly once at mint time; uapi keeps only the salted sha256 on disk. Store securely and pass back as `Authorization: Bearer <bearer>` on subsequent requests." },
				"name":   { "type": "string",
				            "description": "Stable token id (also the uci section name). Use as the path segment in `GET /tokens/{name}`, `DELETE /tokens/{name}`. Must match `[A-Za-z0-9_]+` (uci section-name charset)." },
			},
		},
		"DiagnosticsResponse": {
			"type": "object",
			"required": ["version", "uptime_seconds", "resources_loaded", "lock_state", "request_id"],
			"properties": {
				"version":          { "type": "string" },
				"uptime_seconds":   { "type": "integer" },
				"resources_loaded": { "type": "array", "items": { "type": "string" } },
				"lock_state": { "type": "object",
				                "required": ["global_held", "per_package"],
				                "properties": {
				                  "global_held": { "type": "boolean" },
				                  "per_package": { "type": "object", "additionalProperties": { "type": "boolean" } },
				                } },
				// Present only when the route lookup resolved; `interface` is null when no
				// uci interface claims the device the request arrived on.
				"management_path": {
					"type": "object",
					"description": "Which interface this request arrived through. Absent when the inbound address or its route could not be determined.",
					"required": ["address", "device", "interface"],
					"properties": {
						"address":   { "type": "string" },
						"device":    { "type": "string" },
						"interface": { "type": ["string", "null"] },
					},
				},
				// The three sweep fields appear together, and only with ?validate=1.
				"invalid_sections": {
					"type": "array",
					"description": "Sections a write would reject today. Present only with ?validate=1.",
					"items": {
						"type": "object",
						"required": ["resource", "id", "managed", "errors"],
						"properties": {
							"resource": { "type": "string", "example": "firewall/rules",
							              "description": "Slash form, unlike swept_resources" },
							"id":       { "type": ["string", "null"] },
							"managed":  { "type": ["boolean", "null"] },
							"errors": { "type": "array", "items": {
								"type": "object",
								"required": ["field", "code", "message"],
								"properties": {
									"field":   { "type": "string" },
									"code":    { "type": "string",
									             "enum": ["required", "invalid_type", "invalid_format",
									                      "out_of_range", "not_in_enum", "conflict",
									                      "read_only", "unreadable", "sweep_failed"] },
									"message": { "type": "string" },
								},
							} },
						},
					},
				},
				"swept_resources": {
					"type": "array", "items": { "type": "string", "example": "firewall:rules" },
					"description": "Resources the sweep checked, in colon form. Present only with ?validate=1.",
				},
				"skipped_for_scope": {
					"type": "array", "items": { "type": "string", "example": "firewall:rules" },
					"description": "Resources left out because the token lacks :ro on them. An empty invalid_sections beside a long list here means \"not allowed to look\", not \"nothing wrong\". Present only with ?validate=1.",
				},
				"recent_errors": {
					"type": "array",
					"maxItems": 20,
					"description": "Best-effort ring of the last 20 error envelopes emitted by this uhttpd parent VM. May be empty (no errors yet, or /tmp ring file unreadable).",
					"items": { "type": "object",
					           "required": ["ts", "request_id", "code", "status"],
					           "properties": {
					             "ts":         { "type": "integer", "description": "Unix epoch seconds when the error was recorded." },
					             "request_id": { "type": "string" },
					             "code":       { "type": "string" },
					             "status":     { "type": "integer" },
					             "method":     { "type": ["string", "null"] },
					             "path":       { "type": ["string", "null"] },
					             "message":    { "type": "string" },
					           } },
				},
				"request_id":       { "type": "string" },
			},
		},
		"BatchRequest": {
			"type": "object",
			"required": ["operations"],
			"properties": {
				"operations": { "type": "array", "minItems": 1, "maxItems": 50,
				                "items": { "$ref": "#/components/schemas/BatchOperation" } },
			},
		},
		"BatchOperation": {
			"type": "object",
			"required": ["path", "method"],
			"properties": {
				"path":     { "type": "string", "description": "Resource path (e.g. /firewall/rules)" },
				"method":   { "type": "string", "enum": ["GET", "POST", "PUT", "PATCH", "DELETE"] },
				// Typed rather than left open: the payload is whatever the target
				// resource accepts, so it cannot be described further here, but an
				// untyped schema is where a malformed value hides from every check
				// that walks the document.
				"body":     { "type": "object", "additionalProperties": true,
				              "description": "Request body for POST/PUT/PATCH; shape is the target resource's own schema. Omit for GET/DELETE" },
				"if_match": { "type": "string", "description": "Optional per-sub-request If-Match ETag" },
			},
		},
		"BatchResponse": {
			"type": "object",
			"required": ["results", "request_id"],
			"properties": {
				"results": { "type": "array",
				             "items": { "type": "object",
				                        "required": ["status"],
				                        "properties": {
				                          "status": { "type": "integer" },
				                          "body": {},
				                        } } },
				"request_id": { "type": "string" },
			},
		},
		"JsonPatch": {
			"type": "array",
			"description": "RFC 6902 JSON Patch document. Sent with Content-Type: application/json-patch+json on PATCH. Supports ops: add, remove, replace, move, copy, test.",
			"items": {
				"type": "object",
				"required": ["op", "path"],
				"properties": {
				  "op":    { "type": "string", "enum": ["add", "remove", "replace", "move", "copy", "test"] },
				  "path":  { "type": "string", "description": "RFC 6901 JSON Pointer" },
				  "value": { "description": "Required for add, replace, test" },
				  "from":  { "type": "string", "description": "Required for move, copy" },
				},
			},
		},
	};

	for (let ep in ENDPOINTS) {
		let mod = load_resource(ep.file);
		let properties = {};

		if (ep.kind == "collection") {
			if (type(mod.schema_properties) == "object") {
				for (let k in mod.schema_properties) properties[k] = mod.schema_properties[k];
			}
		} else {
			let example_in;
			try {
				if (mod.fromUci != null) {
					example_in = mod.fromUci({ '.name': 'cfg00', '.anonymous': false, '.type': mod.type });
				} else {
					example_in = { id: "example", managed: false };
				}
			} catch (e) {
				example_in = { id: "example", managed: false };
			}

			for (let k in example_in) {
				let v = example_in[k];
				let prop;
				if (type(v) == "bool") prop = { "type": "boolean" };
				else if (type(v) == "int" || type(v) == "double") prop = { "type": "number" };
				else if (type(v) == "array") prop = { "type": "array", "items": { "type": "string" } };
				else if (type(v) == "object") prop = { "type": "object" };
				else prop = { "type": ["string", "null"] };
				properties[k] = prop;
			}
			if (type(mod.schema_properties) == "object") {
				for (let k in mod.schema_properties) properties[k] = mod.schema_properties[k];
			}
		}

		// runtime is derived from ubus and toUci ignores it, so it can never be
		// written on any resource. Saying so matters twice over: for the fields
		// that deliberately disagree with the configured value, where a generator
		// treating them as writable produces a diff no configuration can resolve;
		// and for the resources that merely carry an empty runtime, where an
		// un-annotated `type: object` reads to a generator as an ordinary
		// writable free-form map. The annotation has to land whether or not the
		// module documents its runtime shape, which is why it is applied to the
		// property rather than folded into the openapi_runtime override.
		if (type(properties.runtime) == "object") {
			let documented = (type(mod.openapi_runtime) == "object") ? mod.openapi_runtime : properties.runtime;
			properties.runtime = { ...documented, readOnly: true };
		}

		// Same reasoning for `managed`, which is derived from uci's `.anonymous` flag: no
		// toUci reads it, and the write path hardcodes `.anonymous = false`, so a PUT
		// sending `managed: false` answers 200 with `managed: true`. Management state
		// moves only through the adopt endpoint. Emitted bare, it reads to a generator as
		// an ordinary writable boolean, so it lands in the request model and every
		// read-modify-write client sends a field the server ignores.
		//
		// Annotated here rather than in the modules on purpose: adding `managed` to a
		// resource's schema_properties would also add it to the runtime type checker, and
		// `managed: "true"` would go from 200 to 422. This is a documentation fix and
		// should not change what the server accepts.
		if (type(properties.managed) == "object")
			properties.managed = { ...properties.managed, readOnly: true };

		// 2.2.0: every CRUD resource accepts an optional `id` at create
		// that becomes both the uci section name and the response id. If
		// the resource module didn't supply its own id schema entry (only
		// network.interfaces does, with IFNAMSIZ specifics for wireguard),
		// inject a standard description so the spec uniformly documents
		// the universal create-time input. The fromUci sample loop above
		// populated `properties.id` with `{"type": ["string", "null"]}`
		// and no description; we detect that case via the missing
		// description and replace.
		if (ep.kind == "crud") {
			let id_entry = properties.id ?? {};
			if (id_entry.description == null) {
				properties.id = {
					"type": "string",
					"pattern": "^[A-Za-z][A-Za-z0-9_]{0,31}$",
					"description": "Optional at create: caller-supplied uci section name; becomes the response `id`. When omitted, the server emits a ULID. Read-only after create (rename via DELETE + POST). Charset and length follow uci section-name rules: 1 to 32 characters, start with a letter, alphanumerics and underscore only. Per-resource modules may tighten further (e.g. proto=wireguard interfaces are IFNAMSIZ-tight at 15 chars).",
				};
			}
		}

		let resp_props = response_properties(properties);
		let s = {
			"type": "object",
			"description": sprintf("uapi resource backed by uci %s.%s", mod.package, mod.type),
			"properties": resp_props,
		};

		if (type(mod.openapi_required) == "array" && length(mod.openapi_required) > 0)
			s.required = mod.openapi_required;

		// A response carries its writeOnly properties so the request half stays a subset of it,
		// which is what keeps a generated client from treating a settable field as computed.
		// They are masked on read, though, so a write-side rule that requires one demands
		// something no response can supply: wireless/interfaces requires `key` when encryption
		// is psk2, and every read of an encrypted interface violated its own schema. The
		// conditional is therefore projected over what a response can actually satisfy.
		if (type(mod.openapi_conditional) == "array" && length(mod.openapi_conditional) > 0) {
			let readable = {};
			for (let k in resp_props)
				if (type(resp_props[k]) != "object" || resp_props[k].writeOnly !== true)
					readable[k] = resp_props[k];
			let cond = project_conditional(mod.openapi_conditional, readable, ep.path);
			if (length(cond) > 0) s.allOf = cond;
		}

		schemas[response_name(ep)] = s;

		let req_props = request_properties(properties);
		// A conditional may not require a masked field. `key` is writeOnly, so a read never
		// returns it and a read-modify-write body cannot carry it, yet wireless/interfaces
		// requires it when encryption is a PSK variant: every round-trip body was invalid
		// against the schema it was published under, while the server accepts it by carrying
		// the stored secret forward. Nothing is lost by dropping the arm, because the runtime
		// never reads openapi_conditional: resource.validate() enforces the rule and answers
		// 422 with field `key`, code `required`, on a keyless PSK create.
		let req_satisfiable = {};
		for (let k in req_props)
			if (type(req_props[k]) != "object" || req_props[k].writeOnly !== true)
				req_satisfiable[k] = req_props[k];
		let req = {
			"type": "object",
			"description": sprintf("Request body for the uapi resource backed by uci %s.%s.",
			                       mod.package, mod.type),
			"properties": req_props,
		};
		if (type(mod.openapi_required) == "array" && length(mod.openapi_required) > 0)
			req.required = mod.openapi_required;
		if (type(mod.openapi_conditional) == "array" && length(mod.openapi_conditional) > 0) {
			let cond = project_conditional(mod.openapi_conditional, req_satisfiable, ep.path);
			if (length(cond) > 0) req.allOf = cond;
		}
		// Only for an endpoint that can actually be written. A generated client reads a
		// missing Request as "not writable, or gone", and that inference is what made the
		// removal of vnstat/interfaces fail codegen loudly instead of quietly; minting one
		// for a read-only endpoint would blunt it.
		if (ep.kind != "collection")
			schemas[request_name(ep)] = req;
	}

	return schemas;
}


function build_doc() {
	return {
		"openapi": "3.1.0",
		"info": {
			"title": "uapi",
			"version": VERSION,
			"description": "Native HTTP REST API for OpenWrt. Translates standard REST verbs into ubus/uci operations so edge routers become first-class targets for Infrastructure-as-Code workflows.\n\n## Quickstart\n\nMint a token on the router (one-time):\n\n```sh\nuapi-token create --name terraform_prod --scope '*:rw' --expires-in 90d\n```\n\nThen call the API:\n\n```sh\ncurl -H \"Authorization: Bearer $TOKEN\" https://router/api/v3/firewall/rules\n```\n\n## Two surfaces\n\n- **Curated resources** under `/api/v3/<domain>/...` - hand-written schemas, stable across the major. Field names are `snake_case`; uci booleans normalize to JSON booleans; uci list options surface as JSON arrays.\n- **Raw passthrough** under `/api/v3/raw/<package>/<id>` - generic uci access for the long tail. Same atomic-transaction recipe and same auth model, but payloads follow uci's field names directly (and move when upstream OpenWrt does).\n\n## Resource shape\n\nEvery curated resource carries `id` (stable across uci rewrites) and `managed: bool` at the top level. Server-derived state lives under `runtime: {...}` (computed; clients ignore for drift detection).\n\n## Auth\n\nBearer tokens with hierarchical scopes (e.g. `firewall:rules:rw`, `*:ro`). See the **Auth / Tokens** group for mint/list/revoke and the `/auth/whoami` endpoint for introspection.\n\n## Optimistic concurrency\n\nEvery curated-resource GET and write returns an `ETag` header that is a stable hash of the resource's own body (the `runtime` block is excluded so live ubus state never trips a 412). Honor with `If-Match` on writes (or `?if_match=<etag>` query param for clients behind uhttpd's strict CGI env, which drops the header). `If-None-Match` is honoured on writes too, per RFC 9110 13.1.2: a match, or `*` against an existing resource, gives 412. Preconditions are evaluated before the transaction, so a 412 never leaves a partial write. Conditional GET via `If-None-Match` returns 304 when matching, and the 304 carries the same `ETag`. Raw passthrough, the non-uci endpoints and the read-only lease views carry no `ETag` and so support neither conditional GET nor `If-Match`. Sibling sections in the same package do not influence each other's ETags; If-Match fires only when *this* resource has actually changed.\n\n## Idempotency\n\n`Idempotency-Key` on POST caches the response for 24 h; a repeat with the same key replays. Same key with a different body returns `409 idempotency_key_conflict`.\n\nuhttpd's CGI env forwards a fixed allowlist of headers and `Idempotency-Key` is not on it, so a client reaching uapi directly through uhttpd must pass `?idempotency_key=` instead; the header only survives behind a reverse proxy that re-adds it. The same applies to `If-Match` and `If-None-Match`, hence `?if_match=` and `?if_none_match=`. All three are declared as query parameters on the operations that honour them.\n\n## Sensitive fields (write-only + `has_<field>` presence flag)\n\nFields holding secret material (passphrases, private keys, PSKs, PKCS#12 paths) are write-only on the wire: GET responses omit the value and surface a read-only `has_<field>: bool` companion indicating presence. Examples: `wireless.interfaces.key`/`has_key`, `network.wireguard_peers.private_key`/`has_private_key`, `network.wireguard_peers.preshared_key`/`has_preshared_key`, `openvpn.instances.key`/`has_key`, `openvpn.instances.tls_auth`/`has_tls_auth`, `openvpn.instances.pkcs12`/`has_pkcs12`. PATCH that omits a sensitive field carries the existing value forward; rotation is explicit.\n\n## Atomicity\n\nEvery write is one transaction: snapshot, validate, commit, reload, restore-on-failure. `POST /batch` extends this across N packages under one combined snapshot/restore.\n\n## IMPORTANT - Success != runtime convergence\n\nA 2xx response means the init script's reload action **exited 0**. It does NOT mean the daemon has finished re-converging (`network/interfaces` is the dangerous one: a bad change can drop the management link, and the API has already reported success). The `X-Reload-Status` response header surfaces the reload outcome explicitly:\n\n- `X-Reload-Status: ok` - init script ran and exited 0 (not a convergence promise)\n- `X-Reload-Status: no_reload` - the resource has no reload services\n\nFor high-stakes writes (management interface, firewall defaults, uhttpd itself) verify convergence out-of-band. See [`docs/operations.md`](https://github.com/openwrt-iac/uapi/blob/main/docs/operations.md) `Success != converged` for the full contract.\n\n## Compatibility & versioning\n\nA given uapi installation serves exactly one API major. Within a major, additions are backwards-compatible: new endpoints, new optional fields, new error codes, new scopes. Breaking changes require the next major. Operators who need an older major keep that package version installed.\n\n## Upcoming in v4\n\nNothing is announced yet. Removals only happen in a major and only after a window announced in an earlier minor, so this section is where the next one will appear.\n\n## Schema annotations\n\nProperty schemas under `components.schemas.*.properties` carry two annotations beyond the standard OpenAPI shape:\n\n- **`default`**: the value uapi's `fromUci` synthesizes when the underlying uci option is absent. Standard OpenAPI 3.1 / JSON Schema 2020-12 keyword. The framework does NOT apply this default to incoming requests; it is documentation of the server-side fallback so IaC clients can keep the field sticky (Optional+Computed) instead of mistakenly treating it as caller-owned.\n- **`x-uapi-clear-on-omit`** (vendor extension, boolean): when present and `true`, the field is caller-owned and an IaC client (e.g. the terraform-provider-uapi) can safely send an explicit JSON null on `PUT`/`PATCH` to clear the underlying uci option. Absence of this flag means the field should be treated as sticky. A field with `default:` MUST NOT carry this flag, and vice versa (the framework's `lint-defaults` enforces this).\n\n## More\n\n- **GitHub:** https://github.com/openwrt-iac/uapi\n- **Terraform provider:** https://registry.terraform.io/providers/openwrt-iac/uapi\n- **APK feed install:** [/install/](../install/)\n- **Architecture, security, migration, release-process docs:** [in repo](https://github.com/openwrt-iac/uapi/tree/main/docs)",
			"contact": { "name": "uapi", "url": "https://github.com/openwrt-iac/uapi" },
			"license": { "name": "MIT", "identifier": "MIT" },
		},
		"servers": [
			{ "url": "https://{host}/api/v3",
			  "variables": { "host": { "default": "192.168.1.1" } } },
		],
		"tags": build_tags(),
		"x-tagGroups": build_tag_groups(),
		"security": [{ "bearerAuth": [] }],
		"paths": build_paths(),
		"components": {
			"schemas": build_schemas(),
			"securitySchemes": {
				"bearerAuth": {
					"type": "http",
					"scheme": "bearer",
					"description": "Token created via uapi-token on the router. Hashed (salted sha256) at rest.",
				},
			},
			"headers": {
				"WWWAuthenticateBearer": {
					"description": "RFC 7235 challenge on 401 responses",
					"schema": { "type": "string", "example": "Bearer realm=\"uapi\", error=\"invalid_token\"" },
				},
				"RetryAfter": {
					"description": "Seconds the client should wait before retrying (RFC 7231 6.6.4)",
					"schema": { "type": "integer", "minimum": 1 },
				},
				"ETag": {
					"description": "Quoted hash of the resource body (minus volatile `runtime` state). Stable across unchanged sibling sections; mutates only when the resource itself changes. Use with `If-Match` on writes (or `?if_match=` query param through uhttpd) for optimistic concurrency.",
					"schema": { "type": "string", "example": "\"a8a93ccd3144\"" },
				},
				"XRequestId": {
					"description": "ULID echoing the request_id from request (or generated server-side).",
					"schema": { "type": "string" },
				},
				"Link": {
					"description": "RFC 8288 link relations; rel=\"next\" present when more paginated items exist.",
					"schema": { "type": "string", "example": "<?cursor=c_r_01HX&limit=100>; rel=\"next\"" },
				},
				"XNextCursor": {
					"description": "Convenience companion to Link rel=next: the bare next-cursor token.",
					"schema": { "type": "string", "pattern": "^c_[A-Za-z0-9_-]+$" },
				},
				"IdempotentReplayed": {
					"description": "Set to true when a POST response was served from the Idempotency-Key cache instead of being re-applied.",
					"schema": { "type": "string", "enum": ["true"] },
				},
				"XReloadStatus": {
					"description": "Outcome of the post-commit daemon reload. `ok` = init script exited 0 (NOT a runtime-convergence promise; see docs/operations.md). `no_reload` = the resource has no reload services, which no shipped resource currently is, so responses today always say `ok`. Present on curated-resource writes only: raw passthrough, `POST /batch` and the non-uci writes do not run the reload machinery and return no reload headers at all.",
					"schema": { "type": "string", "enum": ["ok", "no_reload"] },
				},
				"XReloadServices": {
					"description": "Comma-separated list of init scripts that were reloaded after the write committed. Absent when X-Reload-Status: no_reload, and absent wherever X-Reload-Status itself is.",
					"schema": { "type": "string", "example": "firewall,dnsmasq" },
				},
				"XKernelStatus": {
					"description": "Whether the write reached the kernel as well as uci. `ok` = every targeted interface was applied. `partial` = some were skipped. `skipped` = none was, because the interface is down or netifd does not know it; uci is still committed and the change takes effect on the next ifup. `no_kernel` = the resource has no kernel path, which is the value on most writes. Absent on raw, non-uci and batch writes, which do not run the kernel apply.",
					"schema": { "type": "string", "enum": ["ok", "partial", "skipped", "no_kernel"] },
				},
				"XKernelApplied": {
					"description": "Comma-separated list of the interfaces whose kernel state was actually changed. Absent when nothing was applied, so also absent whenever X-Kernel-Status is `skipped` or `no_kernel`.",
					"schema": { "type": "string", "example": "wg0" },
				},
				"XMgmtPathWarning": {
					"description": "Advisory: the write reached the path this request arrived through, so the connection carrying it may be about to break. Two shapes. `interface=<name> changed=<fields>` when a `network/interfaces` write moved or removed the interface the request came in on. `device=<name> changed=<fields>` when a `network/bridge_vlans` or `network/devices` write targeted the caller's device, or the bridge that device is a port of: a bridge-vlan enables VLAN filtering for the whole bridge and drops untagged traffic, and a device write can change that bridge's ports. Emitted on create as well as on the three item writes, because a new section can claim the management device. The write already happened and was not refused; severing your own path is a legitimate operation. Absent when the write could not be shown to reach the caller, which includes the case where uapi cannot resolve the inbound device at all.",
					"schema": { "type": "string", "example": "interface=lan changed=ipaddr" },
				},
			},
			"responses": {
				"BadRequest":         { "description": "Malformed request (codes: bad_request, invalid_cursor)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } }, "headers": { "WWW-Authenticate": { "$ref": "#/components/headers/WWWAuthenticateBearer" } } },
				"Unauthorized":       { "description": "Missing/invalid bearer (codes: unauthorized, invalid_token; the latter also covers expired tokens and source-IP-not-permitted)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } }, "headers": { "WWW-Authenticate": { "$ref": "#/components/headers/WWWAuthenticateBearer" } } },
				"Forbidden":          { "description": "Scope or TLS check failed (codes: insufficient_scope, tls_required, scope_escalation_blocked)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"NotFound":           { "description": "Resource not found", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"Conflict":           { "description": "Conflict (codes: conflict, unmanaged_resource, idempotency_key_conflict)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"PreconditionFailed": { "description": "A precondition failed: If-Match did not match the current ETag, If-None-Match matched it (or was `*` against an existing resource), or a JSON-Patch test op failed. Preconditions are evaluated before the transaction runs, so a 412 means nothing was written", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"ValidationFailed":   { "description": "Request body failed validation (per-field errors in `errors[]`)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"Locked":             { "description": "Another write holds the same per-package lock; retry after Retry-After seconds", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } }, "headers": { "Retry-After": { "$ref": "#/components/headers/RetryAfter" } } },
				"TooManyRequests":    { "description": "Per-token rate limit exceeded; retry after Retry-After seconds", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } }, "headers": { "Retry-After": { "$ref": "#/components/headers/RetryAfter" } } },
				"InternalError":      { "description": "Server error (codes: internal_error, reload_failed_restored, reload_failed_unrecovered)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"ServiceUnavailable": { "description": "Service unavailable (codes: service_unavailable, init_script_missing)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
			},
		},
	};
}

let doc = build_doc();
let out_path = null;
for (let i = 0; i < length(ARGV); i++) {
	if (ARGV[i] == "-o") out_path = ARGV[++i];
}

let json_text = sprintf("%.J", doc);
if (out_path == null) {
	print(json_text);
	print("\n");
} else {
	let f = fs.open(out_path, "w");
	f.write(json_text);
	f.write("\n");
	f.close();
}
