let t = require('harness');
let fs = require('fs');

let pkg = loadfile('src/lib/packages.uc')();

function ctx(budget_s) { return { request_id: "01hx0000000000000000000000", limits: { reload_budget_s: budget_s ?? 20 } }; }

t.describe('packages module', () => {
	t.it('exports the expected handler set', () => {
		t.assert_equal(type(pkg.list_installed), "function");
		t.assert_equal(type(pkg.get_installed), "function");
		t.assert_equal(type(pkg.install), "function");
		t.assert_equal(type(pkg.remove_installed), "function");
		t.assert_equal(type(pkg.list_feeds), "function");
		t.assert_equal(type(pkg.get_feed), "function");
		t.assert_equal(type(pkg.create_feed), "function");
		t.assert_equal(type(pkg.remove_feed), "function");
	});
});

t.describe('packages.install validation', () => {
	t.it('rejects a non-object body with bad_request', () => {
		let r = pkg.install(ctx(), null);
		t.assert_equal(r.status, 400);
		t.assert_equal(r.body.code, "bad_request");
	});

	t.it('reports name as required when missing', () => {
		let r = pkg.install(ctx(), {});
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.code, "validation_failed");
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "required");
	});

	t.it('rejects shell-metacharacter names with invalid_format', () => {
		let r = pkg.install(ctx(), { name: "evil; rm -rf /" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects path-traversal names with invalid_format', () => {
		let r = pkg.install(ctx(), { name: "../../etc/passwd" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects names starting with - (would be parsed as apk flag)', () => {
		let r = pkg.install(ctx(), { name: "--allow-untrusted" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects names starting with . (path traversal)', () => {
		let r = pkg.install(ctx(), { name: ".bashrc" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});
});

t.describe('packages.remove_installed validation', () => {
	t.it('rejects unsafe names with bad_request', () => {
		let r = pkg.remove_installed(ctx(), "foo bar");
		t.assert_equal(r.status, 400);
		t.assert_equal(r.body.code, "bad_request");
	});
});

t.describe('packages.get_installed validation', () => {
	t.it('rejects unsafe names with not_found (without shelling out)', () => {
		let r = pkg.get_installed(ctx(), "foo;bar");
		t.assert_equal(r.status, 404);
		t.assert_equal(r.body.code, "not_found");
	});
});

t.describe('packages.create_feed validation', () => {
	t.it('rejects missing name and url together', () => {
		let r = pkg.create_feed(ctx(), {});
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.code, "validation_failed");
		let codes = {};
		for (let e in r.body.errors) codes[e.field] = e.code;
		t.assert_equal(codes.name, "required");
		t.assert_equal(codes.url, "required");
	});

	t.it('rejects non-http url with invalid_format', () => {
		let r = pkg.create_feed(ctx(), { name: "my-feed", url: "file:///etc/passwd" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "url");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	// A start-anchored pattern let a newline append a second repository line, which apk
	// trusts on the next install and which no read path showed, since both parse one line.
	// Confirmed on a box running 3.0.0-rc1: the file held 2 lines while GET reported 1.
	t.it('rejects a url carrying an embedded newline', () => {
		let r = pkg.create_feed(ctx(), { name: "inj",
		                                 url: "http://legit.invalid/f\nhttp://evil.invalid/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "url");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects other control characters and trailing whitespace in a url', () => {
		for (let bad in [ "http://a.invalid/x\ty", "http://a.invalid/x\r", "http://a.invalid/x z" ]) {
			let r = pkg.create_feed(ctx(), { name: "inj", url: bad });
			t.assert_equal(r.status, 422);
			t.assert_equal(r.body.errors[0].field, "url");
		}
	});

	t.it('rejects unsafe feed name with invalid_format', () => {
		let r = pkg.create_feed(ctx(), { name: "../etc/foo", url: "https://example.com/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
	});

	t.it('rejects feed name starting with . (directory escape)', () => {
		let r = pkg.create_feed(ctx(), { name: ".hidden", url: "https://example.com/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});

	t.it('rejects feed name starting with - (would be parsed as apk flag)', () => {
		let r = pkg.create_feed(ctx(), { name: "-rf", url: "https://example.com/x" });
		t.assert_equal(r.status, 422);
		t.assert_equal(r.body.errors[0].field, "name");
		t.assert_equal(r.body.errors[0].code, "invalid_format");
	});
});

// /etc/apk and /var/lock are root's, so the feed files are kept in a directory in /tmp and the lock
// is a file in /tmp. A full overlay creates the file and then fails the write, so the full case
// creates the file and hands the module a handle on /dev/full. `run` stands in for run_bounded.
t.describe('packages.create_feed writes the feed file', () => {
	const DIR = '/tmp/uapi-test-feeds';
	function create_with(full, run, budget_s) {
		let s = { runs: [] };
		fs.mkdir(DIR);
		for (let f in fs.lsdir(DIR)) fs.unlink(DIR + '/' + f);
		let at = (path) => replace(path, /^\/etc\/apk\/repositories\.d\//, DIR + '/');
		let fsx = { ...fs,
			stat: (path) => fs.stat(at(path)),
			open: (path, m) => {
				if (path == '/var/lock/uapi.lock') return fs.open('/tmp/uapi-test-packages.lock', m);
				let f = fs.open(at(path), m);
				if (!full || at(path) == path || f == null) return f;
				f.close();
				return fs.open('/dev/full', 'w');
			},
			unlink: (path) => fs.unlink(at(path)),
		};
		let tx = t.load_with_fs(fsx, [ 'transaction' ]);
		let p = t.load_with({ fs: fsx, transaction: { ...tx, run_bounded: (argv, ms) => {
			push(s.runs, [ argv, ms ]);
			return run(tx, argv, ms);
		} } }, [ 'non_uci', 'packages' ]);
		let start = clock(true);
		s.r = p.create_feed(ctx(budget_s), { name: 'extra', url: 'https://example.com/extra' });
		let end = clock(true);
		s.ms = (end[0] - start[0]) * 1000 + (end[1] - start[1]) / 1000000;
		s.files = fs.lsdir(DIR);
		s.feed = fs.readfile(DIR + '/extra.list');
		// Before the asserts, because a failed one dies and would leave the directory in /tmp.
		for (let f in s.files) fs.unlink(DIR + '/' + f);
		fs.rmdir(DIR);
		return s;
	}
	let updated = () => ({ code: 0, output: '' });

	t.it('writes the URL, then refreshes the index under the reload bound', () => {
		let s = create_with(false, updated);
		t.assert_equal(s.r.status, 200);
		t.assert_equal(s.r.body.update_status, 'ok');
		t.assert_deep_equal(s.files, [ 'extra.list' ]);
		t.assert_equal(s.feed, 'https://example.com/extra\n');
		t.assert_deep_equal(s.runs, [ [ [ 'apk', '--timeout', '20', 'update' ], 20000 ] ]);
	});

	t.it('answers 500 and leaves no file when the overlay cannot hold the URL', () => {
		let s = create_with(true, updated);
		t.assert_equal(s.r.status, 500);
		t.assert_equal(s.r.body.code, 'internal_error');
		t.assert_deep_equal(s.files, []);
		t.assert_deep_equal(s.runs, []);
	});

	// A feed host that did not answer held apk update past uhttpd's 60 s timeout, so the request got
	// no answer. The stub leaves a child behind, as a killed apk leaves its wget, and that child must
	// not hold the answer either.
	t.it('kills an apk update that outlasts the bound, and answers with the feed written', () => {
		let dir = '/tmp/uapi-test-apk-hang';
		system(sprintf('rm -rf %s; mkdir -p %s', dir, dir));
		fs.writefile(dir + '/apk', '#!/bin/sh\nsleep 5 &\nexec sleep 5\n');
		fs.chmod(dir + '/apk', 0755);
		let s = create_with(false, (tx, argv, ms) => tx.run_bounded([ dir + '/apk', ...slice(argv, 1) ], ms), 1);
		system('rm -rf ' + dir);
		t.assert_equal(s.r.status, 200);
		t.assert_equal(s.r.body.update_status,
			'apk update did not finish within 1 s and was killed; see syslog 01hx0000000000000000000000');
		t.assert_equal(s.feed, 'https://example.com/extra\n');
		t.assert_deep_equal(s.runs, [ [ [ 'apk', '--timeout', '1', 'update' ], 1000 ] ]);
		t.assert_true(s.ms < 4000, sprintf('the request answered after %d ms', s.ms));
	});
});

t.describe('packages.remove_feed validation', () => {
	t.it('rejects unsafe id with bad_request', () => {
		let r = pkg.remove_feed(ctx(), "foo/bar");
		t.assert_equal(r.status, 400);
	});
});

t.describe('packages.add_with_refresh', () => {
	function fake(adds, update) {
		let calls = [];
		return { calls: calls,
			add: function() {
				push(calls, "add");
				return { ok: shift(adds), output: sprintf("%d:add", length(calls)) };
			},
			update: function() {
				push(calls, "update");
				return update;
			} };
	}

	t.it('does not refresh when the first attempt works', () => {
		let f = fake([true], { ok: true });
		t.assert_true(pkg.add_with_refresh(f.add, f.update).ok);
		t.assert_deep_equal(f.calls, ["add"]);
	});

	t.it('refreshes and tries once more when the cached index is stale', () => {
		let f = fake([false, true], { ok: true });
		t.assert_true(pkg.add_with_refresh(f.add, f.update).ok);
		t.assert_deep_equal(f.calls, ["add", "update", "add"]);
	});

	t.it('reports the second failure when the refresh did not help', () => {
		let f = fake([false, false], { ok: true });
		let r = pkg.add_with_refresh(f.add, f.update);
		t.assert_false(r.ok);
		t.assert_equal(r.output, "3:add");
	});

	t.it('retries even when apk update reports a failure, as one unreachable feed makes it do', () => {
		let f = fake([false, true], { ok: false, killed: false });
		t.assert_true(pkg.add_with_refresh(f.add, f.update).ok);
		t.assert_deep_equal(f.calls, ["add", "update", "add"]);
	});

	// The stale index of the feed that held the refresh would hold the retry as long again.
	t.it('does not retry when the refresh was killed at its bound', () => {
		let f = fake([false, true], { ok: false, killed: true });
		let r = pkg.add_with_refresh(f.add, f.update);
		t.assert_false(r.ok);
		t.assert_equal(r.output, "1:add");
		t.assert_deep_equal(f.calls, ["add", "update"]);
	});
});

t.describe('packages.install bounds apk', () => {
	t.it('passes the reload bound to apk add as --timeout, and kills the refresh at it', () => {
		let commands = [], runs = [];
		let fsx = { ...fs,
			open: (path, m) => fs.open((path == '/var/lock/uapi.lock') ? '/tmp/uapi-test-packages.lock' : path, m),
			popen: (cmd) => { push(commands, cmd); return { read: () => '', close: () => 1 }; },
		};
		let tx = t.load_with_fs(fsx, [ 'transaction' ]);
		let p = t.load_with({ fs: fsx, transaction: { ...tx, run_bounded: (argv, ms) => {
			push(runs, [ argv, ms ]);
			return { code: -9, output: '' };
		} } }, [ 'non_uci', 'packages' ]);
		let r = p.install(ctx(7), { name: "ethtool" });
		t.assert_equal(r.status, 500);
		t.assert_deep_equal(commands, [ "apk --timeout 7 add -- ethtool 2>&1" ]);
		t.assert_deep_equal(runs, [ [ [ "apk", "--timeout", "7", "update" ], 7000 ] ]);
	});
});

t.describe('packages.version_of', () => {
	const QUERY = '[ { "name": "luci-app-uapi", "version": "1.1.1-r1" }, { "name": "uapi", "version": "3.0.0-r1" } ]';

	t.it('reads the full version, where splitting the apk info line kept only r1', () => {
		t.assert_equal(pkg.version_of("uapi", QUERY), "3.0.0-r1");
		t.assert_equal(pkg.version_of("luci-app-uapi", QUERY), "1.1.1-r1");
	});

	t.it('keeps a version with a tilde whole', () => {
		t.assert_equal(pkg.version_of("kernel",
			'[ { "name": "kernel", "version": "6.12.94~a7bc15f4-r1" } ]'), "6.12.94~a7bc15f4-r1");
	});

	t.it('answers null for a name the query did not return', () => {
		t.assert_equal(pkg.version_of("ethtool", QUERY), null);
		t.assert_equal(pkg.version_of("uapi", "[ ]"), null);
	});

	t.it('answers null when a warning on stderr broke the JSON', () => {
		t.assert_equal(pkg.version_of("uapi", "WARNING: opening from cache x: No such file or directory\n" + QUERY), null);
	});
});
