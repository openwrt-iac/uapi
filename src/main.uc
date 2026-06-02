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
let packages = require("packages");
let system_access = require("system_access");

// RESOURCE_SOURCES retains the raw resource modules (with .schema_properties,
// .package, .type) for the /schema/<...> endpoint. The handler wrappers in
// RESOURCES/SINGLETONS do not expose these fields, so we keep a parallel map
// populated by load_resource at construction time.
const RESOURCE_SOURCES = {};

function load_resource(key, file) {
	let src = loadfile("/usr/share/uapi/resources/" + file, { raw_mode: true })();
	RESOURCE_SOURCES[key] = src;
	return src;
}

const RESOURCES = {
	"firewall:rules":        handler.make(load_resource("firewall:rules", "firewall.rules.uc")),
	"firewall:zones":        handler.make(load_resource("firewall:zones", "firewall.zones.uc")),
	"firewall:redirects":    handler.make(load_resource("firewall:redirects", "firewall.redirects.uc")),
	"firewall:forwardings":  handler.make(load_resource("firewall:forwardings", "firewall.forwardings.uc")),
	"network:interfaces":    handler.make(load_resource("network:interfaces", "network.interfaces.uc")),
	"network:devices":       handler.make(load_resource("network:devices", "network.devices.uc")),
	"network:routes":        handler.make(load_resource("network:routes", "network.routes.uc")),
	"network:rules":         handler.make(load_resource("network:rules", "network.rules.uc")),
	"network:bridge_vlans":  handler.make(load_resource("network:bridge_vlans", "network.bridge_vlans.uc")),
	"network:wireguard_peers": handler.make(load_resource("network:wireguard_peers", "network.wireguard_peers.uc")),
	"system:timeservers":  handler.make(load_resource("system:timeservers", "system.timeservers.uc")),
	"dropbear:instances":  handler.make(load_resource("dropbear:instances", "dropbear.instances.uc")),
	"uhttpd:instances":    handler.make(load_resource("uhttpd:instances", "uhttpd.instances.uc")),
	"uhttpd:certs":        handler.make(load_resource("uhttpd:certs", "uhttpd.certs.uc")),
	"wireless:devices":    handler.make(load_resource("wireless:devices", "wireless.devices.uc")),
	"wireless:interfaces": handler.make(load_resource("wireless:interfaces", "wireless.interfaces.uc")),
	"dhcp:hosts":          handler.make(load_resource("dhcp:hosts", "dhcp.hosts.uc")),
	"dhcp:leases":         handler.make_collection(load_resource("dhcp:leases", "dhcp.leases.uc")),
	"dhcp:leases6":        handler.make_collection(load_resource("dhcp:leases6", "dhcp.leases6.uc")),
	"dhcp:servers":        handler.make(load_resource("dhcp:servers", "dhcp.servers.uc")),
	"sqm:queues":          handler.make(load_resource("sqm:queues", "sqm.queues.uc")),
	"snmpd:agents":        handler.make(load_resource("snmpd:agents", "snmpd.agents.uc")),
	"snmpd:com2secs":      handler.make(load_resource("snmpd:com2secs", "snmpd.com2secs.uc")),
	"snmpd:groups":        handler.make(load_resource("snmpd:groups", "snmpd.groups.uc")),
	"snmpd:accesses":      handler.make(load_resource("snmpd:accesses", "snmpd.accesses.uc")),
	"vnstat:interfaces":   handler.make(load_resource("vnstat:interfaces", "vnstat.interfaces.uc")),
};

const SINGLETONS = {
	"system":             handler.make_singleton(load_resource("system", "system.uc")),
	"dhcp:dnsmasq":       handler.make_singleton(load_resource("dhcp:dnsmasq", "dhcp.dnsmasq.uc")),
	"dhcp:odhcpd":        handler.make_singleton(load_resource("dhcp:odhcpd", "dhcp.odhcpd.uc")),
	"firewall:defaults":  handler.make_singleton(load_resource("firewall:defaults", "firewall.defaults.uc")),
	"unbound:server":     handler.make_singleton(load_resource("unbound:server", "unbound.server.uc")),
	"snmpd:system":       handler.make_singleton(load_resource("snmpd:system", "snmpd.system.uc")),
	"lldpd:config":       handler.make_singleton(load_resource("lldpd:config", "lldpd.config.uc")),
	"prometheus_node_exporter_lua:config": handler.make_singleton(load_resource("prometheus_node_exporter_lua:config", "prometheus_node_exporter_lua.config.uc")),
	"vnstat:config":      handler.make_singleton(load_resource("vnstat:config", "vnstat.config.uc")),
};

let raw = loadfile("/usr/share/uapi/raw.uc", { raw_mode: true })();

function read_version() {
	let f = fs.open("/usr/share/uapi/VERSION", "r");
	if (!f) return "unknown";
	let v = trim(f.read("all") ?? "");
	f.close();
	return v != "" ? v : "unknown";
}

const VERSION = read_version();
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

function tls_check(env) {
	if (env.HTTPS == "on") return { ok: true, via_marker: false };
	let addr = env.REMOTE_ADDR ?? "";
	if (addr == "127.0.0.1" || addr == "::1" || addr == "::ffff:127.0.0.1")
		return { ok: true, via_marker: false };
	if (fs.stat(INSECURE_MARKER) != null) return { ok: true, via_marker: true };
	return { ok: false, via_marker: false };
}

function load_logging_config() {
	let cfg = { access: false, debug: false };
	let conn;
	try { conn = bus.connect(); } catch (e) { return cfg; }
	conn.uci_foreach('uapi', 'logging', function(s) {
		if (s.access == "1" || s.access == "true") cfg.access = true;
		if (s.debug == "1" || s.debug == "true") cfg.debug = true;
		return false;
	});
	return cfg;
}

const LOGGING = load_logging_config();

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
	let label = severity == log.LOG_NOTICE  ? "AUDIT"
	          : severity == log.LOG_INFO    ? "ACCESS"
	          : severity == log.LOG_WARNING ? "WARN"
	          :                                "ERROR";
	log.syslog(severity,
		sprintf("%s %s %s %s %s %s %d [%dms]",
			ctx.request_id,
			token_name ?? "-",
			label,
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

function healthz_response(ctx) {
	let checks = { ubus: "ok", uci: "ok", lock_dir: "ok", time_sync: "ok" };
	let errs = [];

	let conn = null;
	try {
		conn = bus.connect({ debug: LOGGING.debug });
		conn.call("system", "info", {});
	} catch (e) {
		checks.ubus = "degraded";
		push(errs, "ubus: " + e);
	}

	if (conn != null) {
		try { conn.uci_foreach('system', 'system', function(_) { return true; }); }
		catch (e) {
			checks.uci = "degraded";
			push(errs, "uci: " + e);
		}
	} else {
		checks.uci = "degraded";
	}

	let st = fs.stat("/var/lock");
	if (st == null || st.type != "directory") {
		checks.lock_dir = "degraded";
		push(errs, "lock_dir: /var/lock missing or not a directory");
	}

	let uptime_s = 0;
	let upf = fs.open("/proc/uptime", "r");
	if (upf) {
		let line = upf.read("line") ?? "";
		upf.close();
		let toks = split(trim(line), " ");
		if (length(toks) > 0) uptime_s = int(toks[0]);
	}
	let now_epoch = 0;
	try { now_epoch = time(); } catch (_) {}
	if (uptime_s < 60 || now_epoch < 1700000000) {
		checks.time_sync = (uptime_s < 60) ? "unknown" : "degraded";
		if (checks.time_sync == "degraded")
			push(errs, "time_sync: clock not synced (epoch below sanity floor)");
	}

	let degraded = false;
	for (let k in checks) if (checks[k] == "degraded") degraded = true;

	let body = { status: degraded ? "degraded" : "ok", version: VERSION, checks };
	if (length(errs) > 0) body.errors = errs;
	return {
		status: degraded ? 503 : 200,
		headers: { "Content-Type": "application/json", "X-Request-Id": ctx.request_id },
		body,
	};
}

function schema_response(ctx, parts) {
	// /schema                           → list of resource keys
	// /schema/<package>                 → all resources under that package
	// /schema/<package>/<resource>      → one resource's schema_properties
	if (length(parts) == 1) {
		let keys = [];
		for (let k in RESOURCE_SOURCES) push(keys, k);
		return errors.ok(ctx, { resources: keys });
	}
	if (length(parts) == 2) {
		let pkg = parts[1];
		let out = {};
		for (let k in RESOURCE_SOURCES) {
			let prefix = pkg + ":";
			if (k == pkg || substr(k, 0, length(prefix)) == prefix)
				out[k] = RESOURCE_SOURCES[k].schema_properties ?? null;
		}
		if (length(out) == 0)
			return errors.error(ctx, "not_found",
			                    sprintf("No schema for package %J", pkg));
		return errors.ok(ctx, out);
	}
	if (length(parts) == 3) {
		let key = parts[1] + ":" + parts[2];
		let src = RESOURCE_SOURCES[key];
		if (src == null)
			return errors.error(ctx, "not_found",
			                    sprintf("No schema for %s/%s", parts[1], parts[2]));
		return errors.ok(ctx, {
			id: key,
			package: src.package ?? null,
			type: src.type ?? null,
			schema_properties: src.schema_properties ?? null,
		});
	}
	return errors.error(ctx, "not_found", "Unknown schema sub-path");
}

function whoami_response(ctx, token, env) {
	return errors.ok(ctx, {
		token_id: token.name,
		scopes: token.scopes,
		source_ip: env.REMOTE_ADDR ?? null,
		expires_at: null,
		allowed_cidrs: [],
		last_used_at: null,
		last_used_ip: null,
	});
}

function strip_etag_quotes(s) {
	if (s == null) return null;
	let t = trim(s);
	if (substr(t, 0, 2) == "W/") t = trim(substr(t, 2));
	if (length(t) >= 2 && substr(t, 0, 1) == "\"" && substr(t, length(t) - 1, 1) == "\"")
		t = substr(t, 1, length(t) - 2);
	return t;
}

function if_none_match_matches(if_none_match, current_etag) {
	if (current_etag == null || if_none_match == null) return false;
	let want = trim(if_none_match);
	if (want == "*") return true;
	for (let entry in split(want, ",")) {
		if (strip_etag_quotes(entry) == current_etag) return true;
	}
	return false;
}

function maybe_304(resp, ctx) {
	if (ctx == null || ctx.if_none_match == null) return resp;
	if (resp.status != 200) return resp;
	if (resp.headers == null) return resp;
	let etag_header = resp.headers.ETag;
	if (etag_header == null) return resp;
	let etag = strip_etag_quotes(etag_header);
	if (!if_none_match_matches(ctx.if_none_match, etag)) return resp;
	let h = { "X-Request-Id": ctx.request_id, "ETag": etag_header };
	if (resp.headers["Cache-Control"] != null)
		h["Cache-Control"] = resp.headers["Cache-Control"];
	return { status: 304, headers: h, body: null };
}

function dispatch(env) {
	// uhttpd's CGI env has a hard-coded HTTP_* allowlist (see env_strings[]
	// in uhttpd source): If-Match, If-None-Match, and X-Request-Id are not
	// in it, so env.HTTP_* is unreliable for these. Each one falls back to
	// a query parameter (?if_match=, ?if_none_match=, ?request_id=) that
	// uhttpd forwards verbatim via QUERY_STRING. A reverse proxy in front
	// of uhttpd that propagates the headers still works via the header path.
	let qs = parse_query(env.QUERY_STRING);
	let inbound_rid = env.HTTP_X_REQUEST_ID ?? qs.request_id ?? null;
	let ctx = errors.new_context(inbound_rid);
	let method = env.REQUEST_METHOD ?? "GET";
	let path = env.PATH_INFO ?? "/";

	let tls = tls_check(env);
	if (!tls.ok)
		return { ctx, resp: errors.error(ctx, "tls_required",
		                                 "HTTPS required for non-localhost requests") };
	ctx.via_insecure_marker = tls.via_marker;
	ctx.if_match = env.HTTP_IF_MATCH ?? qs.if_match ?? null;
	ctx.if_none_match = env.HTTP_IF_NONE_MATCH ?? qs.if_none_match ?? null;

	if (path == "/openapi.json") {
		if (method != "GET")
			return { ctx, resp: errors.error(ctx, "method_not_allowed",
			                                 "openapi.json only supports GET") };
		let f = fs.open("/usr/share/uapi/openapi.json", "r");
		if (!f)
			return { ctx, resp: errors.error(ctx, "not_found", "openapi.json not installed") };
		let content = f.read("all") ?? "";
		f.close();
		return { ctx, resp: { status: 200,
		                      headers: { "Content-Type": "application/json",
		                                 "X-Request-Id": ctx.request_id },
		                      body: content } };
	}

	if (path == "/healthz") {
		if (method != "GET")
			return { ctx, resp: errors.error(ctx, "method_not_allowed",
			                                 "healthz only supports GET") };
		let resp = healthz_response(ctx);
		return { ctx, resp };
	}

	if (length(split_path(path)) >= 1 && split_path(path)[0] == "schema") {
		if (method != "GET")
			return { ctx, resp: errors.error(ctx, "method_not_allowed",
			                                 "schema only supports GET") };
		return { ctx, resp: schema_response(ctx, split_path(path)) };
	}

	let body = null;
	if (method == "POST" || method == "PUT" || method == "PATCH") {
		let body_text = read_body(env);
		if (body_text != "") {
			try { body = json(body_text); }
			catch (e) {
				return { ctx, resp: errors.error(ctx, "bad_request",
				                                 "Request body is not valid JSON") };
			}
		}
	}

	let query = parse_query(env.QUERY_STRING);

	let conn;
	try { conn = bus.connect({ debug: LOGGING.debug }); }
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

	if (length(parts) >= 1 && parts[0] == "auth") {
		if (length(parts) == 2 && parts[1] == "whoami") {
			if (method != "GET")
				return { ctx, token,
				         resp: errors.error(ctx, "method_not_allowed",
				                            "auth/whoami only supports GET") };
			return { ctx, token, resp: whoami_response(ctx, token, env) };
		}
		return { ctx, token,
		         resp: errors.error(ctx, "not_found",
		                            sprintf("Unknown auth sub-path %J",
		                                    length(parts) >= 2 ? parts[1] : "")) };
	}

	if (length(parts) >= 2 && parts[0] == "raw") {
		let pkg = parts[1];
		let id = length(parts) >= 3 ? parts[2] : null;
		let resp;
		if (id == null) {
			if (method == "GET")  resp = raw.list(conn, ctx, token.scopes, pkg);
			else if (method == "POST") resp = raw.create(conn, ctx, token.scopes, pkg, body);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on /raw/%s collection", method, pkg));
		} else {
			if (method == "GET")    resp = raw.get_one(conn, ctx, token.scopes, pkg, id);
			else if (method == "PUT")    resp = raw.replace(conn, ctx, token.scopes, pkg, id, body);
			else if (method == "PATCH")  resp = raw.patch(conn, ctx, token.scopes, pkg, id, body);
			else if (method == "DELETE") resp = raw.remove(conn, ctx, token.scopes, pkg, id);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on /raw/%s/<id>", method, pkg));
		}
		return { ctx, token, resp };
	}
	let singleton_key = null;
	let singleton_scope_path = null;
	if (length(parts) == 1) {
		singleton_key = parts[0];
		singleton_scope_path = [parts[0]];
	} else if (length(parts) == 2) {
		singleton_key = parts[0] + ":" + parts[1];
		singleton_scope_path = [parts[0], parts[1]];
	}
	if (singleton_key != null) {
		let h = SINGLETONS[singleton_key];
		if (h != null) {
			if (!scope.permits(token.scopes, singleton_scope_path, method_verb(method))) {
				return { ctx, token,
				         resp: errors.error(ctx, "insufficient_scope",
				                            sprintf("Token does not permit this operation on %s",
				                                    join("/", singleton_scope_path))) };
			}
			let resp;
			if (method == "GET") resp = h.get(conn, ctx);
			else if (method == "PATCH") resp = h.patch(conn, ctx, body);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on %s", method,
			                                 join("/", singleton_scope_path)));
			return { ctx, token, resp };
		}
	}
	if (parts[0] == "packages" && length(parts) >= 2) {
		let sub = parts[1];
		if (sub != "installed" && sub != "feeds") {
			return { ctx, token,
			         resp: errors.error(ctx, "not_found",
			                            sprintf("Unknown packages subresource %J", sub)) };
		}
		if (length(parts) > 3) {
			return { ctx, token,
			         resp: errors.error(ctx, "not_found",
			                            sprintf("Unknown sub-path under packages/%s", sub)) };
		}
		let id  = length(parts) >= 3 ? parts[2] : null;
		let scope_path = ["packages", sub];
		let verb = method_verb(method);
		if (!scope.permits(token.scopes, scope_path, verb)) {
			return { ctx, token,
			         resp: errors.error(ctx, "insufficient_scope",
			                            sprintf("Token does not permit this operation on packages/%s", sub)) };
		}
		let resp;
		if (sub == "installed") {
			if (method == "GET" && id == null)        resp = packages.list_installed(ctx);
			else if (method == "GET")                  resp = packages.get_installed(ctx, id);
			else if (method == "POST" && id == null)   resp = packages.install(ctx, body);
			else if (method == "DELETE" && id != null) resp = packages.remove_installed(ctx, id);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on packages/installed%s",
			                                 method, id != null ? "/<name>" : ""));
		} else {
			if (method == "GET" && id == null)        resp = packages.list_feeds(ctx);
			else if (method == "GET")                  resp = packages.get_feed(ctx, id);
			else if (method == "POST" && id == null)   resp = packages.create_feed(ctx, body);
			else if (method == "DELETE" && id != null) resp = packages.remove_feed(ctx, id);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on packages/feeds%s",
			                                 method, id != null ? "/<id>" : ""));
		}
		return { ctx, token, resp };
	}

	if (parts[0] == "system" && length(parts) >= 2
	    && (parts[1] == "password" || parts[1] == "authorized_keys")) {
		let sub = parts[1];
		if (length(parts) > 3) {
			return { ctx, token,
			         resp: errors.error(ctx, "not_found",
			                            sprintf("Unknown sub-path under system/%s", sub)) };
		}
		let id  = length(parts) >= 3 ? parts[2] : null;
		let scope_path = ["system", sub];
		let verb = method_verb(method);
		if (!scope.permits(token.scopes, scope_path, verb)) {
			return { ctx, token,
			         resp: errors.error(ctx, "insufficient_scope",
			                            sprintf("Token does not permit this operation on system/%s", sub)) };
		}
		let resp;
		if (sub == "password") {
			if (method == "POST" && id == null) resp = system_access.set_password(ctx, body);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on system/password%s",
			                                 method, id != null ? "/<id>" : ""));
		} else {
			if (method == "GET" && id == null)        resp = system_access.list_keys(ctx);
			else if (method == "GET")                  resp = system_access.get_key(ctx, id);
			else if (method == "POST" && id == null)   resp = system_access.add_key(ctx, body);
			else if (method == "PUT" && id == null)    resp = system_access.replace_keys(ctx, body);
			else if (method == "DELETE" && id != null) resp = system_access.remove_key(ctx, id);
			else resp = errors.error(ctx, "method_not_allowed",
			                         sprintf("Method %J not allowed on system/authorized_keys%s",
			                                 method, id != null ? "/<id>" : ""));
		}
		return { ctx, token, resp };
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
	let result;
	try {
		result = dispatch(env);
	} catch (e) {
		let ctx = errors.new_context();
		log.syslog(log.LOG_ERR,
			sprintf("uapi-internal %s: %s", ctx.request_id, "" + e));
		result = {
			ctx,
			token: null,
			resp: errors.error(ctx, "internal_error", "An internal error occurred"),
		};
	}
	let ctx = result.ctx;
	let resp = maybe_304(result.resp, ctx);
	let token = result.token;
	let method = env.REQUEST_METHOD ?? "GET";
	let path = env.PATH_INFO ?? "/";
	let end = clock(true);
	let duration_ms = int(((end[0] - start[0]) * 1000) + ((end[1] - start[1]) / 1000000));

	let is_write = method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE";
	let is_audit_path = path != "/healthz";
	let code = (resp.body != null && type(resp.body) == "object") ? resp.body.code : null;
	let token_name = token != null ? token.name : null;
	let is_auth_failure = resp.status == 401 || resp.status == 403;
	let is_server_err = resp.status >= 500;

	if (resp.status >= 200 && resp.status < 300 && is_write && is_audit_path) {
		audit_line(ctx, log.LOG_NOTICE, null, method, path, resp.status, duration_ms,
		           token_name);
	} else if ((is_auth_failure || is_server_err) && is_audit_path) {
		audit_line(ctx, is_server_err ? log.LOG_ERR : log.LOG_WARNING,
		           code, method, path, resp.status, duration_ms, token_name);
	}

	if (LOGGING.access && is_audit_path) {
		audit_line(ctx, log.LOG_INFO, code, method, path, resp.status, duration_ms,
		           token_name);
	}

	if (ctx != null && ctx.via_insecure_marker && is_audit_path) {
		log.syslog(log.LOG_NOTICE,
			sprintf("uapi-insecure-bypass %s %s %s status=%d remote=%s",
				ctx.request_id, method, path, resp.status,
				env.REMOTE_ADDR ?? "-"));
	}

	send(resp);
};
