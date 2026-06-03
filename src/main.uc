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
let transaction = require("transaction");
let bus = require("bus");
let packages = require("packages");
let system_access = require("system_access");
let token_store = require("token_store");
let ratelimit = require("ratelimit");
let metrics = require("metrics");
let idempotency = require("idempotency");

// /schema endpoint needs the raw resource modules; handler.make hides them.
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

// BARE variants run inside /batch's outer multi_transaction (skip own lock,
// snapshot, commit, reload). Read-only collections have no toUci and are
// excluded.
const BARE_RESOURCES = {};
const BARE_SINGLETONS = {};
for (let k in RESOURCE_SOURCES) {
	let src = RESOURCE_SOURCES[k];
	if (src.toUci == null && src.list_fn != null) continue;
	if (SINGLETONS[k] != null) BARE_SINGLETONS[k] = handler.make_singleton(src, { tx: { bare: true } });
	else if (RESOURCES[k] != null) BARE_RESOURCES[k] = handler.make(src, { tx: { bare: true } });
}

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
	"207": "Multi-Status",
	"304": "Not Modified",
	"412": "Precondition Failed",
	"429": "Too Many Requests",
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
	return token_store.list_for_auth(conn);
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
	let denied = scope.require_or_deny(errors, ctx, scopes, [domain, sub], method_verb(method),
		sprintf("this operation on %s:%s", domain, sub));
	if (denied != null) return denied;

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
		expires_at: token.expires_at ?? null,
		allowed_cidrs: token.allowed_cidrs ?? [],
		last_used_at: token.last_used_at ?? null,
		last_used_ip: token.last_used_ip ?? null,
	});
}

function tokens_translate(ctx, r) {
	if (r.ok) return errors.ok(ctx, r.body);
	if (r.kind == "validation") return errors.validation_failed(ctx, r.errors);
	if (r.kind == "conflict") return errors.error(ctx, "conflict", r.message);
	if (r.kind == "not_found") return errors.error(ctx, "not_found", r.message);
	if (r.kind == "scope_escalation_blocked")
		return errors.error(ctx, "scope_escalation_blocked",
			"Requested scopes are not a subset of the caller's scopes");
	if (r.kind == "locked") return errors.locked(ctx, 1);
	if (r.kind == "init_script_missing")
		return errors.error(ctx, "init_script_missing", r.message);
	if (r.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, r.reload_error);
	if (r.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, r.reload_error, r.restore_error);
	return errors.error(ctx, "internal_error",
		sprintf("token transaction returned unknown kind %J", r.kind));
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

// path_template lowers a concrete request path to a label that does not
// explode metric cardinality. Concrete segment values (ids, ULIDs, hex
// digests) become `<id>`; named segments (resource, package, sub) pass
// through. Without this, `uapi_requests_total` would grow unbounded as
// clients create resources.
function path_template(method, parts) {
	if (length(parts) == 0) return "/";
	let top = parts[0];
	// Top-level resources whose second segment is the resource id (not a
	// sub-resource name). Adding tokens/auth here collapses /tokens/<id> and
	// /auth/<thing> into one metric series instead of one per id.
	if (top == "tokens") {
		if (length(parts) == 1) return "/tokens";
		return "/tokens/:id";
	}
	if (top == "auth") {
		if (length(parts) == 1) return "/auth";
		if (parts[1] == "whoami") return "/auth/whoami";
		return "/auth/:id";
	}
	let out = ["/" + top];
	for (let i = 1; i < length(parts); i++) {
		let p = parts[i];
		if (i == 1 && (top == "raw" || top == "schema")) {
			// /raw/:package/:id, /schema/:package/:resource
			push(out, p);
		} else if (p == "adopt" || p == "installed" || p == "feeds"
			   || p == "password" || p == "authorized_keys") {
			push(out, p);
		} else if (i >= 2) {
			push(out, ":id");
		} else {
			push(out, p);
		}
	}
	return join("/", out);
}

function record_metrics_for(method, path, status, duration_ms) {
	let parts = split_path(path);
	let tpl = path_template(method, parts);
	if (tpl == "/healthz" || tpl == "/metrics") return;
	metrics.record_request(method, tpl, status, duration_ms);
}

// Pull (package, reload_services) from a sub-request path. Returns null if
// the path does not target a writable, batch-eligible resource.
function batch_resolve_target(parts) {
	if (length(parts) < 1) return null;
	let key, kind;
	if (length(parts) == 1) { key = parts[0]; kind = "singleton"; }
	else { key = parts[0] + ":" + parts[1]; }
	if (BARE_SINGLETONS[key]) {
		let src = RESOURCE_SOURCES[key];
		return { kind: "singleton", key, h: BARE_SINGLETONS[key],
		         package: src.package, reload: src.reload ?? [] };
	}
	if (BARE_RESOURCES[key]) {
		let src = RESOURCE_SOURCES[key];
		return { kind: "resource", key, h: BARE_RESOURCES[key],
		         package: src.package, reload: src.reload ?? [] };
	}
	return null;
}

function batch_run_one(conn, sub_ctx, scopes, op) {
	if (type(op) != "object" || type(op.method) != "string" || type(op.path) != "string")
		return { status: 400, headers: {},
		         body: { code: "bad_request",
		                 message: "sub-request must have string method + path",
		                 request_id: sub_ctx.request_id } };
	let parts = split_path(op.path);
	let domain = parts[0] ?? "";
	let sub = length(parts) >= 2 ? parts[1] : null;
	let m = op.method;
	let scope_path = sub != null ? [domain, sub] : [domain];
	let denied = scope.require_or_deny(errors, sub_ctx, scopes, scope_path, method_verb(m),
		sprintf("%s on %s", m, op.path));
	if (denied != null) return denied;

	let tgt = batch_resolve_target(parts);
	if (tgt == null)
		return errors.error(sub_ctx, "not_found",
			sprintf("No batch-eligible handler for %s", op.path));

	if (op.if_match != null) sub_ctx.if_match = op.if_match;
	sub_ctx.json_patch = false;  // batch sub-requests use merge-patch semantics

	if (tgt.kind == "singleton") {
		if (m == "GET")    return tgt.h.get(conn, sub_ctx);
		if (m == "PATCH")  return tgt.h.patch(conn, sub_ctx, op.body);
		return errors.error(sub_ctx, "method_not_allowed",
			sprintf("Method %s not allowed on %s", m, op.path));
	}

	let id = length(parts) >= 3 ? parts[2] : null;
	if (id == null) {
		if (m == "GET")  return tgt.h.list(conn, sub_ctx, {});
		if (m == "POST") return tgt.h.create(conn, sub_ctx, op.body);
		return errors.error(sub_ctx, "method_not_allowed",
			sprintf("Method %s not allowed on %s", m, op.path));
	}
	if (m == "GET")    return tgt.h.get_one(conn, sub_ctx, id);
	if (m == "PUT")    return tgt.h.replace(conn, sub_ctx, id, op.body);
	if (m == "PATCH")  return tgt.h.patch(conn, sub_ctx, id, op.body);
	if (m == "DELETE") return tgt.h.remove(conn, sub_ctx, id);
	return errors.error(sub_ctx, "method_not_allowed",
		sprintf("Method %s not allowed on %s", m, op.path));
}

function _is_write_method(m) {
	return m == "POST" || m == "PUT" || m == "PATCH" || m == "DELETE";
}

function batch_dispatch(conn, ctx, token, method, body) {
	if (method != "POST")
		return errors.error(ctx, "method_not_allowed", "batch only supports POST");
	if (type(body) != "object" || type(body.operations) != "array")
		return errors.error(ctx, "bad_request",
			"body must be {\"operations\": [{path, method, body?, if_match?}, ...]}");
	let ops = body.operations;
	if (length(ops) == 0)
		return errors.error(ctx, "bad_request", "operations must be non-empty");
	if (length(ops) > 50)
		return errors.error(ctx, "bad_request", "operations capped at 50");

	// Pre-resolve targets up-front: a typo aborts before any lock is taken.
	// Only WRITE ops contribute to the lock/reload set.
	let packages_seen = {}, reload_seen = {};
	for (let i = 0; i < length(ops); i++) {
		let op = ops[i];
		if (type(op) != "object" || type(op.path) != "string")
			return errors.error(ctx, "bad_request",
				sprintf("operations[%d] missing path", i));
		let tgt = batch_resolve_target(split_path(op.path));
		if (tgt == null)
			return errors.error(ctx, "not_found",
				sprintf("operations[%d]: no batch-eligible handler for %s", i, op.path));
		if (_is_write_method(op.method ?? "")) {
			packages_seen[tgt.package] = true;
			for (let svc in tgt.reload) reload_seen[svc] = true;
		}
	}
	let pkgs = [], reloads = [];
	for (let p in packages_seen) push(pkgs, p);
	for (let s in reload_seen) push(reloads, s);
	sort(pkgs); sort(reloads);

	let aborted = null;
	let results = [];
	let run_ops = function(c) {
		for (let i = 0; i < length(ops); i++) {
			let sub_ctx = { request_id: ctx.request_id + "." + i };
			let resp = batch_run_one(c, sub_ctx, token.scopes, ops[i]);
			push(results, { status: resp.status, body: resp.body });
			if (resp.status >= 400) {
				aborted = { index: i, envelope: resp };
				return { ok: false, kind: "batch_aborted" };
			}
		}
		return { ok: true };
	};

	let r;
	if (length(pkgs) == 0) {
		// Pure-read batch: no flock, no snapshot, no commit, no reload.
		r = run_ops(conn);
	} else {
		r = transaction.multi_transaction(conn, {
			packages: pkgs,
			reload_services: reloads,
			fn: run_ops,
		});
	}

	if (aborted != null) {
		return {
			status: aborted.envelope.status,
			headers: { "Content-Type": "application/json",
			           "X-Request-Id": ctx.request_id },
			body: {
				code: "batch_partial_failure",
				message: sprintf("batch aborted at index %d; all changes reverted",
				                 aborted.index),
				request_id: ctx.request_id,
				aborted_at_index: aborted.index,
				error: aborted.envelope.body,
				reverted: true,
			},
		};
	}

	if (r.kind == "init_script_missing")
		return errors.error(ctx, "init_script_missing", r.message);
	if (r.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, r.reload_error);
	if (r.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, r.reload_error, r.restore_error);
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("batch lock unavailable: %s", r.error));
	if (!r.ok)
		return errors.error(ctx, "internal_error",
			sprintf("batch returned unknown kind %J", r.kind));

	return {
		status: 207,
		headers: { "Content-Type": "application/json",
		           "X-Request-Id": ctx.request_id },
		body: { results, request_id: ctx.request_id },
	};
}

function metrics_response(ctx) {
	let text;
	try { text = metrics.format_prometheus(); }
	catch (e) { text = ""; }
	return {
		status: 200,
		headers: { "Content-Type": "text/plain; version=0.0.4",
		           "X-Request-Id": ctx.request_id },
		body: text,
	};
}

function diagnostics_response(ctx) {
	let resources_loaded = [];
	for (let k in RESOURCE_SOURCES) push(resources_loaded, k);
	sort(resources_loaded);

	let uptime_s = 0;
	let upf = fs.open("/proc/uptime", "r");
	if (upf) {
		let line = upf.read("line") ?? "";
		upf.close();
		let toks = split(trim(line), " ");
		if (length(toks) > 0) uptime_s = int(toks[0]);
	}

	let global_held = false;
	let pkg_held = {};
	let lock_dir_entries;
	try { lock_dir_entries = fs.lsdir("/var/lock"); } catch (_) { lock_dir_entries = []; }
	for (let name in lock_dir_entries ?? []) {
		if (name == "uapi.lock") global_held = true;
		else if (substr(name, 0, 9) == "uapi.pkg." && substr(name, length(name) - 5) == ".lock")
			pkg_held[substr(name, 9, length(name) - 14)] = true;
	}

	return errors.ok(ctx, {
		version: VERSION,
		uptime_seconds: uptime_s,
		resources_loaded,
		lock_state: { global_held, per_package: pkg_held },
		request_id: ctx.request_id,
	});
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
	// uhttpd's CGI env drops If-Match/If-None-Match/X-Request-Id/Idempotency-Key.
	// Fall back to query params; reverse proxies that forward the headers still
	// work via the header path.
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
	let body_text = "";
	if (method == "POST" || method == "PUT" || method == "PATCH") {
		body_text = read_body(env);
		if (body_text != "") {
			try { body = json(body_text); }
			catch (e) {
				return { ctx, resp: errors.error(ctx, "bad_request",
				                                 "Request body is not valid JSON") };
			}
		}
	}
	ctx.body_text = body_text;
	ctx.idempotency_key = env.HTTP_IDEMPOTENCY_KEY ?? qs.idempotency_key ?? null;
	// PATCH with Content-Type: application/json-patch+json switches the
	// handler from merge-patch (RFC 7396, the default) to RFC 6902 ops.
	let ctype = env.CONTENT_TYPE ?? "";
	ctx.json_patch = (method == "PATCH"
	                  && index(ctype, "application/json-patch+json") >= 0);

	let query = parse_query(env.QUERY_STRING);

	let conn;
	try { conn = bus.connect({ debug: LOGGING.debug }); }
	catch (e) {
		return { ctx, resp: errors.error(ctx, "service_unavailable",
		                                 "ubus unreachable") };
	}

	let tokens = load_tokens(conn);
	let now_epoch;
	try { now_epoch = time(); } catch (_) { now_epoch = null; }
	let auth_result = auth.authorize(tokens, env.HTTP_AUTHORIZATION, hash_bearer,
		{ remote_addr: env.REMOTE_ADDR, now: now_epoch });
	if (!auth_result.ok) {
		let msg;
		if (auth_result.kind == "unauthorized")
			msg = "Missing or malformed Authorization header";
		else if (auth_result.reason == "expired")
			msg = "Token expired";
		else if (auth_result.reason == "ip_not_permitted")
			msg = "Source IP not permitted for this token";
		else
			msg = "Token not recognized";
		return { ctx, resp: errors.error(ctx, auth_result.kind, msg) };
	}
	let token = auth_result.token;

	// Best-effort last-used tracking. Throttled to ~1 write/minute/token by
	// token_store. Auth has already succeeded; any failure here is silent.
	try { token_store.update_last_used(conn, token.name, env.REMOTE_ADDR, now_epoch); }
	catch (_) {}

	// Rate limit. Per-token rate/burst (uci options on the token section)
	// override the global config defaults from /etc/config/uapi.
	let rl_eff = ratelimit.effective_limits(ratelimit.load_config(conn), token);
	let rl = ratelimit.check(token.name, { now: now_epoch,
	                                       rate: rl_eff.rate,
	                                       burst: rl_eff.burst });
	if (!rl.allowed) {
		try { metrics.record_rate_limit_drop(token.name); } catch (_) {}
		let resp = errors.error(ctx, "too_many_requests",
			"Rate limit exceeded for this token");
		resp.headers["Retry-After"] = "" + rl.retry_after_seconds;
		return { ctx, token, resp };
	}

	// Idempotency for POST. A repeat of the same (token, key, body) replays
	// the cached response; a same-key/different-body POST returns 409.
	if (method == "POST" && ctx.idempotency_key != null) {
		if (!idempotency.validate_key(ctx.idempotency_key))
			return { ctx, token,
			         resp: errors.error(ctx, "bad_request",
			                            "Idempotency-Key has an invalid shape") };
		let lk = idempotency.lookup(token.name, ctx.idempotency_key,
		                            body_text, now_epoch);
		if (lk.state == "hit") {
			let cached = lk.response;
			cached.headers = cached.headers ?? {};
			cached.headers["X-Request-Id"] = ctx.request_id;
			cached.headers["Idempotent-Replayed"] = "true";
			return { ctx, token, resp: cached };
		}
		if (lk.state == "conflict")
			return { ctx, token,
			         resp: errors.error(ctx, "idempotency_key_conflict",
			                            "Idempotency-Key was previously used with a different body") };
	}

	let parts = split_path(path);

	if (path == "/metrics") {
		if (method != "GET")
			return { ctx, token,
			         resp: errors.error(ctx, "method_not_allowed",
			                            "metrics only supports GET") };
		let denied = scope.require_or_deny(errors, ctx, token.scopes, ["uapi", "metrics"], "ro",
			"reading uapi/metrics");
		if (denied != null) return { ctx, token, resp: denied };
		return { ctx, token, resp: metrics_response(ctx) };
	}

	if (path == "/batch") {
		return { ctx, token, resp: batch_dispatch(conn, ctx, token, method, body) };
	}

	if (path == "/diagnostics") {
		if (method != "GET")
			return { ctx, token,
			         resp: errors.error(ctx, "method_not_allowed",
			                            "diagnostics only supports GET") };
		let denied = scope.require_or_deny(errors, ctx, token.scopes, ["uapi", "diagnostics"], "ro",
			"reading uapi/diagnostics");
		if (denied != null) return { ctx, token, resp: denied };
		return { ctx, token, resp: diagnostics_response(ctx) };
	}

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

	if (length(parts) >= 1 && parts[0] == "tokens") {
		let id = length(parts) >= 2 ? parts[1] : null;
		if (length(parts) > 2)
			return { ctx, token,
			         resp: errors.error(ctx, "not_found", "Unknown tokens sub-path") };
		let verb = method_verb(method);
		let denied = scope.require_or_deny(errors, ctx, token.scopes, ["uapi", "tokens"], verb,
			"this operation on uapi/tokens");
		if (denied != null) return { ctx, token, resp: denied };
		let resp;
		if (method == "GET" && id == null) {
			resp = errors.ok(ctx, { tokens: token_store.list_public(conn) });
		} else if (method == "GET") {
			let rec = token_store.get_public(conn, id);
			if (rec == null) resp = errors.error(ctx, "not_found",
				sprintf("Token %J not found", id));
			else resp = errors.ok(ctx, rec);
		} else if (method == "POST" && id == null) {
			let r = token_store.create(conn, body, token.scopes, now_epoch);
			resp = tokens_translate(ctx, r);
		} else if (method == "DELETE" && id != null) {
			let r = token_store.remove(conn, id);
			if (r.ok) resp = errors.no_content(ctx);
			else resp = tokens_translate(ctx, r);
		} else {
			resp = errors.error(ctx, "method_not_allowed",
				sprintf("Method %J not allowed on tokens%s",
					method, id != null ? "/<id>" : ""));
		}
		return { ctx, token, resp };
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
			let denied = scope.require_or_deny(errors, ctx, token.scopes, singleton_scope_path,
				method_verb(method),
				sprintf("this operation on %s", join("/", singleton_scope_path)));
			if (denied != null) return { ctx, token, resp: denied };
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
		let verb = method_verb(method);
		let denied = scope.require_or_deny(errors, ctx, token.scopes, ["packages", sub], verb,
			sprintf("this operation on packages/%s", sub));
		if (denied != null) return { ctx, token, resp: denied };
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
		let verb = method_verb(method);
		let denied = scope.require_or_deny(errors, ctx, token.scopes, ["system", sub], verb,
			sprintf("this operation on system/%s", sub));
		if (denied != null) return { ctx, token, resp: denied };
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

	// Idempotency store: cache 2xx POST responses so a repeated key replays.
	// Only when the request actually carried a key (not on replay itself, the
	// replay path returns before metrics/idempotency-store).
	if (method == "POST" && token != null && ctx != null
	    && ctx.idempotency_key != null
	    && resp.status >= 200 && resp.status < 300
	    && (resp.headers == null || resp.headers["Idempotent-Replayed"] == null)) {
		try { idempotency.store(token.name, ctx.idempotency_key,
		                        ctx.body_text ?? "", resp); }
		catch (_) {}
	}

	try { record_metrics_for(method, path, resp.status, duration_ms); } catch (_) {}
	if (resp.status == 422 && resp.body != null && type(resp.body) == "object"
	    && type(resp.body.errors) == "array") {
		let parts = split_path(path);
		let resource = (length(parts) >= 2) ? (parts[0] + "." + parts[1]) : (parts[0] ?? "_root");
		for (let e in resp.body.errors) {
			try { metrics.record_validate_error(resource, e.code ?? "unknown"); }
			catch (_) {}
		}
	}
	if (resp.status == 423) {
		try { metrics.record_lock_contention("uapi"); } catch (_) {}
	}

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
