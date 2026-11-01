import * as fs from 'fs';
let t = require('harness');

const MAKEFILE = fs.readfile("build/openwrt/uapi/Makefile");
const HOOK = fs.readfile("files/etc/uci-defaults/99-uapi");
const TEMPLATE = fs.readfile("files/usr/share/uapi/config.template");

function block(name) {
	let start = index(MAKEFILE, "\ndefine " + name + "\n");
	if (start < 0) return "";
	let body = substr(MAKEFILE, start + length(name) + 9);
	return substr(body, 0, index(body, "\nendef\n"));
}

const TOKENS = "\nconfig token 'admin'\n\toption salt 's'\n\toption hash 'h'\n\tlist scopes '*:rw'\n";

function real_path(cmd) {
	let p = fs.popen("command -v " + cmd);
	let path = trim(p.read("all") ?? "");
	p.close();
	return path;
}

// The hook names absolute paths, and the unit job can neither chroot nor mount, so it runs as a
// copy whose paths under /etc and /usr/share/uapi lie in a temp dir, with a uci that does nothing.
// `raced` puts a cp first in PATH that writes a store with a token before it copies, as a
// uapi-token create between the hook's test and its write would.
function run_hook(store, raced) {
	let mk = fs.popen("mktemp -d /tmp/uapi-hook.XXXXXX");
	let dir = trim(mk.read("all") ?? "");
	mk.close();
	system([ "mkdir", "-p", dir + "/bin", dir + "/etc/config", dir + "/usr/share/uapi" ]);
	fs.writefile(dir + "/bin/uci", "#!/bin/sh\nexit 0\n");
	fs.chmod(dir + "/bin/uci", 0o755);
	if (raced) {
		fs.writefile(dir + "/raced", TOKENS);
		fs.writefile(dir + "/bin/cp", sprintf("#!/bin/sh\ncat %s/raced > %s/etc/config/uapi\nexec %s \"$@\"\n",
			dir, dir, real_path("cp")));
		fs.chmod(dir + "/bin/cp", 0o755);
	}
	fs.writefile(dir + "/usr/share/uapi/config.template", TEMPLATE);
	if (store != null) {
		fs.writefile(dir + "/etc/config/uapi", store.content);
		fs.chmod(dir + "/etc/config/uapi", store.mode);
	}
	let hook = replace(replace(HOOK, "/etc/", dir + "/etc/"), "/usr/share/uapi/", dir + "/usr/share/uapi/");
	fs.writefile(dir + "/99-uapi", hook);
	let code = system(sprintf("umask 022; PATH=%s/bin:$PATH sh %s/99-uapi >/dev/null 2>&1", dir, dir));
	let st = fs.stat(dir + "/etc/config/uapi");
	let content = fs.readfile(dir + "/etc/config/uapi");
	let left = fs.lsdir(dir + "/etc/config");
	system([ "rm", "-rf", dir ]);
	return { code, mode: st?.mode, content, left };
}

t.describe('99-uapi, the token store', () => {
	t.it('creates a missing store from the template, readable by root only', () => {
		let r = run_hook(null);
		t.assert_equal(r.code, 0);
		t.assert_equal(r.content, TEMPLATE);
		t.assert_equal(sprintf("%o", r.mode), "600");
		t.assert_deep_equal(r.left, [ "uapi" ]);
	});

	t.it('keeps the content of a store that exists, and makes it readable by root only', () => {
		let r = run_hook({ content: TOKENS, mode: 0o644 });
		t.assert_equal(r.code, 0);
		t.assert_equal(r.content, TOKENS);
		t.assert_equal(sprintf("%o", r.mode), "600");
	});

	t.it('keeps a store that uapi-token create made after the test for one', () => {
		let r = run_hook(null, true);
		t.assert_equal(r.code, 0);
		t.assert_equal(r.content, TOKENS);
		t.assert_deep_equal(r.left, [ "uapi" ]);
	});
});

t.describe('the package Makefile', () => {
	t.it('installs nothing under /etc/config, where apk would leave an .apk-new at each upgrade', () => {
		let install = block("Package/uapi/install");
		t.assert_true(index(install, "$(1)/usr/share/uapi/main.uc") >= 0, "no install block found");
		t.assert_equal(index(install, "$(1)/etc/config"), -1);
	});

	// The build turns a conffile that the package does not ship into /lib/upgrade/keep.d/uapi, so
	// that the package names its own store for sysupgrade, besides the /etc/config/ of base-files.
	t.it('lists the token store as a conffile, so that the package names it for sysupgrade', () => {
		t.assert_match(block("Package/uapi/conffiles"), /^\/etc\/config\/uapi$/s);
	});

	t.it('installs the template that the hook copies', () => {
		let m = match(HOOK, /cp (\/usr\/share\/uapi\/[^ ]+) /);
		t.assert_true(m, "the hook copies no template");
		t.assert_true(index(block("Package/uapi/install"), "$(1)" + m[1]) >= 0, m[1]);
	});
});
