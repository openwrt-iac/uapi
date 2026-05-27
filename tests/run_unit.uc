import * as fs from 'fs';
let t = require('harness');

let unit_dir = 'tests/unit';
let entries = fs.lsdir(unit_dir) ?? [];
sort(entries);

let ran = 0;
for (let name in entries) {
	if (!match(name, /_test\.uc$/)) continue;
	ran++;
	printf("\n[%s]\n", name);
	let mod = loadfile(unit_dir + '/' + name);
	mod();
}

if (ran == 0) {
	print("no test files found\n");
	exit(1);
}

t.summary();
