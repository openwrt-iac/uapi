{%
'use strict';

push(REQUIRE_SEARCH_PATH, "/usr/share/uapi/lib/*.uc");

let fs = require("fs");
let log = require("log");
let digest = require("digest");
let errors = require("errors");
let auth = require("auth");
let scope = require("scope");
let handler = require("handler");
let bus = require("bus");

function load_resource(file) {
	return loadfile("/usr/share/uapi/resources/" + file, { raw_mode: true })();
}

const RESOURCES = {
	"firewall:rules":      handler.make(load_resource("firewall.rules.uc")),
	"firewall:zones":      handler.make(load_resource("firewall.zones.uc")),
	"firewall:redirects":  handler.make(load_resource("firewall.redirects.uc")),
	"network:interfaces":  handler.make(load_resource("network.interfaces.uc")),
	"network:devices":     handler.make(load_resource("network.devices.uc")),
	"wireless:devices":    handler.make(load_resource("wireless.devices.uc")),
	"wireless:interfaces": handler.make(load_resource("wireless.interfaces.uc")),
	"dhcp:hosts":          handler.make(load_resource("dhcp.hosts.uc")),
};

const SINGLETONS = {
	"system": handler.make_singleton(load_resource("system.uc")),
};

const VERSION = "1.0.0-dev";
const INSECURE_MARKER = "/etc/uapi.insecure";

const REASON = {
	"200": "OK",
	"204": "No Content",
	"400": "Bad Request",
	"401": "Unauthorized",
	"403": "Forbidden",
	"404": "Not Found",
	"405": "Method Not Allowed",
	"409": "Conflict",
	"415": "Unsupported Media Type",
	"422": "Unprocessable Entity",
	"423": "Locked",
	"500": "Internal Server Error",
	"503": "Service Unavailable",
};

log.openlog("uapi", log.LOG_PID, log.LOG_DAEMON);

function tls_check_passes(env) {
	if (env.HTTPS == "on") return true;
	let addr = env.REMOTE_ADDR ?? "";
	if (addr == "127.0.0.1" || addr == "::1" || addr == "::ffff:127.0.0.1")
		return true;
	if (fs.stat(INSECURE_MARKER) != null) return true;
	return false;
}

function send(resp) {
	let reason = REASON["" + resp.status] ?? "Status";
	uhttpd.send(sprintf("Status: %d %s\r\n", resp.status, reason));
	for (let k in resp.headers)
		uhttpd.send(sprintf("%s: %s\r\n", k, resp.headers[k]));
	uhttpd.send("\r\n");
	if (resp.body == null) return;
	if (type(resp.body) == "object" || type(resp.body) == "array")
		uhttpd.send(sprintf("%J", resp.body));
	else
		uhttpd.send("" + resp.body);
}

function read_body(env) {
	let n = int(env.CONTENT_LENGTH ?? "0");
	if (n <= 0) return "";
	return uhttpd.recv(n) ?? "";
}

function parse_query(qs) {
	let out = {};
	if (!qs) return out;
	for (let pair in split(qs, "&")) {
		if (pair == "") continue;
		let kv = split(pair, "=", 2);
		let k = uhttpd.urldecode(kv[0]);
		let v = length(kv) > 1 ? uhttpd.urldecode(kv[1]) : "";
		out[k] = v;
	}
	return out;
}

function split_path(path) {
	let parts = [];
	for (let s in split(path, "/")) if (s != "") push(parts, s);
	return parts;
}

function load_tokens(conn) {
	let tokens = [];
	conn.uci_foreach('uapi', 'token', function(s) {
		if (!s.salt || !s.hash) return;
		let scopes = type(s.scopes) == "array" ? s.scopes
		             : (s.scopes != null ? [s.scopes] : []);
		push(tokens, {
			name: s['.name'] ?? "anonymous",
			salt: s.salt,
			hash: s.hash,
			scopes: scopes,
		});
	});
	return tokens;
}

function hash_bearer(salt, bearer) {
	return digest.sha256(salt + ":" + bearer);
}

function audit_line(ctx, severity, code, method, path, status, duration_ms, token_name) {
	log.syslog(severity,
		sprintf("%s %s %s %s %s %s %d [%dms]",
			ctx.request_id,
			token_name ?? "-",
			severity == log.LOG_NOTICE ? "AUDIT"
				: (severity == log.LOG_WARNING ? "WARN" : "ERROR"),
			code ?? "-",
			method, path, status, duration_ms));
}

function method_verb(method) {
	return method == "GET" ? "ro" : "rw";
}

function dispatch_resource(h, scopes, ctx, conn, method, domain, sub, id, extra, body, query) {
	if (!scope.permits(scopes, [domain, sub], method_verb(method))) {
		return errors.error(ctx, "insufficient_scope",
		                    sprintf("Token does not permit this operation on %s:%s", domain, sub));
	}

	if (id == null) {
		if (method == "GET")  return h.list(conn, ctx, query);
		if (method == "POST") return h.create(conn, ctx, body);
		return errors.error(ctx, "method_not_allowed",
		                    sprintf("Method %J not allowed on %s/%s collection", method, domain, sub));
	}

	if (extra == "adopt") {
		if (method != "POST")
			return errors.error(ctx, "method_not_allowed", "adopt requires POST");
		return h.adopt(conn, ctx, id);
	}

	if (extra != null)
		return errors.error(ctx, "not_found", "Unknown sub-path");

	if (method == "GET")    return h.get_one(conn, ctx, id);
	if (method == "PUT")    return h.replace(conn, ctx, id, body);
	if (method == "PATCH")  return h.patch(conn, ctx, id, body);
	if (method == "DELETE") return h.remove(conn, ctx, id);
	return errors.error(ctx, "method_not_allowed",
	                    sprintf("Method %J not allowed on %s/%s/<id>", method, domain, sub));
}

function dispatch(env) {
	let ctx = errors.new_context();
	let method = env.REQUEST_METHOD ?? "GET";
	let path = env.PATH_INFO ?? "/";

	if (!tls_check_passes(env))
		return { ctx, resp: errors.error(ctx, "tls_required",
		                                 "HTTPS required for non-localhost requests") };

	if (path == "/healthz") {
		if (method != "GET")
			return { ctx, resp: errors.error(ctx, "method_not_allowed",
			                                 "healthz only supports GET") };
		let probe_err = null;
		try {
			let conn = bus.connect();
			conn.call("system", "info", {});
		} catch (e) { probe_err = "" + e; }
		if (probe_err != null) {
			let r = errors.error(ctx, "service_unavailable", "ubus probe failed");
			r.body.errors = [probe_err];
			return { ctx, resp: r };
		}
		return { ctx, resp: errors.ok(ctx, { status: "ok", version: VERSION }) };
	}

	let body = null;
	if (method == "POST" || method == "PUT" || method == "PATCH") {
		let raw = read_body(env);
		if (raw != "") {
			try { body = json(raw); }
			catch (e) {
				return { ctx, resp: errors.error(ctx, "bad_request",
				                                 "Request body is not valid JSON") };
			}
		}
	}

	let query = parse_query(env.QUERY_STRING);

	let conn;
	try { conn = bus.connect(); }
	catch (e) {
		return { ctx, resp: errors.error(ctx, "service_unavailable",
		                                 "ubus unreachable") };
	}

	let tokens = load_tokens(conn);
	let auth_result = auth.authorize(tokens, env.HTTP_AUTHORIZATION, hash_bearer);
	if (!auth_result.ok) {
		return { ctx, resp: errors.error(ctx, auth_result.kind,
		                                 auth_result.kind == "unauthorized"
		                                 ? "Missing or malformed Authorization header"
		                                 : "Token not recognized") };
	}
	let token = auth_result.token;

	let parts = split_path(path);
	if (length(parts) == 1) {
		let h = SINGLETONS[parts[0]];
		if (h != null) {
			if (!scope.permits(token.scopes, [parts[0]], method_verb(method))) {
				return { ctx, token,
				         resp: errors.error(ctx, "insufficient_scope",
				                            sprintf("Token does not permit this operation on %s",
				                                    parts[0])) };
			}
			let resp;
			if (method == "GET") resp = h.get(conn, ctx);
			else if (method == "PATCH") resp = h.patch(conn, ctx, body);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on %s", method, parts[0]));
			return { ctx, token, resp };
		}
	}
	if (length(parts) >= 2) {
		let h = RESOURCES[parts[0] + ":" + parts[1]];
		if (h != null) {
			let id = length(parts) >= 3 ? parts[2] : null;
			let extra = length(parts) >= 4 ? parts[3] : null;
			return { ctx, token,
			         resp: dispatch_resource(h, token.scopes, ctx, conn,
			                                 method, parts[0], parts[1],
			                                 id, extra, body, query) };
		}
	}

	return { ctx, token, resp: errors.error(ctx, "not_found", "No handler for this path") };
}

global.handle_request = function(env) {
	let start = clock(true);
	let result = dispatch(env);
	let resp = result.resp;
	let ctx = result.ctx;
	let token = result.token;
	let method = env.REQUEST_METHOD ?? "GET";
	let path = env.PATH_INFO ?? "/";
	let end = clock(true);
	let duration_ms = int(((end[0] - start[0]) * 1000) + ((end[1] - start[1]) / 1000000));

	let is_write = method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE";
	let is_audit_path = path != "/healthz";
	let code = (resp.body != null && type(resp.body) == "object") ? resp.body.code : null;

	if (resp.status >= 200 && resp.status < 300 && is_write && is_audit_path) {
		audit_line(ctx, log.LOG_NOTICE, null, method, path, resp.status, duration_ms,
		           token != null ? token.name : null);
	} else if (resp.status >= 400) {
		audit_line(ctx, resp.status >= 500 ? log.LOG_ERR : log.LOG_WARNING,
		           code, method, path, resp.status, duration_ms,
		           token != null ? token.name : null);
	}

	send(resp);
};
