let t = require('harness');
let fs = require('fs');

// 3.5.0 announced that every resource answers `runtime` in v4, an object that the schema requires
// (#322). The curated resources and system/cron_jobs already returned it. These pin the non-uci
// responses that gained it, or whose schema did not require it, and dhcp_leases_test.uc pins the
// items of make_collection.

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

const DIR = '/tmp/uapi-test-runtime';
const KEY_A = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl a@x';
const KEY_B = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb b@x';

// /etc/dropbear and /etc/apk/repositories.d live under DIR, and the global lock beside it.
function at(path) {
	if (path == '/var/lock/uapi.lock') return DIR + '.lock';
	return replace(path, /^\/etc\/(dropbear|apk\/repositories\.d)/, DIR);
}

const APK = {
	"apk info 2>&1": "uapi\n",
	"apk info -e -- uapi 2>&1": "uapi",
	"apk query --from installed --fields name,version --format json -- uapi 2>&1": '[{"name":"uapi","version":"4.0.0-r1"}]',
};

function with_stubbed(names, fn) {
	fs.mkdir(DIR);
	for (let f in fs.lsdir(DIR)) fs.unlink(DIR + '/' + f);
	let mod = t.load_with_fs({ ...fs,
		readfile: (p) => fs.readfile(at(p)),
		stat: (p) => fs.stat(at(p)),
		open: (p, m) => fs.open(at(p), m),
		unlink: (p) => fs.unlink(at(p)),
		chmod: (p, m) => fs.chmod(at(p), m),
		rename: (a, b) => fs.rename(at(a), at(b)),
		lsdir: (p) => fs.lsdir(at(p)),
		popen: (cmd) => ({ read: () => APK[cmd] ?? "", close: () => 0 }),
	}, [ 'transaction', 'non_uci', ...names ]);
	let caught = null;
	try { fn(mod); } catch (e) { caught = e; }
	for (let f in fs.lsdir(DIR)) fs.unlink(DIR + '/' + f);
	fs.rmdir(DIR);
	fs.unlink(DIR + '.lock');
	if (caught != null) die(caught);
}

t.describe('runtime: system/authorized_keys', () => {
	t.it('every key of every GET, POST and PUT holds runtime {}', () => with_stubbed([ 'system_access' ], (sa) => {
		let added = sa.add_key(ctx(), { key: KEY_A });
		t.assert_equal(added.status, 200);
		t.assert_deep_equal(added.body.runtime, {});
		t.assert_deep_equal(map(sa.list_keys(ctx()).body, (k) => k.runtime), [ {} ]);
		t.assert_deep_equal(sa.get_key(ctx(), added.body.id).body.runtime, {});
		let put = sa.replace_keys(ctx(), { keys: [ KEY_A, KEY_B ] });
		t.assert_equal(put.status, 200);
		t.assert_deep_equal(map(put.body, (k) => k.runtime), [ {}, {} ]);
	}));
});

t.describe('runtime: packages/installed and packages/feeds', () => {
	t.it('every package of every GET and POST holds runtime {}', () => with_stubbed([ 'packages' ], (p) => {
		t.assert_deep_equal(map(p.list_installed(ctx()).body, (e) => e.runtime), [ {} ]);
		t.assert_deep_equal(p.get_installed(ctx(), "uapi").body.runtime, {});
		let r = p.install(ctx(), { name: "uapi" });
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body.runtime, {});
	}));

	t.it('every feed of every GET and POST holds runtime {}', () => with_stubbed([ 'packages' ], (p) => {
		let r = p.create_feed(ctx(), { name: "extra", url: "https://example.com/extra" });
		t.assert_equal(r.status, 200);
		t.assert_deep_equal(r.body.runtime, {});
		t.assert_deep_equal(map(p.list_feeds(ctx()).body, (e) => e.runtime), [ {} ]);
		t.assert_deep_equal(p.get_feed(ctx(), "extra").body.runtime, {});
	}));
});

// Each 2xx body of a resource path. /raw answers the uci section, where a `runtime` key would hide
// an option of that name, and the special endpoints under /uapi are not resources.
t.describe('runtime: the spec', () => {
	let spec = json(fs.readfile("build/openapi.json"));
	let schemas = spec.components.schemas;
	let names = {};
	for (let path, ops in spec.paths) {
		if (match(path, /^\/(uapi|raw)\//) || index([ "/healthz", "/openapi.json" ], path) >= 0
		    || match(path, /^\/schema\//))
			continue;
		for (let verb, op in ops)
			for (let code, r in op?.responses ?? {}) {
				let s = r?.content?.["application/json"]?.schema;
				let ref = s?.["$ref"] ?? s?.items?.["$ref"];
				if (match(code, /^2/) && ref != null) names[replace(ref, /^.*\//, "")] = true;
			}
	}
	t.it('finds the curated, non-uci and collection schemas', () => {
		for (let n in [ "SystemResponse", "CronJob", "InstalledPackage", "PackageFeed", "SSHAuthorizedKey",
		                "DhcpLeasesResponse", "NetworkWireguardKernelPeersResponse" ])
			t.assert_true(names[n], n);
	});
	for (let n in sort(keys(names)))
		t.it(sprintf("%s requires a read-only runtime object", n), () => {
			t.assert_true(index(schemas[n].required ?? [], "runtime") >= 0);
			t.assert_equal(schemas[n].properties.runtime.type, "object");
			t.assert_true(schemas[n].properties.runtime.readOnly);
		});
});
