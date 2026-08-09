#!/usr/bin/ucode

// Emits "<package>\t<module>\t<uci option>" for every option a resource writes, which is
// the input to the dead-field audit. Reads the modules as text rather than loading them,
// because loading pulls in `values` and a bus connection that do not exist off-device.

import * as fs from 'fs';

let dir = fs.opendir("src/resources");
let files = [];
for (let e = dir.read(); e != null; e = dir.read())
	if (substr(e, -3) == ".uc") push(files, e);
dir.close();

for (let name in sort(files)) {
	let f = fs.open("src/resources/" + name, "r");
	let src = f.read("all") ?? "";
	f.close();

	let pkg = match(src, /package:[ \t]*["']([^"']+)["']/);
	if (!pkg) pkg = match(src, /const PKG[ \t]*=[ \t]*["']([^"']+)["']/);
	pkg = pkg ? pkg[1] : "?";

	let seen = {};
	for (let m in match(src, /out\.([A-Za-z_][A-Za-z0-9_]*)[ \t]*=/g))
		seen[m[1]] = true;
	for (let m in match(src, /out\[['"]([^'"]+)['"]\][ \t]*=/g))
		seen[m[1]] = true;
	delete seen.runtime;

	for (let opt in sort(keys(seen)))
		printf("%s\t%s\t%s\n", pkg, name, opt);
}
