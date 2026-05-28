#!/usr/bin/ucode

'use strict';

push(REQUIRE_SEARCH_PATH, "./src/lib/*.uc");

const VERSION = "1.0.0-rc1";

const ENDPOINTS = [
	{ path: "/firewall/rules",     file: "firewall.rules.uc",     kind: "crud", domain: "firewall", subresource: "rules" },
	{ path: "/firewall/zones",     file: "firewall.zones.uc",     kind: "crud", domain: "firewall", subresource: "zones" },
	{ path: "/firewall/redirects", file: "firewall.redirects.uc", kind: "crud", domain: "firewall", subresource: "redirects" },
	{ path: "/network/interfaces", file: "network.interfaces.uc", kind: "crud", domain: "network",  subresource: "interfaces" },
	{ path: "/network/devices",    file: "network.devices.uc",    kind: "crud", domain: "network",  subresource: "devices" },
	{ path: "/wireless/devices",   file: "wireless.devices.uc",   kind: "crud", domain: "wireless", subresource: "devices" },
	{ path: "/wireless/interfaces",file: "wireless.interfaces.uc",kind: "crud", domain: "wireless", subresource: "interfaces" },
	{ path: "/dhcp/hosts",         file: "dhcp.hosts.uc",         kind: "crud", domain: "dhcp",     subresource: "hosts" },
	{ path: "/dhcp/leases",        file: "dhcp.leases.uc",        kind: "collection", domain: "dhcp", subresource: "leases" },
	{ path: "/system",             file: "system.uc",             kind: "singleton", domain: "system" },
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
		"422": { "$ref": "#/components/responses/ValidationFailed" },
		"423": { "$ref": "#/components/responses/Locked" },
		"500": { "$ref": "#/components/responses/InternalError" },
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
		            "responses": { "200": make_response(200, "OK", schema_ref), ...error_responses() } },
		"put":    { "summary": sprintf("Replace a %s", ep.subresource),
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/" + schema_ref } } } },
		            "responses": { "200": make_response(200, "Replaced", schema_ref), ...error_responses() } },
		"patch":  { "summary": sprintf("Partially update a %s", ep.subresource),
		            "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object" } } } },
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
			           "responses": { "200": make_response(200, "OK", schema_ref), ...error_responses() } },
			"patch": { "summary": sprintf("Update the %s singleton", ep.domain),
			           "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object" } } } },
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

	paths["/healthz"] = {
		"get": {
			"summary": "Liveness check (no auth required)",
			"security": [],
			"responses": {
				"200": {
					"description": "OK",
					"content": { "application/json": { "schema": {
						"type": "object",
						"properties": {
							"status": { "type": "string", "enum": ["ok"] },
							"version": { "type": "string" },
						},
					} } }
				},
				"503": { "description": "ubus unreachable" },
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
				"code": { "type": "string" },
				"message": { "type": "string" },
				"request_id": { "type": "string" },
				"errors": { "type": "array",
				            "items": { "$ref": "#/components/schemas/FieldError" } },
				"reload_error": { "type": "string" },
				"restore_error": { "type": "string" },
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
	};

	for (let ep in ENDPOINTS) {
		let mod = load_resource(ep.file);
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

		let properties = {};
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

		schemas[schema_name(ep)] = {
			"type": "object",
			"description": sprintf("uapi resource backed by uci %s.%s", mod.package, mod.type),
			"properties": properties,
		};
	}

	return schemas;
}

function build_doc() {
	return {
		"openapi": "3.1.0",
		"info": {
			"title": "uapi",
			"description": "Native HTTP REST API for OpenWrt (curated + raw uci passthrough)",
			"version": VERSION,
		},
		"servers": [
			{ "url": "https://{host}/api/v1",
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
			"responses": {
				"BadRequest":       { "description": "Malformed request",      "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"Unauthorized":     { "description": "Missing or invalid bearer", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"Forbidden":        { "description": "Scope or TLS check failed", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"NotFound":         { "description": "Resource not found",     "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"Conflict":         { "description": "Conflict (unmanaged, already exists, etc.)", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"ValidationFailed": { "description": "Request body failed validation",      "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"Locked":           { "description": "Another write transaction holds the global lock", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
				"InternalError":    { "description": "Server error",           "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorEnvelope" } } } },
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
	let fs = require('fs');
	let f = fs.open(out_path, "w");
	f.write(json_text);
	f.write("\n");
	f.close();
}
