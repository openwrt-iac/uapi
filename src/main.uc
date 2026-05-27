{%
'use strict';

push(REQUIRE_SEARCH_PATH, "/usr/share/uapi/lib/*.uc");

let fs = require("fs");
let errors = require("errors");

const VERSION = "1.0.0-dev";
const INSECURE_MARKER = "/etc/uapi.insecure";

function tls_check_passes(env) {
	if (env.HTTPS == "on") return true;
	let addr = env.REMOTE_ADDR ?? "";
	if (addr == "127.0.0.1" || addr == "::1" || addr == "::ffff:127.0.0.1")
		return true;
	if (fs.stat(INSECURE_MARKER) != null) return true;
	return false;
}

function send(resp) {
	uhttpd.send(sprintf("Status: %d\r\n", resp.status));
	for (let k in resp.headers)
		uhttpd.send(sprintf("%s: %s\r\n", k, resp.headers[k]));
	uhttpd.send("\r\n");
	if (resp.body == null) return;
	if (type(resp.body) == "object" || type(resp.body) == "array")
		uhttpd.send(sprintf("%J", resp.body));
	else
		uhttpd.send("" + resp.body);
}

function healthz(ctx, method) {
	if (method != "GET")
		return errors.error(ctx, "method_not_allowed", "healthz only supports GET");
	return errors.ok(ctx, { status: "ok", version: VERSION });
}

function dispatch(env) {
	let ctx = errors.new_context();

	if (!tls_check_passes(env)) {
		return errors.error(ctx, "tls_required",
		                    "HTTPS required for non-localhost requests");
	}

	let path = env.PATH_INFO ?? "/";
	let method = env.REQUEST_METHOD ?? "GET";

	if (path == "/healthz") return healthz(ctx, method);

	return errors.error(ctx, "not_found", "No handler for this path");
}

global.handle_request = function(env) {
	send(dispatch(env));
};
