let t = require('harness');
let ubus = require('bus');
let fs = require('fs');

t.describe('ubus.stub, ubus call', () => {
	t.it('records each call with normalized args', () => {
		let c = ubus.stub();
		c.call('system', 'info');
		c.call('network', 'reload', { wait: 1 });
		t.assert_deep_equal(c._state.ubus_calls, [
			['system', 'info', {}],
			['network', 'reload', { wait: 1 }],
		]);
	});

	t.it('returns programmed responses', () => {
		let c = ubus.stub({ ubus: { 'system info': { uptime: 42 } } });
		t.assert_deep_equal(c.call('system', 'info'), { uptime: 42 });
	});

	t.it('returns null when no response is programmed', () => {
		let c = ubus.stub();
		t.assert_equal(c.call('whatever', 'thing'), null);
	});

	t.it('supports function responses that see the args', () => {
		let c = ubus.stub({
			ubus: {
				'svc m': function(args) { return { echoed: args.x }; }
			}
		});
		t.assert_deep_equal(c.call('svc', 'm', { x: 7 }), { echoed: 7 });
	});

	t.it('throws when the programmed response has _error', () => {
		let c = ubus.stub({ ubus: { 'network reload': { _error: 'kaboom' } } });
		t.assert_throws(() => c.call('network', 'reload'));
	});

	t.it('set_ubus_response programs responses at runtime', () => {
		let c = ubus.stub();
		c.set_ubus_response('fw4', 'reload', { ok: true });
		t.assert_deep_equal(c.call('fw4', 'reload'), { ok: true });
	});
});

t.describe('ubus.stub, uci read', () => {
	t.it('uci_get returns null for missing package, section, or option', () => {
		let c = ubus.stub();
		t.assert_equal(c.uci_get('network', 'lan', 'proto'), null);
		t.assert_equal(c.uci_get('network', 'lan'), null);
	});

	t.it('uci_get returns the option value when present', () => {
		let c = ubus.stub({
			uci: { network: { lan: { proto: 'static', ipaddr: '10.0.0.1' } } }
		});
		t.assert_equal(c.uci_get('network', 'lan', 'proto'), 'static');
		t.assert_equal(c.uci_get('network', 'lan', 'missing'), null);
	});

	t.it('uci_get without option returns the whole section', () => {
		let c = ubus.stub({
			uci: { sys: { main: { hostname: 'r1' } } }
		});
		t.assert_deep_equal(c.uci_get('sys', 'main'), { hostname: 'r1', '.name': 'main' });
	});
});

t.describe('ubus.stub, uci mutations', () => {
	t.it('uci_set creates the section if absent and records the op', () => {
		let c = ubus.stub();
		c.uci_set('network', 'lan', 'proto', 'static');
		t.assert_equal(c._state.uci.network.lan.proto, 'static');
		t.assert_deep_equal(c._state.uci_ops[0],
		                    ['set', 'network', 'lan', 'proto', 'static']);
	});

	t.it('uci_rename moves a section and records the op', () => {
		let c = ubus.stub({
			uci: { firewall: { cfg00 : { '.type': 'rule', target: 'ACCEPT' } } }
		});
		t.assert_true(c.uci_rename('firewall', 'cfg00', 'r_01hx'));
		t.assert_equal(c._state.uci.firewall.cfg00, null);
		t.assert_equal(c._state.uci.firewall.r_01hx.target, 'ACCEPT');
	});

	t.it('uci_rename returns false when the source section is absent', () => {
		let c = ubus.stub();
		t.assert_false(c.uci_rename('firewall', 'nope', 'whatever'));
	});

	t.it('uci_delete with option deletes that option only', () => {
		let c = ubus.stub({
			uci: { net: { lan: { proto: 'static', ipaddr: '1.2.3.4' } } }
		});
		c.uci_delete('net', 'lan', 'ipaddr');
		t.assert_deep_equal(c._state.uci.net.lan, { proto: 'static' });
	});

	t.it('uci_delete without option deletes the whole section', () => {
		let c = ubus.stub({
			uci: { net: { lan: { proto: 'static' } } }
		});
		c.uci_delete('net', 'lan');
		t.assert_equal(c._state.uci.net.lan, null);
	});

	t.it('uci_commit and uci_revert just record their ops', () => {
		let c = ubus.stub();
		c.uci_commit('firewall');
		c.uci_revert('network');
		t.assert_deep_equal(c._state.uci_ops, [
			['commit', 'firewall'],
			['revert', 'network'],
		]);
	});
});

t.describe('ubus.stub, snapshot round-trip', () => {
	t.it('uci_export then uci_import restores the package state', () => {
		let c = ubus.stub({
			uci: { fw: { r1: { '.type': 'rule', target: 'ACCEPT' } } }
		});
		let snap = c.uci_export('fw');
		c.uci_set('fw', 'r1', 'target', 'DROP');
		t.assert_equal(c._state.uci.fw.r1.target, 'DROP');
		c.uci_import('fw', snap);
		t.assert_equal(c._state.uci.fw.r1.target, 'ACCEPT');
	});
});

t.describe('ubus.stub, uci_foreach', () => {
	let initial = {
		uci: {
			fw: {
				z1: { '.type': 'zone', name: 'lan' },
				r1: { '.type': 'rule', target: 'ACCEPT' },
				r2: { '.type': 'rule', target: 'DROP' },
			}
		}
	};

	t.it('iterates all sections when sec_type is null', () => {
		let c = ubus.stub(initial);
		let seen = [];
		c.uci_foreach('fw', null, function(s) { push(seen, s['.name']); });
		t.assert_equal(length(seen), 3);
	});

	t.it('filters by section type', () => {
		let c = ubus.stub(initial);
		let seen = [];
		c.uci_foreach('fw', 'rule', function(s) { push(seen, s['.name']); });
		t.assert_equal(length(seen), 2);
		sort(seen);
		t.assert_deep_equal(seen, ['r1', 'r2']);
	});

	t.it('stops early when the callback returns false', () => {
		let c = ubus.stub(initial);
		let count = 0;
		c.uci_foreach('fw', 'rule', function(s) {
			count++;
			return false;
		});
		t.assert_equal(count, 1);
	});

	t.it('returns true when iteration completes', () => {
		let c = ubus.stub(initial);
		let r = c.uci_foreach('fw', 'zone', function(s) { });
		t.assert_equal(r, true);
	});
});

t.describe('ubus.stub, isolation', () => {
	t.it('mutating initial state does not affect the stub after construction', () => {
		let initial_uci = { net: { lan: { proto: 'static' } } };
		let c = ubus.stub({ uci: initial_uci });
		initial_uci.net.lan.proto = 'dhcp';
		t.assert_equal(c.uci_get('net', 'lan', 'proto'), 'static');
	});
});


const FAKE_UBUS = { connect: () => ({ call: () => null }), error: () => null };

// libuci as the uci and ucode of the OpenWrt SDK behave, in what these tests use. A load by name,
// which get, get_all, set, delete, rename and foreach do on first use, carries what `uci set`
// staged in /tmp/.uci, and reads /var/run/uci/<pkg> in place of the file when that exists. A load
// by path reads the file alone, and fails with "Duplicate entry" for a package that the cursor
// holds. A commit writes the copy that the cursor holds, and a revert also deletes what the shell
// staged. A failed call answers null and leaves its reason for error().
function fake_uci(disk) {
	let copy = (v) => json(sprintf("%J", v));
	return {
		cursor: function() {
			let held = {};
			let last = null;
			let fail = (why) => { last = why; return null; };
			function take(name, by_name) {
				if (held[name] == null) {
					let file = by_name ? (disk.override?.[name] ?? disk.files[name]) : disk.files[name];
					if (file == null) return null;
					held[name] = copy(file);
					if (by_name)
						for (let s, opts in disk.staged[name] ?? {})
							held[name][s] = { ...held[name][s], ...opts };
				}
				return held[name];
			}
			let section = (p, s) => take(p, true)?.[s] ?? fail("Entry not found");
			return {
				load: function(arg) {
					let name = fs.basename(arg);
					if (held[name] != null) return fail("Duplicate entry");
					return (take(name, index(arg, "/") < 0) != null) || fail("Entry not found");
				},
				unload: function(name) {
					let had = held[name] != null;
					delete held[name];
					return had;
				},
				get: (p, s, o) => section(p, s)?.[o],
				get_all: (p, s) => (section(p, s) != null) ? { ...section(p, s), '.name': s } : null,
				set: function(p, s, o, v) {
					if (v == null) {
						let pkg = take(p, true);
						if (pkg == null) return fail("Entry not found");
						pkg[s] = { ...(pkg[s] ?? {}), '.type': o };
						return true;
					}
					let sec = section(p, s);
					if (sec == null) return null;
					sec[o] = v;
					return true;
				},
				delete: function(p, s, o) {
					let sec = section(p, s);
					if (sec == null) return null;
					if (o == null)
						delete held[p][s];
					else if (sec[o] == null)
						return fail("Entry not found");
					else
						delete sec[o];
					return true;
				},
				rename: function(p, s, n) {
					let sec = section(p, s);
					if (sec == null) return null;
					held[p][n] = sec;
					delete held[p][s];
					return true;
				},
				foreach: function(p, sec_type, fn) {
					let pkg = take(p, true);
					if (pkg == null) return fail("Entry not found");
					for (let name, sec in pkg)
						if ((sec_type == null || sec['.type'] == sec_type) && fn({ ...sec, '.name': name }) === false)
							break;
					return true;
				},
				commit: function(p) {
					if (held[p] == null) return fail("Entry not found");
					disk.files[p] = copy(held[p]);
					disk.commits = (disk.commits ?? 0) + 1;
					return true;
				},
				revert: function(p) {
					delete disk.staged[p];
					delete held[p];
					return true;
				},
				error: function() {
					let why = last;
					last = null;
					return why;
				},
			};
		},
	};
}

function seeded() {
	return {
		files: { fw: {
			d: { '.type': 'defaults', input: 'ACCEPT', forward: 'REJECT', extra: '1', spare: '1' },
			r1: { '.type': 'rule', name: 'one' },
			r2: { '.type': 'rule', name: 'two' },
		} },
		staged: { fw: { d: { input: 'DROP' } } },
	};
}

function connect_to(disk, opts) {
	return ubus.connect({ ubus: FAKE_UBUS, uci: fake_uci(disk), ...(opts ?? {}) });
}

function temp_dir() {
	let p = fs.popen("mktemp -d /tmp/uapi-bus-restore.XXXXXX");
	let dir = trim(p.read("all") ?? "");
	p.close();
	return dir;
}

function caught(fn) {
	try { fn(); } catch (e) { return e.message; }
	return null;
}

t.describe('bus.connect, changes that the shell staged and did not commit', () => {
	t.it('a read reports what the file holds', () => {
		let c = connect_to(seeded());
		t.assert_equal(c.uci_get('fw', 'd', 'input'), 'ACCEPT');
		t.assert_equal(c.uci_get('fw', 'd').input, 'ACCEPT');
	});

	t.it('a foreach reports what the file holds', () => {
		let seen = [];
		connect_to(seeded()).uci_foreach('fw', 'defaults', (s) => push(seen, s.input));
		t.assert_deep_equal(seen, [ 'ACCEPT' ]);
	});

	t.it('a commit stores the writes of the request and leaves the staged change staged', () => {
		let disk = seeded();
		let c = connect_to(disk);
		c.uci_set('fw', 'd', 'forward', 'ACCEPT');
		c.uci_commit('fw');
		t.assert_equal(disk.files.fw.d.input, 'ACCEPT');
		t.assert_equal(disk.files.fw.d.forward, 'ACCEPT');
		t.assert_deep_equal(disk.staged.fw, { d: { input: 'DROP' } });
	});

	t.it('a revert drops the writes of the request and keeps the staged change', () => {
		let disk = seeded();
		let c = connect_to(disk);
		c.uci_set('fw', 'd', 'forward', 'ACCEPT');
		c.uci_revert('fw');
		t.assert_equal(c.uci_get('fw', 'd', 'forward'), 'REJECT');
		t.assert_deep_equal(disk.staged.fw, { d: { input: 'DROP' } });
	});
});

t.describe('bus.connect, a package that does not load by its path', () => {
	t.it('answers null to a read and fails a write, where a load by name would read the override', () => {
		let disk = { files: {}, staged: {}, override: { ov: { s: { '.type': 'x', v: 'override' } } } };
		let c = connect_to(disk);
		let seen = [];
		t.assert_equal(c.uci_get('ov', 's', 'v'), null);
		t.assert_equal(c.uci_foreach('ov', null, (s) => push(seen, s)), null);
		t.assert_deep_equal(seen, []);
		t.assert_equal(caught(() => c.uci_set('ov', 's', 'v', 'mine')), "uci load ov: Entry not found");
	});

	t.it('is every name that uci does not load, such as the temp files of libuci and of the restore', () => {
		let section = { s: { '.type': 'zone', name: 'lan' } };
		let c = connect_to({ files: { '.fw.uci-AbC123': section, '.fw.uapi-restore': section }, staged: {} });
		for (let name in [ '.fw.uci-AbC123', '.fw.uapi-restore' ]) {
			let seen = [];
			t.assert_equal(c.uci_get(name, 's', 'name'), null, name);
			t.assert_equal(c.uci_foreach(name, null, (s) => push(seen, s)), null, name);
			t.assert_deep_equal(seen, [], name);
			t.assert_match(caught(() => c.uci_set(name, 's', 'name', 'x')), /^uci load /, name);
		}
	});
});

t.describe('bus.connect, the commit', () => {
	t.it('replays every kind of write over the file as another writer left it', () => {
		let disk = seeded();
		let c = connect_to(disk);
		c.uci_set('fw', 'd', 'forward', 'ACCEPT');
		c.uci_set('fw', 'd', 'extra', []);
		c.uci_delete('fw', 'd', 'spare');
		c.uci_create_section('fw', 'z', 'zone');
		c.uci_set('fw', 'z', 'name', 'lan');
		c.uci_rename('fw', 'r1', 'r_one');
		c.uci_delete('fw', 'r2');
		disk.files.fw.d.output = 'DROP';
		t.assert_equal(c.uci_commit('fw'), true);
		t.assert_deep_equal(disk.files.fw, {
			d: { '.type': 'defaults', input: 'ACCEPT', forward: 'ACCEPT', output: 'DROP' },
			z: { '.type': 'zone', name: 'lan' },
			r_one: { '.type': 'rule', name: 'one' },
		});
	});

	t.it('leaves the file alone when the request wrote nothing to the package', () => {
		let disk = seeded();
		let c = connect_to(disk);
		c.uci_get('fw', 'd', 'input');
		disk.files.fw.d.output = 'DROP';
		t.assert_equal(c.uci_commit('fw'), false);
		t.assert_equal(disk.commits, null);
		t.assert_equal(disk.files.fw.d.output, 'DROP');
	});

	t.it('fails, names the package and writes nothing when a write no longer applies', () => {
		let disk = seeded();
		let c = connect_to(disk);
		c.uci_set('fw', 'r2', 'name', 'deux');
		delete disk.files.fw.r2;
		t.assert_equal(caught(() => c.uci_commit('fw')),
		               "uci commit fw: another writer changed the package while the request ran, and its writes no longer apply: uci set fw: Entry not found");
		t.assert_equal(disk.commits, null);
	});
});

t.describe('bus.connect, the restore of a snapshot', () => {
	const BEFORE = "config defaults 'd'\n\toption forward 'ACCEPT'\n";
	const SNAPSHOT = "config defaults 'd'\n\toption forward 'REJECT'\n";

	function restore_with(fs_mod) {
		let dir = temp_dir();
		fs.writefile(dir + "/fw", BEFORE);
		fs.chmod(dir + "/fw", 0o640);
		let c = connect_to({ files: {}, staged: {} }, { config_dir: dir, fs: fs_mod ?? fs });
		let err = caught(() => c.uci_import('fw', SNAPSHOT));
		let out = { dir, err, content: fs.readfile(dir + "/fw"), mode: fs.stat(dir + "/fw").mode,
		            files: fs.lsdir(dir) };
		system([ "rm", "-rf", dir ]);
		return out;
	}

	t.it('replaces the file, keeps its mode and leaves no temp file', () => {
		let r = restore_with(null);
		t.assert_equal(r.err, null);
		t.assert_equal(r.content, SNAPSHOT);
		t.assert_equal(r.mode, 0o640);
		t.assert_deep_equal(r.files, [ "fw" ]);
	});

	t.it('holds the flock that libuci takes on the package across the rename', () => {
		let free_during = "no rename";
		let r = restore_with({ ...fs, rename: function(from, to) {
			let probe = fs.open(to, "r");
			free_during = probe.lock("sn");
			probe.close();
			return fs.rename(from, to);
		} });
		t.assert_equal(r.content, SNAPSHOT);
		t.assert_equal(free_during, null);
	});

	t.it('gives up on a lock that another process holds, naming the file and leaving it whole', () => {
		let dir = temp_dir();
		fs.writefile(dir + "/fw", BEFORE);
		let holder = fs.open(dir + "/fw", "r");
		holder.lock("x");
		let c = connect_to({ files: {}, staged: {} }, { config_dir: dir, lock_wait_ms: 100 });
		let err = caught(() => c.uci_import('fw', SNAPSHOT));
		holder.lock("u");
		holder.close();
		let content = fs.readfile(dir + "/fw"), files = fs.lsdir(dir);
		system([ "rm", "-rf", dir ]);
		t.assert_equal(err, sprintf("restore of %s/fw: another process held its lock for 100 ms", dir));
		t.assert_equal(content, BEFORE);
		t.assert_deep_equal(files, [ "fw" ]);
	});

	t.it('replaces the target of a symlinked package and keeps the link', () => {
		let dir = temp_dir();
		fs.mkdir(dir + "/real");
		fs.writefile(dir + "/real/fw", BEFORE);
		fs.symlink(dir + "/real/fw", dir + "/fw");
		let c = connect_to({ files: {}, staged: {} }, { config_dir: dir });
		let err = caught(() => c.uci_import('fw', SNAPSHOT));
		let link = fs.lstat(dir + "/fw").type, content = fs.readfile(dir + "/real/fw"), files = fs.lsdir(dir + "/real");
		system([ "rm", "-rf", dir ]);
		t.assert_equal(err, null);
		t.assert_equal(link, "link");
		t.assert_equal(content, SNAPSHOT);
		t.assert_deep_equal(files, [ "fw" ]);
	});

	// A full overlay takes part of the buffer, and the failure reaches only the fclose that
	// ucode's close() does not report.
	t.it('fails naming the file and leaves it whole when the filesystem cannot hold the snapshot', () => {
		let r = restore_with({ ...fs, open: function(path, mode, perm) {
			let f = fs.open(path, mode, perm);
			if (f == null || substr(mode, 0, 1) != "w") return f;
			return { write: (s) => { f.write(substr(s, 0, 10)); return length(s); },
			         close: () => f.close() };
		} });
		t.assert_match(r.err, regexp("^restore of " + r.dir + "/fw: cannot write "));
		t.assert_equal(r.content, BEFORE);
		t.assert_deep_equal(r.files, [ "fw" ]);
	});

	t.it('fails naming the file and leaves it whole when the mode cannot be set', () => {
		let r = restore_with({ ...fs, chmod: () => null });
		t.assert_match(r.err, regexp("^restore of " + r.dir + "/fw: cannot set the mode of "));
		t.assert_equal(r.content, BEFORE);
		t.assert_deep_equal(r.files, [ "fw" ]);
	});

	t.it('fails naming the file and leaves it whole when the rename fails', () => {
		let r = restore_with({ ...fs, rename: () => null });
		t.assert_match(r.err, regexp("^restore of " + r.dir + "/fw: cannot rename "));
		t.assert_equal(r.content, BEFORE);
		t.assert_deep_equal(r.files, [ "fw" ]);
	});

	t.it('fails naming the file when the package is gone', () => {
		let c = connect_to({ files: {}, staged: {} }, { config_dir: "/nonexistent" });
		t.assert_equal(caught(() => c.uci_import('fw', SNAPSHOT)), "restore of /nonexistent/fw: cannot open it");
	});

	t.it('discards the writes of the request, so the commit that follows has nothing to apply', () => {
		let disk = seeded();
		let dir = temp_dir();
		fs.writefile(dir + "/fw", BEFORE);
		let c = connect_to(disk, { config_dir: dir });
		c.uci_set('fw', 'd', 'forward', 'ACCEPT');
		c.uci_import('fw', SNAPSHOT);
		let committed = c.uci_commit('fw');
		system([ "rm", "-rf", dir ]);
		t.assert_equal(committed, false);
		t.assert_equal(disk.files.fw.d.forward, 'REJECT');
	});
});

// The bus commits only a package that the request wrote, and a write of the value that uci holds
// still counts. A PATCH that names nothing wrote each stored secret again, because the read masks
// it, so on any section with one the commit rewrote the package and dropped its comments. On the
// goto rule nr3 it deleted the `action` that toUci clears and the rule does not hold.
t.describe('bus.connect, a PATCH that names nothing commits nothing', () => {
	let handler = require('handler');
	let fx = require('resource_fixtures');
	let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null,
	           wg_apply: () => null, wg_reconcile: () => null };
	for (let id in [ "wg0", "p1", "w1", "vpn0", "nr3" ]) {
		let c = filter(fx.CASES, (x) => x.id == id)[0];
		t.it(sprintf("%s/%s", c.file, id), () => {
			let files = fx.world();
			files[c.pkg] = { ...(files[c.pkg] ?? {}), [id]: { ...c.section } };
			let disk = { files, staged: {} };
			let dir = temp_dir();
			for (let pkg in files) fs.writefile(dir + "/" + pkg, "");
			let conn = connect_to(disk, { config_dir: dir });
			let r = handler.make(loadfile('src/resources/' + c.file)(), { tx })
			               .patch(conn, { request_id: "01hx0000000000000000000000" }, id, {});
			system([ "rm", "-rf", dir ]);
			t.assert_equal(r.status, 200, r.body);
			t.assert_equal(disk.commits, null);
		});
	}
});
