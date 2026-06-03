#!/usr/bin/ucode

'use strict';

push(REQUIRE_SEARCH_PATH, "./src/lib/*.uc");

let fs = require('fs');

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
	{ path: "/firewall/forwardings",  file: "firewall.forwardings.uc",  kind: "crud",      domain: "firewall", subresource: "forwardings" },
	{ path: "/firewall/defaults",     file: "firewall.defaults.uc",     kind: "singleton", domain: "firewall", subresource: "defaults" },
	{ path: "/network/interfaces",   file: "network.interfaces.uc",   kind: "crud", domain: "network",  subresource: "interfaces" },
	{ path: "/network/devices",      file: "network.devices.uc",      kind: "crud", domain: "network",  subresource: "devices" },
	{ path: "/network/routes",       file: "network.routes.uc",       kind: "crud", domain: "network",  subresource: "routes" },
	{ path: "/network/rules",        file: "network.rules.uc",        kind: "crud", domain: "network",  subresource: "rules" },
	{ path: "/network/bridge_vlans",     file: "network.bridge_vlans.uc",     kind: "crud", domain: "network", subresource: "bridge_vlans" },
	{ path: "/network/wireguard_peers",  file: "network.wireguard_peers.uc",  kind: "crud", domain: "network", subresource: "wireguard_peers" },
	{ path: "/wireless/devices",   file: "wireless.devices.uc",   kind: "crud", domain: "wireless", subresource: "devices" },
	{ path: "/wireless/interfaces",file: "wireless.interfaces.uc",kind: "crud", domain: "wireless", subresource: "interfaces" },
	{ path: "/dhcp/hosts",         file: "dhcp.hosts.uc",         kind: "crud", domain: "dhcp",     subresource: "hosts" },
	{ path: "/dhcp/leases",        file: "dhcp.leases.uc",        kind: "collection", domain: "dhcp", subresource: "leases" },
	{ path: "/dhcp/leases6",       file: "dhcp.leases6.uc",       kind: "collection", domain: "dhcp", subresource: "leases6" },
	{ path: "/dhcp/servers",       file: "dhcp.servers.uc",       kind: "crud",       domain: "dhcp", subresource: "servers" },
	{ path: "/dhcp/dnsmasq",       file: "dhcp.dnsmasq.uc",       kind: "singleton",  domain: "dhcp", subresource: "dnsmasq" },
	{ path: "/dhcp/odhcpd",        file: "dhcp.odhcpd.uc",        kind: "singleton",  domain: "dhcp", subresource: "odhcpd" },
	{ path: "/system",             file: "system.uc",             kind: "singleton", domain: "system" },
	{ path: "/system/timeservers", file: "system.timeservers.uc", kind: "crud",      domain: "system",   subresource: "timeservers" },
	{ path: "/dropbear/instances", file: "dropbear.instances.uc", kind: "crud",      domain: "dropbear", subresource: "instances" },
	{ path: "/uhttpd/instances",   file: "uhttpd.instances.uc",   kind: "crud",      domain: "uhttpd",   subresource: "instances" },
	{ path: "/uhttpd/certs",       file: "uhttpd.certs.uc",       kind: "crud",      domain: "uhttpd",   subresource: "certs" },
	{ path: "/unbound/server",     file: "unbound.server.uc",     kind: "singleton", domain: "unbound",  subresource: "server" },
	{ path: "/sqm/queues",         file: "sqm.queues.uc",         kind: "crud",      domain: "sqm",      subresource: "queues" },
	{ path: "/snmpd/agents",       file: "snmpd.agents.uc",       kind: "crud",      domain: "snmpd",    subresource: "agents" },
	{ path: "/snmpd/com2secs",     file: "snmpd.com2secs.uc",     kind: "crud",      domain: "snmpd",    subresource: "com2secs" },
	{ path: "/snmpd/groups",       file: "snmpd.groups.uc",       kind: "crud",      domain: "snmpd",    subresource: "groups" },
	{ path: "/snmpd/accesses",     file: "snmpd.accesses.uc",     kind: "crud",      domain: "snmpd",    subresource: "accesses" },
	{ path: "/snmpd/system",       file: "snmpd.system.uc",       kind: "singleton", domain: "snmpd",    subresource: "system" },
	{ path: "/lldpd/config",       file: "lldpd.config.uc",       kind: "singleton", domain: "lldpd",    subresource: "config" },
	{ path: "/prometheus_node_exporter_lua/config", file: "prometheus_node_exporter_lua.config.uc", kind: "singleton", domain: "prometheus_node_exporter_lua", subresource: "config" },
	{ path: "/vnstat/config",      file: "vnstat.config.uc",      kind: "singleton", domain: "vnstat",   subresource: "config" },
	{ path: "/vnstat/interfaces",  file: "vnstat.interfaces.uc",  kind: "crud",      domain: "vnstat",   subresource: "interfaces" },
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

function schema_name(endpoint) {
	return pascal(endpoint.domain) + pascal(endpoint.subresource ?? "");
}

function error_responses() {
	return {
		"400": { "$ref": "#/components/responses/BadRequest" },
		"401": { "$ref": "#/components/responses/Unauthorized" },
		"403": { "$ref": "#/components/responses/Forbidden" },
		"404": { "$ref": "#/components/responses/NotFound" },
		"409": { "$ref": "#/components/responses/Conflict" },
		"412": { "$ref": "#/components/responses/PreconditionFailed" },
		"422": { "$ref": "#/components/responses/ValidationFailed" },
		"423": { "$ref": "#/components/responses/Locked" },
		"429": { "$ref": "#/components/responses/TooManyRequests" },
		"500": { "$ref": "#/components/responses/InternalError" },
		"503": { "$ref": "#/components/responses/ServiceUnavailable" },
	};
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

function build_crud_paths(ep) {
	let schema_ref = schema_name(ep);
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
			"responses": {
				"200": {
					"description": "OK",
					"content": {
						"application/json": {
							"schema": { "type": "array",
							            "items": { "$ref": "#/components/schemas/" + schema_ref } }
						}
					}
				},
				...error_responses(),
			},
		},
		"post": {
			"summary": sprintf("Create a %s", ep.subresource),
			"requestBody": {
				"required": true,
				"content": {
					"application/json": {
						"schema": { "$ref": "#/components/schemas/" + schema_ref }
					}
				}
			},
			"responses": {
				"200": make_response(200, "Created", schema_ref),
				...error_responses(),
			},
		},
	};

	paths[ep.path + "/{id}"] = {
		"parameters": [id_param],
		"get":    { "summary": sprintf("Get one %s", ep.subresource),
		            "description": "Supports conditional GET via `If-None-Match` (or `?if_none_match=` query param for clients behind uhttpd's strict CGI env). A matching ETag returns 304 with no body.",
		            "responses": { "200": make_response(200, "OK", schema_ref),
		                           "304": { "description": "If-None-Match matched current ETag" },
		                           ...error_responses() } },
		"put":    { "summary": sprintf("Replace a %s", ep.subresource),
		            "description": "Honors `If-Match` (header or `?if_match=`). Stale ETag → 412.",
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/" + schema_ref } } } },
		            "responses": { "200": make_response(200, "Replaced", schema_ref), ...error_responses() } },
		"patch":  { "summary": sprintf("Partially update a %s", ep.subresource),
		            "description": "Default content-type uses RFC 7396 merge-patch semantics (partial object). `application/json-patch+json` selects RFC 6902 JSON Patch with ops add/remove/replace/move/copy/test (the test op enables atomic compare-and-swap without If-Match).",
		            "requestBody": { "required": true, "content": {
		              "application/json":            { "schema": { "type": "object",
		                                                            "description": "merge-patch partial body" } },
		              "application/json-patch+json": { "schema": { "$ref": "#/components/schemas/JsonPatch" } },
		            } },
		            "responses": { "200": make_response(200, "Updated", schema_ref), ...error_responses() } },
		"delete": { "summary": sprintf("Delete a %s", ep.subresource),
		            "responses": { "204": { "description": "Deleted" }, ...error_responses() } },
	};

	paths[ep.path + "/{id}/adopt"] = {
		"parameters": [id_param],
		"post": {
			"summary": sprintf("Adopt an anonymous %s", ep.subresource),
			"responses": { "200": make_response(200, "Adopted", schema_ref), ...error_responses() }
		},
	};

	return paths;
}

function build_singleton_paths(ep) {
	let schema_ref = schema_name(ep);
	return {
		[ep.path]: {
			"get":   { "summary": sprintf("Get the %s singleton", ep.domain),
			           "description": "Conditional GET via If-None-Match (or ?if_none_match=).",
			           "responses": { "200": make_response(200, "OK", schema_ref),
			                          "304": { "description": "If-None-Match matched current ETag" },
			                          ...error_responses() } },
			"patch": { "summary": sprintf("Update the %s singleton", ep.domain),
			           "description": "Merge-patch by default; `application/json-patch+json` selects RFC 6902 ops.",
			           "requestBody": { "required": true, "content": {
			             "application/json":            { "schema": { "type": "object" } },
			             "application/json-patch+json": { "schema": { "$ref": "#/components/schemas/JsonPatch" } },
			           } },
			           "responses": { "200": make_response(200, "Updated", schema_ref), ...error_responses() } },
		},
	};
}

function build_collection_paths(ep) {
	let schema_ref = schema_name(ep);
	return {
		[ep.path]: {
			"get": {
				"summary": sprintf("List %s (read-only)", ep.subresource),
				"responses": {
					"200": {
						"description": "OK",
						"content": { "application/json": {
							"schema": { "type": "array",
							            "items": { "$ref": "#/components/schemas/" + schema_ref } }
						} }
					},
					...error_responses(),
				},
			},
		},
		[ep.path + "/{id}"]: {
			"parameters": [{ "name": "id", "in": "path", "required": true,
			                 "schema": { "type": "string" } }],
			"get": { "summary": sprintf("Get one %s by id", ep.subresource),
			         "responses": { "200": make_response(200, "OK", schema_ref), ...error_responses() } },
		},
	};
}

function build_paths() {
	let paths = {};
	for (let ep in ENDPOINTS) {
		let p;
		if (ep.kind == "crud") p = build_crud_paths(ep);
		else if (ep.kind == "singleton") p = build_singleton_paths(ep);
		else if (ep.kind == "collection") p = build_collection_paths(ep);
		for (let k in p) paths[k] = p[k];
	}

	paths["/raw/{package}"] = {
		"parameters": [{ "name": "package", "in": "path", "required": true,
		                 "schema": { "type": "string" } }],
		"get": {
			"summary": "List raw uci sections for a package",
			"responses": { "200": make_response(200, "OK", "RawSection"), ...error_responses() }
		},
		"post": {
			"summary": "Create a raw uci section",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/RawSection" } } } },
			"responses": { "200": make_response(200, "Created", "RawWriteResult"), ...error_responses() }
		},
	};
	paths["/raw/{package}/{id}"] = {
		"parameters": [
			{ "name": "package", "in": "path", "required": true, "schema": { "type": "string" } },
			{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } },
		],
		"get":    { "summary": "Get a raw uci section",
		            "responses": { "200": make_response(200, "OK", "RawSection"), ...error_responses() } },
		"put":    { "summary": "Replace a raw uci section",
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/RawSection" } } } },
		            "responses": { "200": make_response(200, "Replaced", "RawWriteResult"), ...error_responses() } },
		"patch":  { "summary": "Partially update a raw uci section",
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object" } } } },
		            "responses": { "200": make_response(200, "Updated", "RawWriteResult"), ...error_responses() } },
		"delete": { "summary": "Delete a raw uci section",
		            "responses": { "204": { "description": "Deleted" }, ...error_responses() } },
	};

	paths["/packages/installed"] = {
		"get": {
			"summary": "List installed apk packages",
			"responses": { "200": {
				"description": "OK",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/InstalledPackage" } } } },
			}, ...error_responses() }
		},
		"post": {
			"summary": "Install a package (apk add)",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PackageInstallRequest" } } } },
			"responses": { "200": make_response(200, "Installed", "InstalledPackage"), ...error_responses() }
		},
	};
	paths["/packages/installed/{name}"] = {
		"parameters": [
			{ "name": "name", "in": "path", "required": true, "schema": { "type": "string" } },
		],
		"get":    { "summary": "Get info on an installed package",
		            "responses": { "200": make_response(200, "OK", "InstalledPackage"), ...error_responses() } },
		"delete": { "summary": "Remove a package (apk del)",
		            "responses": { "204": { "description": "Removed" }, ...error_responses() } },
	};
	paths["/packages/feeds"] = {
		"get": {
			"summary": "List apk feeds under /etc/apk/repositories.d",
			"responses": { "200": {
				"description": "OK",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/PackageFeed" } } } },
			}, ...error_responses() }
		},
		"post": {
			"summary": "Create a new apk feed file and run apk update",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PackageFeedCreateRequest" } } } },
			"responses": { "200": make_response(200, "Created", "PackageFeed"), ...error_responses() }
		},
	};
	paths["/packages/feeds/{id}"] = {
		"parameters": [
			{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } },
		],
		"get":    { "summary": "Get one apk feed by id",
		            "responses": { "200": make_response(200, "OK", "PackageFeed"), ...error_responses() } },
		"delete": { "summary": "Delete an apk feed and re-run apk update",
		            "responses": { "204": { "description": "Removed" }, ...error_responses() } },
	};

	paths["/system/password"] = {
		"post": {
			"summary": "Set the password for a local user (write-only; shells out to passwd)",
			"requestBody": { "required": true,
			                 "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SystemPasswordRequest" } } } },
			"responses": { "204": { "description": "Password set" }, ...error_responses() }
		},
	};
	paths["/system/authorized_keys"] = {
		"get": {
			"summary": "List installed SSH public keys",
			"responses": { "200": {
				"description": "OK",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/SSHAuthorizedKey" } } } },
			}, ...error_responses() }
		},
		"post": {
			"summary": "Add a single SSH public key",
			"requestBody": { "required": true,
			                 "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SSHKeyAddRequest" } } } },
			"responses": { "200": make_response(200, "Added", "SSHAuthorizedKey"), ...error_responses() }
		},
		"put": {
			"summary": "Replace the authorized_keys list wholesale",
			"requestBody": { "required": true,
			                 "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SSHKeyReplaceRequest" } } } },
			"responses": { "200": {
				"description": "Replaced",
				"content": { "application/json": { "schema": {
					"type": "array",
					"items": { "$ref": "#/components/schemas/SSHAuthorizedKey" } } } },
			}, ...error_responses() }
		},
	};
	paths["/system/authorized_keys/{id}"] = {
		"parameters": [
			{ "name": "id", "in": "path", "required": true, "schema": { "type": "string", "pattern": "^[a-f0-9]{12}$" } },
		],
		"get":    { "summary": "Get a single SSH key by stable id",
		            "responses": { "200": make_response(200, "OK", "SSHAuthorizedKey"), ...error_responses() } },
		"delete": { "summary": "Remove a single SSH key by stable id",
		            "responses": { "204": { "description": "Removed" }, ...error_responses() } },
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
			"responses": {
				"200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/WhoamiResponse" } } } },
				...error_responses(),
			},
		},
	};

	paths["/tokens"] = {
		"get": {
			"summary": "List all tokens (no secrets surfaced)",
			"description": "Scope: uapi:tokens:ro (or *:ro). Each entry omits salt and hash.",
			"responses": {
				"200": { "description": "OK", "content": { "application/json": { "schema": {
				  "type": "object",
				  "properties": { "tokens": { "type": "array", "items": { "$ref": "#/components/schemas/TokenMetadata" } } } } } } },
				...error_responses(),
			},
		},
		"post": {
			"summary": "Mint a new token over HTTP",
			"description": "Scope: uapi:tokens:rw (or *:rw). Requested scopes MUST be a strict subset of the caller's own; escalation returns 403 scope_escalation_blocked. The cleartext bearer is returned exactly once.",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TokenCreateRequest" } } } },
			"responses": {
				"200": { "description": "Created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TokenCreateResponse" } } } },
				...error_responses(),
			},
		},
	};
	paths["/tokens/{id}"] = {
		"parameters": [{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }],
		"get":    { "summary": "Get one token's metadata",
		            "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TokenMetadata" } } } }, ...error_responses() } },
		"delete": { "summary": "Revoke a token",
		            "responses": { "204": { "description": "Revoked" }, ...error_responses() } },
	};

	paths["/metrics"] = {
		"get": {
			"summary": "Prometheus 0.0.4 text exposition",
			"description": "Scope: uapi:metrics:ro (or *:ro). Series: uapi_requests_total, uapi_request_duration_seconds_bucket, uapi_request_duration_seconds_count, uapi_rate_limit_drops_total, uapi_lock_contention_total, uapi_validate_errors_total. Path-template labels normalize concrete ids to :id to keep cardinality bounded.",
			"responses": {
				"200": { "description": "OK", "content": { "text/plain": { "schema": { "type": "string" }, "example": "uapi_requests_total{method=\"GET\",path=\"/firewall/rules\",status=\"200\"} 42\n" } } },
				...error_responses(),
			},
		},
	};

	paths["/diagnostics"] = {
		"get": {
			"summary": "Operational snapshot (lock state, uptime, loaded resources)",
			"description": "Scope: uapi:diagnostics:ro (or *:rw).",
			"responses": {
				"200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/DiagnosticsResponse" } } } },
				...error_responses(),
			},
		},
	};

	paths["/batch"] = {
		"post": {
			"summary": "Multi-package atomic transaction",
			"description": "Each sub-request is scope-checked independently. Pure-read batches acquire no lock. Writes acquire per-package EX locks in sorted order (deadlock-free) under one combined snapshot/restore. First sub-request failure aborts the batch and reverts all packages; success returns 207 Multi-Status with the per-sub-request results. Max 50 ops.",
			"requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/BatchRequest" } } } },
			"responses": {
				"207": { "description": "Multi-Status: every sub-request succeeded", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/BatchResponse" } } } },
				...error_responses(),
			},
		},
	};

	return paths;
}

function build_schemas() {
	let schemas = {
		"ErrorEnvelope": {
			"type": "object",
			"required": ["code", "message", "request_id"],
			"properties": {
				"code": { "type": "string",
				          "enum": [
				            "bad_request", "invalid_cursor",
				            "unauthorized", "invalid_token",
				            "insufficient_scope", "scope_escalation_blocked", "tls_required",
				            "not_found", "method_not_allowed",
				            "conflict", "unmanaged_resource", "idempotency_key_conflict",
				            "precondition_failed", "unsupported_media_type",
				            "validation_failed", "locked", "too_many_requests",
				            "internal_error", "reload_failed_restored", "reload_failed_unrecovered",
				            "service_unavailable", "init_script_missing",
				            "batch_partial_failure",
				          ],
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
				"code": { "type": "string",
				          "enum": ["required","invalid_type","invalid_format",
				                  "out_of_range","not_in_enum","conflict","read_only"] },
				"message": { "type": "string" },
			},
		},
		"RawSection": {
			"type": "object",
			"required": [".type"],
			"properties": {
				"id": { "type": "string", "description": "Optional; generated if absent" },
				".type": { "type": "string" },
				"managed": { "type": "boolean" },
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
				"managed": { "type": "boolean" },
				"name": { "type": "string" },
				"version": { "type": "string", "nullable": true },
				"installed": { "type": "boolean" },
				"runtime": { "type": "object" },
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
				"managed": { "type": "boolean" },
				"name": { "type": "string" },
				"filename": { "type": "string" },
				"url": { "type": "string" },
				"enabled": { "type": "boolean" },
				"update_status": { "type": "string" },
				"runtime": { "type": "object" },
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
				"schema_properties": { "type": "object", "description": "JSON-Schema fragment for the resource body" },
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
				"rate":  { "type": ["integer", "null"], "description": "Per-token rate-limit override (req/s); null means use global" },
				"burst": { "type": ["integer", "null"], "description": "Per-token burst override; null means use global" },
			},
		},
		"TokenMetadata": {
			"allOf": [
				{ "$ref": "#/components/schemas/WhoamiResponse" },
				{ "type": "object", "required": ["name"], "properties": {
				  "name": { "type": "string", "description": "Same as token_id; field name varies by endpoint" } } },
			],
		},
		"TokenCreateRequest": {
			"type": "object",
			"required": ["name", "scopes"],
			"properties": {
				"name":   { "type": "string", "pattern": "^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$" },
				"scopes": { "type": "array", "items": { "type": "string" }, "minItems": 1,
				            "description": "MUST be a strict subset of the caller's own scopes; escalation returns 403 scope_escalation_blocked" },
				"expires_in_seconds": { "type": ["integer", "null"], "minimum": 1 },
				"allowed_cidrs":      { "type": "array", "items": { "type": "string", "description": "IPv4 CIDR" } },
			},
		},
		"TokenCreateResponse": {
			"type": "object",
			"required": ["bearer", "name"],
			"properties": {
				"bearer": { "type": "string", "writeOnly": true,
				            "description": "Cleartext bearer; returned exactly once. Store securely." },
				"name":   { "type": "string" },
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
				"body":     { "description": "Request body for POST/PUT/PATCH; omit for GET/DELETE" },
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
				else prop = { "type": "string", "nullable": true };
				properties[k] = prop;
			}
			if (type(mod.schema_properties) == "object") {
				for (let k in mod.schema_properties) properties[k] = mod.schema_properties[k];
			}
		}

		// Resource-declared runtime sub-shape: replaces the opaque
		// `runtime: {"type": "object"}` placeholder so clients can see
		// which keys a populated runtime block actually carries.
		if (type(mod.openapi_runtime) == "object" && type(properties.runtime) == "object")
			properties.runtime = mod.openapi_runtime;

		let s = {
			"type": "object",
			"description": sprintf("uapi resource backed by uci %s.%s", mod.package, mod.type),
			"properties": properties,
		};

		// Resource-declared unconditional requireds. The OpenAPI generator
		// previously emitted no `required` arrays on curated schemas,
		// forcing every client (Terraform provider, etc.) to re-derive
		// requireds by reading validate(). Module-side declaration lets
		// the spec carry the contract directly.
		if (type(mod.openapi_required) == "array" && length(mod.openapi_required) > 0)
			s.required = mod.openapi_required;

		// Resource-declared conditional requireds (if/then/required). Models
		// proto/type discriminators like "ipaddr required when proto=static".
		if (type(mod.openapi_conditional) == "array" && length(mod.openapi_conditional) > 0)
			s.allOf = mod.openapi_conditional;

		schemas[schema_name(ep)] = s;
	}

	return schemas;
}

function build_doc() {
	return {
		"openapi": "3.1.0",
		"info": {
			"title": "uapi",
			"description": "Native HTTP REST API for OpenWrt (curated + raw uci passthrough).\n\nIMPORTANT: a 2xx response to a write means the init script's reload action exited 0, NOT that the daemon has finished re-converging. Clients should not treat 200 OK as a runtime-convergence promise. See docs/operations.md `Success != converged` and the `X-Reload-Status` response header.",
			"version": VERSION,
		},
		"servers": [
			{ "url": "https://{host}/api/v2",
			  "variables": { "host": { "default": "192.168.1.1" } } },
		],
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
					"description": "Quoted body hash. Mix dependency state via depends_on. Use with If-Match for optimistic concurrency.",
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
					"description": "Outcome of the post-commit daemon reload. `ok` = init script exited 0 (NOT a runtime-convergence promise; see docs/operations.md). `no_reload` = the resource has no reload services. Absent on non-write 2xx responses.",
					"schema": { "type": "string", "enum": ["ok", "no_reload"] },
				},
				"XReloadServices": {
					"description": "Comma-separated list of init scripts that were reloaded after the write committed. Absent when X-Reload-Status: no_reload.",
					"schema": { "type": "string", "example": "firewall,dnsmasq" },
				},
			},
			"responses": {
				"BadRequest":         { "description": "Malformed request (codes: bad_request, invalid_cursor)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } }, "headers": { "WWW-Authenticate": { "$ref": "#/components/headers/WWWAuthenticateBearer" } } },
				"Unauthorized":       { "description": "Missing/invalid bearer (codes: unauthorized, invalid_token; the latter also covers expired tokens and source-IP-not-permitted)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } }, "headers": { "WWW-Authenticate": { "$ref": "#/components/headers/WWWAuthenticateBearer" } } },
				"Forbidden":          { "description": "Scope or TLS check failed (codes: insufficient_scope, tls_required, scope_escalation_blocked)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"NotFound":           { "description": "Resource not found", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"Conflict":           { "description": "Conflict (codes: conflict, unmanaged_resource, idempotency_key_conflict)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"PreconditionFailed": { "description": "If-Match did not match current ETag, or JSON-Patch test op failed", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
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
