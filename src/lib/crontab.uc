let fs = require('fs');
let errors = require('errors');
let values = require('values');
let non_uci = require('non_uci');
let transaction = require('transaction');
let handler = require('handler');
let ids = require('ids');

// The temp file replace_private_file writes beside this one has a dot in its name, and
// crond skips dotted names, so a crash between write and rename leaves nothing it loads.
const CRONTAB_PATH = "/etc/crontabs/root";
const RELOAD = ["cron"];
const REQUEST_PROPERTIES = { schedule: { type: "string" }, command: { type: "string" } };

// busybox crond does not refuse an out-of-range value: it logs a parse error and keeps
// the line with a half-filled field, so minute 75 runs every minute and weekday 7,
// Sunday in most crons, runs every day.
//
// busybox also fills `*` in the day field from day 0, which never matches, so `*/2` runs
// on days 2,4,...,30 where other crons run on 1,3,...,31, and it ORs such a day with a
// restricted weekday where other crons AND them.
const FIELDS = [
	{ name: "minute",  min: 0, max: 59 },
	{ name: "hour",    min: 0, max: 23 },
	{ name: "day",     min: 1, max: 31, star_from_zero: true },
	{ name: "month",   min: 1, max: 12,
	  names: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"] },
	{ name: "weekday", min: 0, max: 6,
	  names: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] },
];

function value_ok(f, v) {
	if (match(v, /^[0-9]+$/)) {
		let n = int(v);
		return n >= f.min && n <= f.max;
	}
	return f.names != null && index(f.names, lc(v)) >= 0;
}

// A step on a single value is refused although busybox accepts it: busybox reads `5/10`
// as 5 alone, other crons as 5-59/10 or not at all, so the line means different things.
function field_problem(f, text) {
	let allowed = sprintf("%d-%d%s", f.min, f.max, f.names ? " or a three-letter name" : "");
	for (let item in split(text, ",")) {
		let m = match(item, /^(\*|([A-Za-z0-9]+)(-([A-Za-z0-9]+))?)(\/([0-9]+))?$/);
		if (m == null)
			return sprintf("%s field %J is not a list of values, ranges and steps", f.name, text);
		for (let v in [m[2], m[4]])
			if (v != null && !value_ok(f, v))
				return sprintf("%s value %J is outside %s", f.name, v, allowed);
		if (m[6] != null) {
			if (m[1] != "*" && m[4] == null)
				return sprintf("%s step %J needs `*` or a range before it", f.name, item);
			if (int(m[6]) < 1)
				return sprintf("%s step in %J must be at least 1", f.name, item);
			if (m[1] == "*" && f.star_from_zero)
				return sprintf("%s step %J counts from day 0 in busybox crond, unlike other crons: write %d-%d/%s",
				               f.name, item, f.min, f.max, m[6]);
		}
	}
	return null;
}

function schedule_problem(s) {
	if (substr(s, 0, 1) == "@")
		return "special schedules such as @daily are not supported: OpenWrt builds busybox crond without them";
	let parts = split(s, " ");
	if (length(parts) != 5 || index(parts, "") >= 0)
		return "must be five fields separated by single spaces";
	for (let i = 0; i < 5; i++) {
		let p = field_problem(FIELDS[i], parts[i]);
		if (p != null) return p;
	}
	return null;
}

function command_problem(c) {
	if (values.has_control_chars(c))
		return "must not contain control characters (newline, tab, NUL, etc.)";
	if (index(c, "#") >= 0)
		return "must not contain '#': crond reads it as a comment wherever it appears and drops the rest of the line";
	if (trim(c) != c)
		return "must not start or end with whitespace: crond strips it, so the entry would read back different";
	if (substr(c, -1) == "\\")
		return "must not end with a backslash: crond reads it as a line continuation and joins the next line into the command";
	return null;
}

function validate(body) {
	let errs = handler.check_schema_types(REQUEST_PROPERTIES, body);
	for (let field in ["schedule", "command"]) {
		let v = body[field];
		if (v == null || v === "")
			push(errs, errors.field_error(field, "required", "is required"));
		else if (type(v) == "string") {
			let p = (field == "schedule") ? schedule_problem(v) : command_problem(v);
			if (p != null) push(errs, errors.field_error(field, "invalid_format", p));
		}
	}
	return errs;
}

function entry_of(schedule, command) {
	return { id: ids.content_id(schedule + " " + command), schedule: schedule, command: command };
}

// Reads a line the way OpenWrt's crond does, so a read lists what crond runs rather
// than what the line seems to say: `#` ends the line wherever it appears, a MAILTO=,
// SHELL= or PATH= line sets the environment, and a line short of five fields plus a
// command is skipped. There is no `@daily`, since OpenWrt builds busybox without
// FEATURE_CROND_SPECIAL_TIMES.
function parse_line(line) {
	let text = trim(split(line, "#")[0], " \t");
	if (match(text, /^(MAILTO|SHELL|PATH)=/)) return null;
	let m = match(text, /^([^ \t]+)[ \t]+([^ \t]+)[ \t]+([^ \t]+)[ \t]+([^ \t]+)[ \t]+([^ \t]+)[ \t]+(.+)$/);
	if (m == null) return null;
	return entry_of(join(" ", slice(m, 1, 6)), m[6]);
}

// crond joins a line that ends in `\` with the next one, dropping the backslash, before
// it looks for `#`: a comment that ends in `\` hides the entry below it. Each group is
// the physical lines crond reads as one, so an edit never splits one.
function logical_lines(content) {
	if (substr(content, -1) == "\n") content = substr(content, 0, -1);
	let physical = split(content, "\n");
	let out = [];
	for (let i = 0; i < length(physical); i++) {
		let lines = [physical[i]];
		let text = physical[i];
		while (substr(text, -1) == "\\") {
			text = substr(text, 0, -1);
			if (i + 1 >= length(physical)) break;
			push(lines, physical[++i]);
			text += physical[i];
		}
		push(out, { lines: lines, text: text });
	}
	return out;
}

function read_content() {
	return non_uci.read_file_if_present(CRONTAB_PATH);
}

function entries_of(content) {
	let out = [];
	let seen = {};
	for (let l in logical_lines(content ?? "")) {
		let e = parse_line(l.text);
		if (e == null || seen[e.id]) continue;
		seen[e.id] = true;
		push(out, e);
	}
	return out;
}

// A blank line ends a continuation without changing what crond reads for the line before
// it, so an entry appended after a trailing `\` stays an entry of its own.
function with_entry(content, entry) {
	let out = content ?? "";
	if (out != "" && substr(out, -1) != "\n") out += "\n";
	if (substr(out, -2) == "\\\n") out += "\n";
	return out + entry.schedule + " " + entry.command + "\n";
}

// Every other line stays byte for byte, so package entries, comments and environment
// lines survive. A duplicated entry goes in full: leaving one copy would keep it.
function without_entry(content, id) {
	let kept = [];
	for (let l in logical_lines(content))
		if (parse_line(l.text)?.id != id)
			for (let line in l.lines) push(kept, line);
	let out = join("\n", kept);
	return (out != "" && substr(content, -1) == "\n") ? out + "\n" : out;
}

// The init script exits 0 even when crond does not come up: with an invalid
// system.cronloglevel it prints "validation failed" and procd stops crond. Asking procd
// is the only way to know whether the write took effect.
function crond_running(conn) {
	let services;
	try { services = conn.call("service", "list", { name: "cron" }); }
	catch (e) { return null; }
	for (let name, instance in services?.cron?.instances ?? {})
		if (instance?.running) return true;
	return false;
}

// Same recipe as a curated write: when the reload fails, put the old file back and
// reload again, so the failed request leaves crond with the table it had.
function apply(before, after) {
	if (!non_uci.replace_private_file(CRONTAB_PATH, after))
		return { ok: false, kind: "io_error" };
	let reload_error = transaction.default_reload(RELOAD);
	if (reload_error == null) return { ok: true };
	let restored = (before == null) ? fs.unlink(CRONTAB_PATH)
	                                : non_uci.replace_private_file(CRONTAB_PATH, before);
	let restore_error = restored ? transaction.default_reload(RELOAD)
	                             : sprintf("could not restore %s", CRONTAB_PATH);
	if (restore_error != null)
		return { ok: false, kind: "reload_failed_unrecovered", reload_error, restore_error };
	return { ok: false, kind: "reload_failed_restored", reload_error };
}

function reload_failure(ctx, r) {
	if (r.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, r.reload_error);
	if (r.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, r.reload_error, r.restore_error);
	return null;
}

// Only another writer can leave a schedule uapi refuses, and it is exactly such a line
// that crond runs differently from how it reads, so the refusal doubles as the signal.
function entry_view(e, running) {
	return { id: e.id, schedule: e.schedule, command: e.command,
	         runtime: { crond_running: running,
	                    runs_as_written: schedule_problem(e.schedule) == null } };
}

function list_entries(ctx, conn) {
	let running = crond_running(conn);
	return errors.ok(ctx, map(entries_of(read_content()), e => entry_view(e, running)));
}

function get_entry(ctx, conn, id) {
	if (!ids.is_content_id(id))
		return errors.error(ctx, "not_found", sprintf("invalid cron job id %J", id));
	for (let e in entries_of(read_content()))
		if (e.id == id) return errors.ok(ctx, entry_view(e, crond_running(conn)));
	return errors.error(ctx, "not_found", sprintf("no cron job with id %J", id));
}

function add_entry(ctx, conn, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let errs = validate(body);
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);
	let missing = transaction.default_check_services(RELOAD);
	if (missing != null)
		return errors.error(ctx, "init_script_missing", missing);
	let entry = entry_of(body.schedule, body.command);
	let lr = non_uci.with_lock_translated(ctx, function() {
		let before = read_content();
		for (let e in entries_of(before))
			if (e.id == entry.id) return { ok: false, kind: "conflict" };
		return apply(before, with_entry(before, entry));
	}, {
		conflict: sprintf("cron job %s already present", entry.id),
		io_error: sprintf("could not write %s", CRONTAB_PATH),
	});
	if (lr.envelope) return lr.envelope;
	let failed = reload_failure(ctx, lr.result);
	if (failed) return failed;
	non_uci.audit_notice(ctx, "cron-job-add", { id: entry.id });
	return errors.ok(ctx, entry_view(entry, crond_running(conn)));
}

function remove_entry(ctx, conn, id) {
	if (!ids.is_content_id(id))
		return errors.error(ctx, "not_found", sprintf("invalid cron job id %J", id));
	let missing = transaction.default_check_services(RELOAD);
	if (missing != null)
		return errors.error(ctx, "init_script_missing", missing);
	let removed = null;
	let lr = non_uci.with_lock_translated(ctx, function() {
		let before = read_content();
		removed = filter(entries_of(before), e => e.id == id)[0];
		if (removed == null) return { ok: false, kind: "not_found" };
		return apply(before, without_entry(before, id));
	}, {
		not_found: sprintf("no cron job with id %J", id),
		io_error:  sprintf("could not write %s", CRONTAB_PATH),
	});
	if (lr.envelope) return lr.envelope;
	let failed = reload_failure(ctx, lr.result);
	if (failed) return failed;
	return errors.ok(ctx, entry_view(removed, crond_running(conn)));
}

return {
	list_entries,
	get_entry,
	add_entry,
	remove_entry,
	validate,
	parse_line,
	entries_of,
	with_entry,
	without_entry,
};
