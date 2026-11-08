let fs = require('fs');
let wg = require('wg');
let limits = require('limits');
let write_journal = require('write_journal');

// Lock layout (introduced to let concurrent writes to different uci packages
// proceed in parallel without losing the apk-vs-uci serialization guarantee):
//
//   /var/lock/uapi.lock              shared by uci transactions, exclusive
//                                     by non-uci writes (apk, system/access,
//                                     cron_jobs)
//   /var/lock/uapi.pkg.<package>.lock exclusive per-package; serializes
//                                     writes to the same uci package only
//
// A uci transaction takes SH on the global + EX on its per-package file.
// Two transactions on different packages: both SH on global (compatible),
// each EX on its own file -> parallel.
// Two on the same package: both SH on global, only one EX on the package
// file -> serialized on the package one.
// A non-uci write takes EX on the global. Every acquire here is LOCK_NB, so it does not
// wait: it fails immediately and the caller answers 423 rather than queueing.
const LOCK_PATH = "/var/lock/uapi.lock";
const PKG_LOCK_PREFIX = "/var/lock/uapi.pkg.";
// Same charset for both: uci package names and init-script names must match
// /^[A-Za-z0-9_-]+$/ before we let them anywhere near a shell command or path.
const SAFE_NAME_RE = /^[A-Za-z0-9_-]+$/;

// Fail-fast before any uci write if a target init script is missing. The
// alternative path stages+commits, fails reload with exit 127, fails the
// restore-reload identically, and reports `reload_failed_unrecovered` -
// misleading since uci IS in a clean state.
function default_check_services(services) {
	for (let svc in services) {
		if (type(svc) != "string" || !match(svc, SAFE_NAME_RE))
			return sprintf("refusing to reload service with unsafe name %J", svc);
		let path = "/etc/init.d/" + svc;
		if (fs.stat(path) == null)
			return sprintf("init script %s not found (is the daemon installed?)", path);
	}
	return null;
}

function installed(services, check_services) {
	return filter(services ?? [], (svc) => check_services([ svc ]) == null);
}

// A daemon that reads the package but that an image can lack or that the operator stopped, as
// dnsmasq, odhcpd and unbound read dhcp, is reloaded when a LuCI save reloads it: while procd lists
// its service with a config.change trigger, whatever its instances show. `stop` removes the service
// and its triggers. procd lists a service before it has one too: at boot, unbound.init registers
// only a trigger on interface events, which starts unbound 3 s after the last of them, and a write
// then started unbound early. A system write reaches unbound only through ucitrack's `affects`, so
// any config trigger counts. The reload of dnsmasq.init and unbound.init starts a stopped daemon,
// and refusing the write would answer 503 on every router without it. When the ubus call fails,
// whether procd holds the service is unknown, and skipping it would answer 2xx with a daemon on its
// old config. The write asks procd only once it holds the locks of every such daemon that is
// installed: asked before them, a write that skipped a stopped unbound took no lock of it, and a
// write to unbound at the same moment started unbound on the config from before the commit.
function with_config_trigger(conn, services) {
	return filter(services, function(svc) {
		let r = null;
		try { r = conn.call("service", "list", { name: svc, verbose: true }); } catch (e) { return true; }
		return length(filter(r?.[svc]?.triggers ?? [], (t) => t[0] == "config.change")) > 0;
	});
}

// A write into a config file that does not exist stores nothing, and the uci cursor raises
// nothing either, so this answers first. Nothing on the box created the file: the package that
// ships it is missing, or, for `wireless`, the radio that `wifi config` would have described.
function missing_config(conn, pkg) {
	if (conn.uci_package_exists(pkg)) return null;
	return sprintf("/etc/config/%s not found: the package or hardware that creates it is missing on this router", pkg);
}

// A popen held the request until every process that held its pipe closed it, and uhttpd killed the
// request at its 60 s script timeout, with no restore and no answer. Killing a reload at a bound does
// not help: a child of the script, such as fw4, runs on and holds the lock that procd_lock of
// rc.common takes for the service, so the reload of the restore waited on it and was killed too.
// So uapi waits for the reloads of a request, those of the restore included, for 20 s in all, and
// then answers without them: they run on, and the write keeps its commit and answers unverified.
// 20 s, the checks after the reloads, the 8 s that the wireguard apply and the 8 s that the reconcile
// of its restore wait for netifd, and the flock wait of a restore fit in the 60 s for a write of one
// package.
const RELOAD_MS = 20000;

function now_ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000;
}

// One shell runs the reloads in order, stops at the first that fails, and writes the exit code of
// each to a file. system() with a timeout kills its child and blocks SIGCHLD in it, and the mask
// outlives exec, so a script that runs `x & wait` hung. Without one it waits only for the shell
// that puts the reloads in the background. uapi reads the file through /proc, because the shell
// moves the offset of the descriptor that both hold. `budget` is shared by the reloads of a request.
function default_reload(services, budget, init_dir) {
	for (let svc in services)
		if (type(svc) != "string" || !match(svc, SAFE_NAME_RE))
			return sprintf("refusing to reload service with unsafe name %J", svc);
	if (length(services) == 0) return null;
	budget ??= {};
	budget.ms ??= RELOAD_MS;
	budget.until ??= now_ms() + budget.ms;
	let n = length(services);
	let files = map([ ...services, null ], () => fs.mkstemp("uapi-reload"));
	let read = (f) => fs.readfile("/proc/self/fd/" + f.fileno()) ?? "";
	let unstarted = (why) => sprintf("could not start the reload of %s: %s", join(", ", services), why);
	let err = null;
	if (index(files, null) >= 0)
		err = unstarted("cannot create a file for its output");
	else {
		// The output of a script can take the last pages of a full tmpfs, and an exit code that
		// then cannot be written reads as a reload still running, so a failed reload answered
		// unverified with no restore. A code written over bytes reserved here needs no new page.
		let pad = join("", map(services, () => "    "));
		files[n].write(pad);
		files[n].flush();
		files[n].seek(0);
		if (read(files[n]) != pad)
			err = unstarted("cannot reserve a file for its exit codes");
	}
	if (err == null) {
		// Each script keeps only its own output, on stdout and stderr. busybox ash 1.38 also closed
		// a descriptor of 10 or above in the calling shell for `cmd N>&-`, so a subshell closes them.
		let fds = map(files, (f) => f.fileno());
		let closed = join(" ", map(fds, (fd) => fd + ">&-"));
		let steps = map(services, (svc, i) => sprintf("(exec %s; exec %s reload) >&%d 2>&1; c=$?; echo $c >&%d; [ $c = 0 ] || exit",
			closed, wg.command_line([ (init_dir ?? "/etc/init.d") + "/" + svc ]), fds[i], fds[n]));
		try {
			let code = system(sprintf("(%s) </dev/null >/dev/null 2>&1 &", join("; ", steps)));
			if (code != 0) err = unstarted(sprintf("the shell exited with code %d", code));
		} catch (e) {
			err = unstarted(e.message);
		}
	}
	while (err == null) {
		let done = split(read(files[n]), "\n");
		pop(done);
		let k = length(done);
		if (k > 0 && done[k - 1] != "0")
			err = sprintf("%s exited with code %s: %s", services[k - 1], done[k - 1], trim(read(files[k - 1])));
		else if (k == n)
			break;
		else if (now_ms() >= budget.until)
			err = { unverified: sprintf("%s reload was still running when the %g s that uapi waits for the reloads "
			                            + "of a request ran out, so its result is unknown%s", services[k], budget.ms / 1000.0,
			                            (k + 1 < n) ? sprintf(", and the reloads of %s follow it unless it fails",
			                                                  join(", ", slice(services, k + 1))) : "") };
		else
			sleep(20);
	}
	for (let f in files)
		if (f != null) f.close();
	return err;
}

// procd starts the daemon with its new config on its own, so the init script answers 0 before the
// daemon has read that config. unbound exits within a few hundred ms on a line that it cannot parse,
// and procd starts it again only 5 s later, to fail the same way. A reload of these services waits
// for the daemons that ran before the write to keep running. Writes to two packages that restart
// one daemon also take the lock of the package named after it, because a restart that one starts
// would read as a stop to the other, and its config as the other's.
const STAY_UP = { unbound: [ "unbound" ], "unbound-uci-ext": [ "unbound" ] };

function stay_up_daemons(services) {
	let daemons = {};
	for (let svc in services)
		for (let d in STAY_UP[svc] ?? []) daemons[d] = true;
	return keys(daemons);
}

function instances(conn, daemons) {
	let out = {};
	for (let d in daemons) {
		let r = null;
		try { r = conn.call("service", "list", { name: d }); } catch (e) {}
		for (let name, i in r?.[d]?.instances ?? {})
			out[d + "/" + name] = i;
	}
	return out;
}

// The restore runs the same check, so it fails when the previous config does not bring the daemon
// back either. An instance that `service list` does not show is being restarted, by `restart` or by
// another writer, or the ubus call failed, so only one that procd reports as not running counts.
function default_watch(conn, services, total_ms, step_ms) {
	let names = stay_up_daemons(services);
	if (length(names) == 0) return null;
	let was = instances(conn, names);
	let before = filter(keys(was), (k) => was[k].running);
	if (length(before) == 0) return null;
	return function(only) {
		let watched = (only == null) ? before
			: filter(before, (k) => index(stay_up_daemons(only), split(k, "/")[0]) >= 0);
		if (length(watched) == 0) return null;
		for (let waited = 0; ; waited += step_ms) {
			let now = instances(conn, names);
			for (let k in watched)
				if (now[k] != null && !now[k].running)
					return sprintf("%s stopped after the reload%s", split(k, "/")[0],
					               (now[k]?.exit_code != null) ? sprintf(", with exit code %d", now[k].exit_code) : "");
			if (waited >= total_ms) return null;
			sleep(step_ms);
		}
	};
}

// A popen has no time bound, so a conf-file on a mount that hangs held the locks until uhttpd
// killed the request at its 60 s script timeout, before any restore. A write that fails runs the
// check twice, and the parse of a conf-dir with 500k adblock lines took 0.6 s on x86. The exec
// makes dnsmasq the child that system() kills, and procd starts dnsmasq with stdin on /dev/null.
// system() raises when fork fails, after the commit, where a throw would skip the restore. The
// SIGCHLD that system() blocks harms no --test, which starts no child.
const DNSMASQ_TEST_MS = 10000;

function run_test(argv, timeout_ms) {
	let out = fs.mkstemp("uapi-dnsmasq-test");
	if (out == null) return { code: -1, output: "cannot create a file for its output" };
	let code = null;
	try {
		code = system(sprintf("exec %s </dev/null >&%d 2>&1", wg.command_line(argv), out.fileno()), timeout_ms);
	} catch (e) {
		out.close();
		return { code: -1, output: e.message };
	}
	out.seek(0);
	let output = out.read("all") ?? "";
	out.close();
	return { code, output };
}

// dnsmasq.init writes the config of each instance before it returns, and procd then restarts the
// instance. A watch of the process cannot judge that config: reload_service() sends SIGHUP right
// after the restart, and on a slow machine the signal can reach the new dnsmasq before it installs
// its handler, so dnsmasq dies and procd starts it again 5 s later. `--test` parses the config and
// the files that it includes, and exits: a config that dnsmasq parses but cannot start with, such
// as one whose port another daemon holds, passes. Every instance is checked, one that the race
// left stopped included, since procd starts it on that config. An instance that `service list`
// does not show after the reload, which another writer restarts or a failed ubus call hides, is
// checked with its command from before. A parse that was killed, by the time bound or by another
// SIGKILL such as the OOM killer's, which uapi cannot tell apart, judges nothing: the check answers
// { unverified } instead of a refusal, and the write keeps its commit.
function dnsmasq_check(conn, services, run) {
	if (index(services, "dnsmasq") < 0) return null;
	let was = instances(conn, [ "dnsmasq" ]);
	return function(only) {
		if (only != null && index(only, "dnsmasq") < 0) return null;
		let unverified = null;
		for (let k, i in { ...was, ...instances(conn, [ "dnsmasq" ]) }) {
			let cmd = i.command;
			if (type(cmd) != "array" || !match(cmd[0], /\/dnsmasq$/)) continue;
			let name = split(k, "/")[1];
			let r = run([ cmd[0], "--test", ...slice(cmd, 1) ]);
			if (r.code == -9)
				unverified ??= { unverified: sprintf("dnsmasq --test did not finish on its config %s: it was killed, "
				                                     + "by the time bound or another SIGKILL, so whether dnsmasq takes the "
				                                     + "config is unknown", name) };
			else if (r.code == -1)
				return sprintf("dnsmasq --test could not run on its config %s: %s", name, r.output);
			else if (r.code != 0)
				return sprintf("dnsmasq refuses its config %s: %s", name,
				               replace(split(trim(r.output), "\n")[0], /^dnsmasq: /, ""));
		}
		return unverified;
	};
}

// The reload and the restore each run every check, and the first refusal fails them. A system
// write reloads dnsmasq for the hostname and NTP, and an old refusal or a slow parse of its config
// must not fail or undo that write, so only a dhcp write runs the dnsmasq check.
function check_daemons(conn, services, packages, test_ms) {
	let checks = filter([ (index(packages ?? [], "dhcp") >= 0)
	                      ? dnsmasq_check(conn, services, (argv) => run_test(argv, test_ms ?? DNSMASQ_TEST_MS)) : null,
	                      default_watch(conn, services, 2000, 100) ],
	                    (c) => c != null);
	return function(only) {
		let unverified = null;
		for (let c in checks) {
			let err = c(only);
			if (type(err) == "object") unverified ??= err;
			else if (err != null) return err;
		}
		return unverified;
	};
}

// `only` limits the checks to the daemons of those services, the ones that a restore reloaded.
function run_check(watch, only) {
	let r = (watch.check != null) ? watch.check(only) : null;
	if (type(r) != "object") return r;
	watch.unverified = r.unverified;
	return null;
}

function with_unverified(result, watch) {
	if (!result?.ok || watch.unverified == null) return result;
	return { ...result, reload_status: "unverified", unverified: watch.unverified };
}

// Open + flock a single file. mode is "x" (exclusive) or "s" (shared); always
// non-blocking ("n" suffix). Returns the fd handle on success; null on lock
// contention; { unavailable: <path> } on infrastructure failure (fs.open).
//
// "e" is O_CLOEXEC. An flock belongs to the open file description, and without "e" every
// child started under the lock (an init script, apk, passwd, wg) held a copy of it. A request
// that uhttpd killed then left its lock held until that child exited, or for as long as a
// daemon that the child started outside procd ran. With no copy, the close in _release_one(),
// or the exit of a killed request, releases the lock.
function _lock_one(path, mode) {
	let fd = fs.open(path, "w+e");
	if (!fd) return { unavailable: "" + path };
	let r = fd.lock(mode + "n");
	if (r !== true) { fd.close(); return null; }
	return fd;
}

function _release_one(fd) {
	if (fd) fd.close();
}

// Default global-exclusive lock; used by non-uci writes (apk, system/access).
// Backward-compatible signature: ignores extras, returns a single fd.
function default_acquire(path) {
	return _lock_one(path ?? LOCK_PATH, "x");
}

function default_release(handle) {
	_release_one(handle);
}

// Per-package uci-transaction lock. Holds SH on the global, EX on the
// per-package file of `package` and of each package in `also`, taken in
// sorted order as multi_transaction takes them. Returns { _g, _p } on
// success, or one of:
//   { contention: "global" }  - non-uci writer holds the global EX
//   { contention: "package", package } - another uci writer holds the EX
//                                        of that package
//   { unavailable: <path> }   - file open failed (infrastructure)
// The contention distinction feeds the 423 message identity so the
// caller learns which lock blocked them. prefix is for the tests, as in
// multi_transaction().
function default_acquire_pkg(global_path, package, also, prefix) {
	if (type(package) != "string" || !match(package, SAFE_NAME_RE))
		return { unavailable: sprintf("invalid package name %J", package) };
	let g = _lock_one(global_path ?? LOCK_PATH, "s");
	if (g == null) return { contention: "global" };
	if (type(g) == "object" && g.unavailable != null) return g;
	let held = [];
	for (let name in sort([ package, ...(also ?? []) ])) {
		let p = _lock_one((prefix ?? PKG_LOCK_PREFIX) + name + ".lock", "x");
		if (p == null || type(p) == "object" && p.unavailable != null) {
			for (let h in held) _release_one(h);
			_release_one(g);
			return (p == null) ? { contention: "package", package: name } : p;
		}
		push(held, p);
	}
	return { _g: g, _p: held };
}

function default_release_pkg(handle) {
	if (handle == null) return;
	for (let h in handle._p) _release_one(h);
	_release_one(handle._g);
}

// For a writer outside a request, such as uapi-token, which waits rather than answer 423.
// Every acquire here is non-blocking, so it polls. Returns the locks, an unavailable path, or
// the last contention once wait_ms has passed.
function acquire_pkg_waiting(package, wait_ms, global_path, prefix) {
	for (let waited = 0; ; waited += 100) {
		let lock = default_acquire_pkg(global_path, package, null, prefix);
		if (lock._g != null || lock.unavailable != null || waited >= wait_ms) return lock;
		sleep(100);
	}
}

// A write with no kernel path at all is distinct from one whose every target was
// skipped: without that distinction an absent header cannot tell a caller which
// of the two it got, which is the whole point of reporting this.
function _kernel_status(ops, applied) {
	let targets = wg.interfaces_of(ops);
	if (length(targets) == 0) return "no_kernel";
	if (length(applied) == 0) return "skipped";
	return (length(applied) == length(targets)) ? "ok" : "partial";
}

function _finalize_after_reload(reload_err, restore_fn, body, services, ops, applied) {
	if (reload_err == null) {
		return { ok: true, body: body,
		         reload_services: services,
		         reload_status: (length(services) > 0) ? "ok" : "no_reload",
		         kernel_applied: applied ?? [],
		         kernel_status: _kernel_status(ops ?? [], applied ?? []) };
	}

	// restore_fn pushes to `left` why it left a package as it is, see put_back().
	let left = [], errs = [];
	try {
		let r2 = restore_fn(left);
		if (type(r2) == "object") push(errs, "reload during restore did not finish: " + r2.unverified);
		else if (r2 != null) push(errs, "reload during restore failed: " + r2);
	} catch (e) {
		push(errs, "" + e);
	}
	let restore_err = join("; ", [ ...left, ...errs ]);

	if (restore_err != "")
		return { ok: false, kind: "reload_failed_unrecovered",
		         reload_error: reload_err, restore_error: restore_err };
	return { ok: false, kind: "reload_failed_restored",
	         reload_error: reload_err };
}

// LuCI and a shell take no uapi lock, so they can commit to a package while its daemons reload,
// into the file that the request committed. The snapshot predates that commit, so the restore leaves
// such a package as it is rather than undo both. Returns why it left the package, or null.
function put_back(conn, pkg, snapshot, stored) {
	if (snapshot == null || stored == null)
		return sprintf("the file of the package %s could not be read %s the commit of the request, so the "
		               + "restore left it as it is", pkg, (snapshot == null) ? "before" : "after");
	if (conn.uci_import(pkg, snapshot, stored)) return null;
	return sprintf("another writer committed to the package %s after the commit of the request, so the "
	               + "restore left it as that writer left it", pkg);
}

// Only here is it known that nothing stays written: in a batch, the restore of the packages that
// it committed can still fail.
function conflict_result(message) {
	return { ok: false, kind: "conflict", message: message + ". Nothing was written. A retry reads the new state." };
}

function run_inner(conn, pkg, services, fn, apply, restore, ops, applied, request_id) {
	let result = fn(conn, pkg);

	if (!result || result.ok === false) {
		conn.uci_revert(pkg);
		return result ?? { ok: false, kind: "unknown" };
	}

	// The file that the commit replays over, so the restore undoes the writes of the request and
	// keeps what another writer committed while the request ran. Taken when the lock was, it put back
	// the file from before such a commit.
	let snapshot = conn.uci_export(pkg);
	// The journal record is written before the commit and under the lock, so the record and the
	// commit are ordered together: a request that uhttpd kills after the commit leaves the
	// record behind, and /diagnostics reports it as an interrupted write.
	let staged = [];
	conn.uci_foreach(pkg, null, function(s) { push(staged, s['.name']); });
	write_journal.record_start([pkg], request_id, staged);
	let committed = conn.uci_commit(pkg);
	if (type(committed) == "object")
		return conflict_result(committed.conflict);
	// A package that the write left as it was gets no reload, which would read the same config
	// again, and no restore, which would put the snapshot over what another writer committed since.
	if (!committed)
		return { ..._finalize_after_reload(null, null, result.body, [], ops, applied), unchanged: true };

	write_journal.mark_reload_started();
	let stored = conn.uci_export(pkg);
	return _finalize_after_reload(apply(), function(left) {
		let why = put_back(conn, pkg, snapshot, stored);
		if (why == null) return restore();
		push(left, why);
		return null;
	}, result.body, services, ops, applied);
}

// Reload the declared services, then push the wireguard peer changes the write
// collected to the kernel. Both report the same way (null or a message), so a
// failed apply lands in the existing reload-failure recipe: restore the snapshot,
// re-apply, and report reload_failed_restored. `ops` is read here rather than
// captured by value because the handler fills it while fn runs, and fn has
// already returned by the time this is called. A reload still running when the
// budget ran out is no failure, and the checks after it would judge a config
// that it may not have written yet, so they do not run.
function _make_apply(conn, reload, services, wg_apply, ops, applied, watch) {
	return function() {
		watch.check = watch.start(conn, services, watch.packages);
		let err = reload(services, watch.budget);
		if (type(err) == "object") {
			watch.unverified = err.unverified;
			err = null;
		} else if (err == null)
			err = run_check(watch);
		if (err != null) return err;
		// The time for the reloads counts the reloads only. The kernel apply can wait for netifd's
		// wireguard restart, and on that clock the restore of a failed apply had no time left for
		// its own reloads.
		let start = now_ms();
		err = wg_apply(conn, ops, applied);
		if (watch.budget.until != null) watch.budget.until += now_ms() - start;
		return err;
	};
}

// The restore path must not replay the request's own operations. A batch can
// apply several peers before failing on a later one, so replaying would reapply
// the failure instead of undoing what landed. Reconciling each touched interface
// against the restored uci converges from whatever state the kernel is in.
function _make_restore(conn, reload, services, wg_reconcile, ops, watch) {
	return function() {
		let r = reload(services, watch.budget);
		if (type(r) == "string") return r;
		let err = (r == null) ? run_check(watch, services) : null;
		return err ?? wg_reconcile(conn, wg.interfaces_of(ops), ops) ?? r;
	};
}

function transaction(conn, params) {
	let pkg = params.package;
	let fn = params.fn;
	let path = params.lock_path ?? LOCK_PATH;
	let acquire = params.acquire ?? function(p, also) { return default_acquire_pkg(p, pkg, also); };
	let release = params.release ?? default_release_pkg;
	let reload = params.reload ?? default_reload;
	let wg_apply = params.wg_apply ?? wg.apply;
	let wg_reconcile = params.wg_reconcile ?? wg.reconcile;
	let wg_ops = params.wg_ops ?? [];
	let wg_applied = [];
	let check_services = params.check_services ?? default_check_services;
	let watch = { start: params.watch ?? check_daemons, packages: [ pkg ],
	              budget: { ms: limits.reload_budget_ms(conn) } };

	// Bare mode: run fn against `conn` without acquiring any lock, taking a
	// snapshot, committing, or reloading. Used by /batch to compose many
	// handler-level writes under a single outer multi_transaction lock+commit.
	if (params.bare === true)
		return fn(conn, pkg);

	let required = params.reload_services ?? [];
	let if_running = installed(params.reload_if_running, check_services);
	let svc_err = check_services(required);
	if (svc_err != null)
		return { ok: false, kind: "init_script_missing", message: svc_err };
	let cfg_err = missing_config(conn, pkg);
	if (cfg_err != null)
		return { ok: false, kind: "config_missing", message: cfg_err };

	let lock = acquire(path, filter(stay_up_daemons([ ...required, ...if_running ]), (d) => d != pkg));
	// `null` means a test/legacy stub that pre-dates the contention sentinel;
	// treat as per-package since that's the production-default flavour.
	if (lock == null)
		return { ok: false, kind: "locked", lock_kind: "package", package: pkg };
	if (type(lock) == "object" && lock.contention != null) {
		if (lock.contention == "global")
			return { ok: false, kind: "locked", lock_kind: "global" };
		return { ok: false, kind: "locked", lock_kind: "package", package: lock.package ?? pkg };
	}
	if (type(lock) == "object" && lock.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: lock.unavailable };

	let result = null;
	let caught = null;
	try {
		let services = [ ...required, ...with_config_trigger(conn, if_running) ];
		// The preview before the lock loaded the package into this cursor, and libuci serves
		// every later read from that copy. A commit by LuCI or a shell in between was then
		// invisible to fn: a PUT kept an option that it had to remove, and the response showed
		// a section that uci did not store. The commit itself re-reads the file, so only the
		// reads were stale.
		conn.uci_unload(pkg);
		result = run_inner(conn, pkg, services, fn,
		                   _make_apply(conn, reload, services, wg_apply, wg_ops, wg_applied, watch),
		                   _make_restore(conn, reload, services, wg_reconcile, wg_ops, watch),
		                   wg_ops, wg_applied, params.request_id);
	} catch (e) {
		caught = e;
	}
	// Every path the request can still reach ends here, under the lock. A throw keeps the record,
	// as a kill does, because the commit may have landed.
	if (caught == null) write_journal.clear();
	release(lock);
	if (caught != null) die(caught);
	return with_unverified(result, watch);
}

function services_of(by_package, packages) {
	let out = {};
	for (let p in packages)
		for (let s in by_package[p] ?? []) out[s] = true;
	return sort(keys(out));
}

// multi_transaction snapshots, EX-locks, and on-failure restores N packages
// atomically. Caller passes a package list, the reload services of each package
// keyed by package, those to reload only while they run keyed the same way, and
// an fn that performs all uci writes inside the locked region. On success every
// package that the batch wrote commits, and the union of their reload services
// runs once. On a failure after the commits, every package that the batch
// committed is restored from its snapshot. Per-package EX locks are acquired in
// sorted order to avoid deadlocks vs other writers.
function multi_transaction(conn, params) {
	let packages = params.packages ?? [];
	let check_services = params.check_services ?? default_check_services;
	let required = params.reload_services ?? {};
	let if_running = {};
	for (let p in packages) if_running[p] = installed(params.reload_if_running?.[p], check_services);
	let fn = params.fn;
	let path = params.lock_path ?? LOCK_PATH;
	let reload = params.reload ?? default_reload;
	let wg_ops = params.wg_ops ?? [];
	let wg_applied = [];
	let watch = { start: params.watch ?? check_daemons,
	              budget: { ms: limits.reload_budget_ms(conn) } };

	let svc_err = check_services(services_of(required, packages));
	if (svc_err != null)
		return { ok: false, kind: "init_script_missing", message: svc_err };

	// Validate package names + sort + dedup so lock acquisition is deterministic.
	let unique = {};
	for (let p in packages) {
		if (type(p) != "string" || !match(p, SAFE_NAME_RE))
			return { ok: false, kind: "lock_unavailable",
			         error: sprintf("invalid package name %J", p) };
		unique[p] = true;
	}
	let sorted = [];
	for (let p in unique) push(sorted, p);
	sort(sorted);
	for (let p in sorted) {
		let cfg_err = missing_config(conn, p);
		if (cfg_err != null)
			return { ok: false, kind: "config_missing", message: cfg_err };
	}

	let locks = { ...unique };
	let may_reload = [ ...services_of(required, packages), ...services_of(if_running, packages) ];
	for (let d in stay_up_daemons(may_reload)) locks[d] = true;
	locks = sort(keys(locks));
	let lock_prefix = params.pkg_lock_prefix ?? PKG_LOCK_PREFIX;

	let acquired = [];
	let g = _lock_one(path, "s");
	// Global SH contention means a non-uci writer holds EX (system/password,
	// packages/installed, etc.). Report it as such so the client knows the
	// blocker isn't another uci write.
	if (g == null) return { ok: false, kind: "locked", lock_kind: "global" };
	if (type(g) == "object" && g.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: g.unavailable };
	for (let pkg in locks) {
		let p = _lock_one(lock_prefix + pkg + ".lock", "x");
		if (p == null) {
			for (let h in acquired) _release_one(h);
			_release_one(g);
			return { ok: false, kind: "locked", lock_kind: "package", package: pkg };
		}
		if (type(p) == "object" && p.unavailable != null) {
			for (let h in acquired) _release_one(h);
			_release_one(g);
			return { ok: false, kind: "lock_unavailable", error: p.unavailable };
		}
		push(acquired, p);
	}

	let snapshots = {};
	let result = null;
	let caught = null;
	try {
		let by_package = {};
		for (let p in packages)
			by_package[p] = [ ...(required[p] ?? []), ...with_config_trigger(conn, if_running[p]) ];
		for (let pkg in sorted) conn.uci_unload(pkg);
		let inner = fn(conn);
		if (!inner || inner.ok === false) {
			for (let pkg in sorted) conn.uci_revert(pkg);
			result = inner ?? { ok: false, kind: "unknown" };
		} else {
			// Commit each package, but capture the first failure so the
			// packages committed before it are still restored. Without this, a
			// mid-loop commit throw leaves earlier packages committed and
			// breaks the across-packages atomicity contract. Only those are
			// restored: the snapshot of a package that this batch did not write
			// would undo what another writer committed since, such as LuCI's
			// delete of the section that made this batch's commit fail. The
			// others are reverted, so that the cursor holds no write that uci
			// did not store, and the reconcile after a failed reload reads the
			// network package from the file.
			write_journal.record_start(packages, params.request_id, null);
			let committed = [], stored = {};
			let commit_err = null, conflict = null;
			for (let pkg in sorted) {
				let caught_commit = null;
				let wrote = false;
				// Right before the commit, for the reason that run_inner() gives.
				snapshots[pkg] = conn.uci_export(pkg);
				try { wrote = conn.uci_commit(pkg); } catch (e) { caught_commit = "" + e; }
				if (type(wrote) == "object") {
					commit_err = conflict = wrote.conflict;
					break;
				}
				if (caught_commit != null) {
					commit_err = sprintf("uci_commit(%s) failed: %s",
					                     pkg, caught_commit);
					break;
				}
				if (wrote) {
					push(committed, pkg);
					stored[pkg] = conn.uci_export(pkg);
				}
			}
			if (commit_err == null && length(committed) > 0)
				write_journal.mark_reload_started();
			let ran = services_of(by_package, committed);
			// Returns the packages that it wrote back.
			let put_back_all = function(left) {
				for (let pkg in sorted)
					if (index(committed, pkg) < 0) conn.uci_revert(pkg);
				return filter(committed, function(pkg) {
					let why = put_back(conn, pkg, snapshots[pkg], stored[pkg]);
					if (why != null) push(left, why);
					return why == null;
				});
			};
			if (commit_err != null) {
				// The reload and the kernel apply come after every commit, so neither ran: the
				// daemons and the kernel hold what they held before the batch, and the restored
				// files match it again. A reload or a reconcile there would reset WireGuard
				// sessions and undo what another writer put in the kernel by hand.
				result = _finalize_after_reload(commit_err, function(left) { put_back_all(left); return null; },
				                                inner.body, ran, wg_ops, wg_applied);
				if (conflict != null && result.kind == "reload_failed_restored")
					result = conflict_result(conflict);
			} else if (length(committed) == 0) {
				result = _finalize_after_reload(null, null, inner.body, [], wg_ops, wg_applied);
			} else {
				watch.packages = committed;
				let apply = _make_apply(conn, reload, ran, params.wg_apply ?? wg.apply, wg_ops, wg_applied, watch);
				// The restore reloads and checks the daemons of the packages that it wrote back only: a
				// package that it left holds the config that just failed.
				result = _finalize_after_reload(apply(), function(left) {
					let restored = put_back_all(left);
					if (length(restored) == 0) return null;
					return _make_restore(conn, reload, services_of(by_package, restored), params.wg_reconcile ?? wg.reconcile,
					                     (index(restored, "network") >= 0) ? wg_ops : [], watch)();
				}, inner.body, ran, wg_ops, wg_applied);
			}
		}
	} catch (e) { caught = e; }

	if (caught == null) write_journal.clear();
	for (let h in acquired) _release_one(h);
	_release_one(g);
	if (caught != null) die(caught);
	return with_unverified(result, watch);
}

function with_lock(params) {
	let path = params.lock_path ?? LOCK_PATH;
	let acquire = params.acquire ?? default_acquire;
	let release = params.release ?? default_release;
	let fn = params.fn;

	let lock = acquire(path);
	if (lock == null) return { ok: false, kind: "locked", lock_kind: "global" };
	if (type(lock) == "object" && lock.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: lock.unavailable };

	write_journal.record_start(params.journal_packages ?? [], params.request_id, null);
	let result = null;
	let caught = null;
	try { result = fn(); }
	catch (e) { caught = e; }
	if (caught == null) write_journal.clear();
	release(lock);
	if (caught != null) die(caught);
	return result ?? { ok: true };
}

return { transaction, multi_transaction, with_lock,
         default_acquire, default_release,
         default_acquire_pkg, default_release_pkg, acquire_pkg_waiting,
         default_check_services, default_reload, default_watch, dnsmasq_check, run_test, check_daemons };
