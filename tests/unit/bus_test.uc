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

// libuci as the uci and ucode of the OpenWrt SDK behave: a package loaded by name carries what
// `uci set` staged in /tmp/.uci, also when the cursor loads it on first use, one loaded by its
// path carries the file alone and commits the copy that the cursor holds, and a revert also
// deletes what the shell staged.
function fake_uci(disk) {
	let copy = (v) => json(sprintf("%J", v));
	return {
		cursor: function() {
			let held = {};
			function take(name, with_staged) {
				if (held[name] == null && disk.files[name] != null) {
					held[name] = copy(disk.files[name]);
					if (with_staged)
						for (let s, opts in disk.staged[name] ?? {})
							held[name][s] = { ...held[name][s], ...opts };
				}
				return held[name];
			}
			return {
				load: (arg) => take(fs.basename(arg), index(arg, "/") < 0) != null,
				unload: (name) => delete held[name],
				get: (p, s, o) => take(p, true)?.[s]?.[o],
				set: function(p, s, o, v) {
					let sec = take(p, true)?.[s];
					if (sec == null) return null;
					sec[o] = v;
					return true;
				},
				commit: function(p) {
					if (held[p] == null) return null;
					disk.files[p] = copy(held[p]);
					return true;
				},
				revert: function(p) {
					delete disk.staged[p];
					delete held[p];
					return true;
				},
				error: () => "Entry not found",
			};
		},
	};
}

function seeded() {
	return {
		files: { fw: { d: { '.type': 'defaults', input: 'ACCEPT', forward: 'REJECT' } } },
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

t.describe('bus.connect, changes that the shell staged and did not commit', () => {
	t.it('a read reports what the file holds', () => {
		t.assert_equal(connect_to(seeded()).uci_get('fw', 'd', 'input'), 'ACCEPT');
	});

	t.it('a commit stores the writes of the request and leaves the staged change staged', () => {
		let disk = seeded();
		let c = connect_to(disk);
		c.uci_set('fw', 'd', 'forward', 'ACCEPT');
		c.uci_commit('fw');
		t.assert_deep_equal(disk.files.fw.d, { '.type': 'defaults', input: 'ACCEPT', forward: 'ACCEPT' });
		t.assert_deep_equal(disk.staged.fw, { d: { input: 'DROP' } });
	});

	t.it('a commit keeps what another writer committed while the request ran', () => {
		let disk = seeded();
		let c = connect_to(disk);
		c.uci_set('fw', 'd', 'forward', 'ACCEPT');
		disk.files.fw.d.output = 'DROP';
		c.uci_commit('fw');
		t.assert_equal(disk.files.fw.d.output, 'DROP');
		t.assert_equal(disk.files.fw.d.forward, 'ACCEPT');
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

t.describe('bus.connect, the restore of a snapshot', () => {
	const BEFORE = "config defaults 'd'\n\toption forward 'ACCEPT'\n";
	const SNAPSHOT = "config defaults 'd'\n\toption forward 'REJECT'\n";

	function restore_with(fs_mod) {
		let dir = temp_dir();
		fs.writefile(dir + "/fw", BEFORE);
		fs.chmod(dir + "/fw", 0o640);
		let c = connect_to({ files: {}, staged: {} }, { config_dir: dir, fs: fs_mod ?? fs });
		let err = null;
		try { c.uci_import('fw', SNAPSHOT); } catch (e) { err = "" + e; }
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

	t.it('fails naming the file and leaves it whole when the rename fails', () => {
		let r = restore_with({ ...fs, rename: () => null });
		t.assert_match(r.err, regexp("^restore of " + r.dir + "/fw: cannot rename "));
		t.assert_equal(r.content, BEFORE);
		t.assert_deep_equal(r.files, [ "fw" ]);
	});

	t.it('fails naming the file when the package is gone', () => {
		let c = connect_to({ files: {}, staged: {} }, { config_dir: "/nonexistent" });
		let err = null;
		try { c.uci_import('fw', SNAPSHOT); } catch (e) { err = "" + e; }
		t.assert_equal(err, "restore of /nonexistent/fw: cannot open it");
	});

	t.it('discards the writes of the request, so the commit that follows does not apply them again', () => {
		let disk = seeded();
		let dir = temp_dir();
		fs.writefile(dir + "/fw", BEFORE);
		let c = connect_to(disk, { config_dir: dir });
		c.uci_set('fw', 'd', 'forward', 'ACCEPT');
		c.uci_import('fw', SNAPSHOT);
		c.uci_commit('fw');
		system([ "rm", "-rf", dir ]);
		t.assert_equal(disk.files.fw.d.forward, 'REJECT');
	});
});
