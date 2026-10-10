let t = require('harness');

let ct = loadfile('src/lib/crontab.uc')();

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

function codes(body) {
	let out = {};
	for (let e in ct.validate(body)) out[e.field] = e.code;
	return out;
}

t.describe('crontab.validate schedule', () => {
	t.it('accepts the grammar busybox crond reads correctly', () => {
		for (let s in ["*/15 * * * *", "0 3 * * mon-fri", "30 22-2 * * *",
		               "0 0 1 jan,jul *", "5,35 */2 1-15 * 0", "0 0 * * SAT",
		               "0 9-17/2 * * 1-5", "0 0 1-31/2 * *"])
			t.assert_deep_equal(codes({ schedule: s, command: "true" }), {}, s);
	});

	t.it('refuses values crond would turn into a different schedule', () => {
		for (let s in ["75 * * * *", "0 24 * * *", "0 0 0 * *", "0 0 * 13 *",
		               "0 0 * * 7", "0 0 * * monday", "5/10 * * * *", "*/0 * * * *",
		               "*-5 * * * *", "1,,2 * * * *"])
			t.assert_equal(codes({ schedule: s, command: "true" }).schedule, "invalid_format", s);
	});

	t.it('refuses a stepped * in the day field, which busybox counts from day 0', () => {
		let errs = ct.validate({ schedule: "0 0 */2 * *", command: "true" });
		t.assert_equal(errs[0].code, "invalid_format");
		t.assert_match(errs[0].message, /write 1-31\/2/);
	});

	t.it('refuses @daily, which OpenWrt crond skips', () => {
		let errs = ct.validate({ schedule: "@daily", command: "true" });
		t.assert_equal(errs[0].code, "invalid_format");
		t.assert_match(errs[0].message, /not supported/);
	});

	t.it('refuses a schedule whose spacing would read back different', () => {
		for (let s in ["0  3 * * *", " 0 3 * * *", "0 3 * * * ", "0\t3 * * *", "0 3 * *"])
			t.assert_equal(codes({ schedule: s, command: "true" }).schedule, "invalid_format", s);
	});
});

t.describe('crontab.validate command', () => {
	t.it('refuses # because crond cuts the line there', () => {
		t.assert_equal(codes({ schedule: "* * * * *", command: "echo a#b" }).command, "invalid_format");
	});

	t.it('refuses a newline that would write a second line', () => {
		t.assert_equal(codes({ schedule: "* * * * *", command: "true\n* * * * * evil" }).command,
		               "invalid_format");
	});

	t.it('refuses whitespace crond would strip', () => {
		t.assert_equal(codes({ schedule: "* * * * *", command: " true" }).command, "invalid_format");
		t.assert_equal(codes({ schedule: "* * * * *", command: "true " }).command, "invalid_format");
	});

	t.it('refuses a trailing backslash, which joins the next line into the command', () => {
		t.assert_equal(codes({ schedule: "* * * * *", command: "touch /tmp/a \\" }).command, "invalid_format");
	});

	t.it('passes % through, since busybox crond gives it no meaning', () => {
		t.assert_deep_equal(codes({ schedule: "* * * * *", command: "date +%s > /tmp/now" }), {});
	});
});

t.describe('crontab.validate presence and type', () => {
	t.it('reports both fields missing at once', () => {
		t.assert_deep_equal(codes({}), { schedule: "required", command: "required" });
	});

	t.it('tells a wrong type from a missing value', () => {
		t.assert_deep_equal(codes({ schedule: 0, command: false }),
		                    { schedule: "invalid_type", command: "invalid_type" });
	});

	t.it('refuses a field it does not know, but tolerates what a read sends back', () => {
		t.assert_deep_equal(codes({ schedule: "* * * * *", command: "true", user: "nobody" }),
		                    { user: "unknown_field" });
		t.assert_deep_equal(codes({ schedule: "* * * * *", command: "true", id: "0123456789ab",
		                            runtime: { crond_running: true } }), {});
	});
});

t.describe('crontab.parse_line reads like crond', () => {
	t.it('cuts the command at #', () => {
		t.assert_equal(ct.parse_line("0 * * * * touch /tmp/h1;touch /tmp/h2#x").command,
		               "touch /tmp/h1;touch /tmp/h2");
	});

	t.it('skips comments, blank lines, environment lines and short lines', () => {
		for (let line in ["# 0 * * * * x", "", "   ", "PATH=/usr/bin:/bin",
		                  "SHELL=/bin/sh 1 2 3 4 5", "MAILTO=", "0 * * * *"])
			t.assert_equal(ct.parse_line(line), null, line);
	});

	t.it('collapses field spacing but keeps the command as written', () => {
		let a = ct.parse_line("0\t3  * * *   echo  a\tb  ");
		t.assert_equal(a.schedule, "0 3 * * *");
		t.assert_equal(a.command, "echo  a\tb");
		t.assert_equal(a.id, ct.parse_line("0 3 * * * echo  a\tb").id);
	});

	t.it('skips a short @daily line, as OpenWrt crond does', () => {
		t.assert_equal(ct.parse_line("@daily /usr/bin/backup"), null);
	});

	t.it('reads a written entry back with the same schedule and command', () => {
		let body = { schedule: "*/5 * * * mon-fri", command: "/usr/bin/sync-time --quiet" };
		let parsed = ct.parse_line(split(ct.with_entry(null, body), "\n")[0]);
		t.assert_equal(parsed.schedule, body.schedule);
		t.assert_equal(parsed.command, body.command);
	});
});

t.describe('crontab line continuation, as measured on OpenWrt crond', () => {
	t.it('joins a line that ends in a backslash with the next one', () => {
		let e = ct.entries_of("* * * * * touch /tmp/c1 \\\n/tmp/c2\n");
		t.assert_equal(length(e), 1);
		t.assert_equal(e[0].command, "touch /tmp/c1 /tmp/c2");
	});

	t.it('lets a comment that ends in a backslash hide the entry below it', () => {
		t.assert_deep_equal(ct.entries_of("# note \\\n* * * * * touch /tmp/c3\n"), []);
	});

	t.it('keeps an entry appended after a trailing backslash on its own', () => {
		let before = "5 5 * * * /bin/a \\\n";
		let after = ct.with_entry(before, { schedule: "1 2 3 4 5", command: "x" });
		t.assert_equal(substr(after, 0, length(before)), before);
		t.assert_deep_equal(map(ct.entries_of(after), e => e.command), ["/bin/a", "x"]);
	});

	t.it('removes every physical line of a continued entry and nothing else', () => {
		let content = "0 0 * * * keep\n* * * * * touch a \\\nb\n0 1 * * * keep too\n";
		let id = ct.entries_of(content)[1].id;
		t.assert_equal(ct.without_entry(content, id), "0 0 * * * keep\n0 1 * * * keep too\n");
	});
});

t.describe('crontab file edits', () => {
	const PACKAGE = "0 0 * * * /etc/init.d/acme renew";

	t.it('appends after a file that lacks a final newline', () => {
		t.assert_equal(ct.with_entry(PACKAGE, { schedule: "1 2 3 4 5", command: "x" }),
		               PACKAGE + "\n1 2 3 4 5 x\n");
	});

	t.it('removes every copy of the entry and keeps other lines byte for byte', () => {
		let content = "# keep\nPATH=/sbin:/bin\n" + PACKAGE + "\n*/5 * * * * x\n\t*/5  * * * *  x\n";
		let id = ct.parse_line("*/5 * * * * x").id;
		t.assert_equal(ct.without_entry(content, id), "# keep\nPATH=/sbin:/bin\n" + PACKAGE + "\n");
	});

	t.it('leaves the file as it was when the entry is absent', () => {
		let id = ct.parse_line("1 2 3 4 5 x").id;
		for (let content in [PACKAGE + "\n", PACKAGE, "# a\n\n" + PACKAGE + "\n", ""])
			t.assert_equal(ct.without_entry(content, id), content);
	});
});

t.describe('crontab handlers refuse before any I/O', () => {
	t.it('rejects a non-object body', () => {
		t.assert_equal(ct.add_entry(ctx(), null, null).status, 400);
	});

	t.it('rejects an invalid entry with 422', () => {
		let r = ct.add_entry(ctx(), null, { schedule: "75 * * * *", command: "true" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "schedule");
	});

	t.it('answers 404 for an id that cannot exist', () => {
		t.assert_equal(ct.get_entry(ctx(), null, "AAAA").status, 404);
		t.assert_equal(ct.remove_entry(ctx(), null, "../../etc/passwd").status, 404);
	});
});
