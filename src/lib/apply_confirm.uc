let fs = require('fs');

// Thin wrapper around the apply-confirm CLI (a separate OpenWrt package). uapi
// invokes it, never absorbs it: the rollback timer and durable state live in
// apply-confirm's procd supervisor, so uapi keeps its zero-daemon footprint.
// The integration is optional - when the binary is absent the confirm surface
// degrades to 501 and ordinary writes are unaffected.
const BIN = "/usr/sbin/apply-confirm";

// Package and service names that reach the shell. Matches transaction.uc's
// SAFE_NAME_RE. popen runs the string through sh, so every interpolated value
// is validated against this BEFORE it is concatenated - that is the injection
// control (ucode fs.popen has no argv-vector form).
const NAME_RE = /^[A-Za-z0-9_-]+$/;
// apply-confirm token: ac_<unixtime>_<8 lowercase hex> (see its cli-contract).
const TOKEN_RE = /^ac_[0-9]+_[0-9a-f]{8}$/;

function ac_present() {
	return fs.stat(BIN) != null;
}

function _run(args) {
	let p = fs.popen(BIN + " " + args, "r");
	if (p == null) return { exit: -1, out: "" };
	let out = trim(p.read("all") ?? "");
	let exit = p.close();
	return { exit, out };
}

// Snapshot `packages`, arm a `timeout`-second rollback that reloads `services`
// on restore. Returns { ok: true, token, timeout, deadline } or
// { ok: false, kind, message } with kind a registered error code.
function ac_stage(packages, services, timeout) {
	if (type(timeout) != "int" || timeout <= 0)
		return { ok: false, kind: "bad_request",
		         message: "confirm timeout must be a positive integer" };
	if (type(packages) != "array" || length(packages) == 0)
		return { ok: false, kind: "confirm_stage_failed",
		         message: "no packages to stage" };

	let args = "stage --timeout " + timeout;
	for (let pkg in packages) {
		if (type(pkg) != "string" || !match(pkg, NAME_RE))
			return { ok: false, kind: "confirm_stage_failed",
			         message: sprintf("unsafe package name %J", pkg) };
		args += " --package " + pkg;
	}
	for (let svc in (services ?? [])) {
		if (type(svc) != "string" || !match(svc, NAME_RE))
			return { ok: false, kind: "confirm_stage_failed",
			         message: sprintf("unsafe service name %J", svc) };
		args += " --service " + svc;
	}

	if (!ac_present())
		return { ok: false, kind: "confirm_unavailable",
		         message: "apply-confirm is not installed" };

	let r = _run(args);
	if (r.exit == 0) {
		if (!match(r.out, TOKEN_RE))
			return { ok: false, kind: "confirm_stage_failed",
			         message: sprintf("apply-confirm returned an unrecognized token %J", r.out) };
		return { ok: true, token: r.out, timeout, deadline: time() + timeout };
	}
	if (r.exit == 3)
		return { ok: false, kind: "already_armed",
		         message: "another apply is already armed (one pending apply at a time)" };
	if (r.exit == 2)
		return { ok: false, kind: "bad_request",
		         message: "apply-confirm rejected the stage parameters" };
	return { ok: false, kind: "confirm_stage_failed",
	         message: sprintf("apply-confirm stage failed (exit %d)", r.exit) };
}

function _control(verb, token) {
	if (!match(token ?? "", TOKEN_RE))
		return { ok: false, kind: "bad_request", message: "malformed confirm token" };
	if (!ac_present())
		return { ok: false, kind: "confirm_unavailable",
		         message: "apply-confirm is not installed" };
	let r = _run(verb + " " + token);
	return { ok: r.exit == 0, exit: r.exit, out: r.out };
}

// ack: confirm the pending apply so it is NOT rolled back.
function ac_ack(token) {
	let r = _control("ack", token);
	if (r.kind != null) return r;
	if (r.exit == 0) return { ok: true };
	if (r.exit == 4)
		return { ok: false, kind: "confirm_window_closed",
		         message: "no such token, or the confirm window already closed" };
	return { ok: false, kind: "confirm_stage_failed",
	         message: sprintf("apply-confirm ack failed (exit %d)", r.exit) };
}

// rollback: restore the snapshot now (early/forced revert).
function ac_rollback(token) {
	let r = _control("rollback", token);
	if (r.kind != null) return r;
	if (r.exit == 0) return { ok: true };
	if (r.exit == 4)
		return { ok: false, kind: "confirm_window_closed",
		         message: "no such token, or nothing pending" };
	if (r.exit == 5)
		return { ok: false, kind: "rollback_reload_failed",
		         message: "config WAS restored but a service reload failed; check logread" };
	return { ok: false, kind: "confirm_stage_failed",
	         message: sprintf("apply-confirm rollback failed (exit %d)", r.exit) };
}

// status / list are read passthroughs returning apply-confirm's JSON verbatim.
function ac_status(token) {
	if (!match(token ?? "", TOKEN_RE))
		return { ok: false, kind: "bad_request", message: "malformed confirm token" };
	if (!ac_present())
		return { ok: false, kind: "confirm_unavailable", message: "apply-confirm is not installed" };
	let r = _run("status " + token + " --json");
	if (r.exit == 0) return { ok: true, json: r.out };
	if (r.exit == 4)
		return { ok: false, kind: "not_found", message: "no such token" };
	return { ok: false, kind: "confirm_stage_failed",
	         message: sprintf("apply-confirm status failed (exit %d)", r.exit) };
}

function ac_list() {
	if (!ac_present())
		return { ok: false, kind: "confirm_unavailable", message: "apply-confirm is not installed" };
	let r = _run("list --json");
	if (r.exit == 0) return { ok: true, json: r.out };
	return { ok: false, kind: "confirm_stage_failed",
	         message: sprintf("apply-confirm list failed (exit %d)", r.exit) };
}

return { ac_present, ac_stage, ac_ack, ac_rollback, ac_status, ac_list };
