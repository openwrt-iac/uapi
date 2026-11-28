let t = require('harness');
let o = require('cmd_output');

t.describe('cmd_output', () => {
	t.it('gives the writer the text and the output, and the other readers only the text', () => {
		let e = o.append("dnsmasq exited with code 1", "bad option at line 2: key=SECRET");
		t.assert_equal(o.for_writer(e), "dnsmasq exited with code 1: bad option at line 2: key=SECRET");
		t.assert_equal(o.without_output(e), "dnsmasq exited with code 1");
	});

	t.it('keeps the marks through a nested error, and removes each output', () => {
		let e = o.append("fw exited with code 2", "SECRET1") + "; reload during restore failed: "
		        + o.append("fw exited with code 3", "SECRET2\nmore");
		t.assert_equal(o.for_writer(e), "fw exited with code 2: SECRET1; reload during restore failed: fw exited with code 3: SECRET2\nmore");
		t.assert_equal(o.without_output(e), "fw exited with code 2; reload during restore failed: fw exited with code 3");
	});

	t.it('keeps an output whole between its marks, even when it prints the mark characters', () => {
		let e = o.append("wg set on wg0 failed", "a\x1f SECRET \x1eb");
		t.assert_equal(o.for_writer(e), "wg set on wg0 failed: a\x1f SECRET \x1eb");
		t.assert_equal(o.without_output(e), "wg set on wg0 failed");
	});

	t.it('leaves the mark characters of a key that a message names, and still removes the output', () => {
		let e = "Request body: a\x1eb\x1fc holds a control character; " + o.append("fw exited with code 2", "SECRET");
		t.assert_equal(o.for_writer(e), "Request body: a\x1eb\x1fc holds a control character; fw exited with code 2: SECRET");
		t.assert_equal(o.without_output(e), "Request body: a\x1eb\x1fc holds a control character; fw exited with code 2");
	});

	t.it('hides the rest of a text whose mark does not close', () => {
		let e = o.append("dnsmasq refuses its config main", "SECRET");
		t.assert_equal(o.without_output(substr(e, 0, length(e) - 1)), "dnsmasq refuses its config main");
	});

	t.it('keeps the end of a long output, where a command prints its cause', () => {
		let out = "";
		for (let i = 0; i < 5000; i++) out += "a";
		let r = o.tail(out + "CAUSE");
		t.assert_equal(length(r), 3 + 4096);
		t.assert_equal(substr(r, 0, 4), "...a");
		t.assert_equal(substr(r, -5), "CAUSE");
		t.assert_equal(o.tail("short"), "short");
		t.assert_equal(o.tail(null), null);
	});

	t.it('cuts a long output at the start of a UTF-8 character', () => {
		let out = "";
		for (let i = 0; i < 1366; i++) out += "€";
		t.assert_equal(o.tail(out), "..." + substr(out, 3));
	});

	t.it('leaves a text without output and a value that is not a string as they are', () => {
		t.assert_equal(o.without_output("dnsmasq stopped after the reload"), "dnsmasq stopped after the reload");
		t.assert_equal(o.for_writer("x"), "x");
		t.assert_equal(o.without_output(null), null);
		t.assert_deep_equal(o.for_writer([ "a" ]), [ "a" ]);
	});
});
