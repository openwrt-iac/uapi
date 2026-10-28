#!/usr/bin/ucode

// docs/lock-state-audit.md said "17 sites audited" while its own reproduction command found 36,
// and nine modules, one of them added that release, were absent from its table. Nothing read the
// table, so the gap grew without anyone seeing it. The command is run from the doc rather than
// copied here, so the two cannot disagree about what a site is.
//
// A row's range only has to contain its sites, so an edit that moves a site within its range
// passes. The "covers all N sites" count is what catches a new site added inside a range that
// already holds one.

import * as fs from 'fs';

const DOC = "docs/lock-state-audit.md";
const COUNTED = [ DOC, "CLAUDE.md" ];
// Only this shape is run: everything that varies is inside the single quotes, where the shell
// interprets nothing.
const COMMAND_RE = /^grep -rnE '[^']+' src\/ cli\/$/;

function read(path) {
	let f = fs.open(path, "r");
	if (!f) die(sprintf("cannot read %s", path));
	let s = f.read("all") ?? "";
	f.close();
	return s;
}

let problems = [];
let doc = split(read(DOC), "\n");

let commands = filter(doc, (l) => match(l, COMMAND_RE));
if (length(commands) != 1) {
	printf("FAIL: %s must hold exactly one line of the form grep -rnE '<pattern>' src/ cli/, found %d\n",
	       DOC, length(commands));
	exit(1);
}

let p = fs.popen(commands[0], "r");
let output = p ? (p.read("all") ?? "") : "";
let code = p ? p.close() : -1;
// grep exits 1 when nothing matches. An empty run cannot be right for this tree, and passing
// on it would repeat lint-emdash, which reported success for releases without reading a file.
if (code != 0) {
	printf("FAIL: the reproduction command exited %d and so found no site:\n  %s\n", code, commands[0]);
	exit(1);
}

let sites = [];
for (let line in split(output, "\n")) {
	if (line == "") continue;
	let m = match(line, /^([^:]+):([0-9]+):(.*)$/);
	if (!m) {
		printf("FAIL: cannot read this line of the command's output:\n  %s\n", line);
		exit(1);
	}
	push(sites, { file: m[1], line: int(m[2]), text: trim(m[3]), rows: 0 });
}

let rows = [];
let in_sites = false;
for (let i = 0; i < length(doc); i++) {
	if (match(doc[i], /^## /)) in_sites = (doc[i] == "## Sites");
	if (!in_sites) continue;
	let m = match(doc[i], /^\| `([^`]+)` \| ([0-9]+)(-([0-9]+))? \|/);
	if (m) push(rows, { file: m[1], from: int(m[2]), to: int(m[4] ?? m[2]), at: i + 1, held: 0 });
}
if (length(rows) == 0) {
	printf("FAIL: no rows found under \"## Sites\" in %s\n", DOC);
	exit(1);
}

// Named so a failure says where to look: a row that drifted usually still sits in the
// function it was written for.
function enclosing(file, line) {
	let src = split(read(file), "\n");
	for (let i = line - 1; i >= 0; i--) {
		let m = match(src[i], /function ([A-Za-z0-9_]+)\(/) ?? match(src[i], /([A-Za-z0-9_]+): function\(/);
		if (m) return m[1] + "()";
	}
	return "top level";
}

for (let s in sites)
	for (let r in rows)
		if (r.file == s.file && s.line >= r.from && s.line <= r.to) { s.rows++; r.held++; }

for (let s in sites) {
	if (s.rows == 0)
		push(problems, sprintf("%s:%d in %s is not in %s: %s",
		                       s.file, s.line, enclosing(s.file, s.line), DOC, s.text));
	else if (s.rows > 1)
		push(problems, sprintf("%s:%d is covered by %d rows of %s, so no single proof applies to it",
		                       s.file, s.line, s.rows, DOC));
}
for (let r in rows) {
	if (r.from > r.to || fs.stat(r.file) == null)
		push(problems, sprintf("%s:%d names %s %d-%d, which is no range of an existing file",
		                       DOC, r.at, r.file, r.from, r.to));
	else if (r.held == 0)
		push(problems, sprintf("%s:%d names %s %d-%d, which holds no acquisition the command finds",
		                       DOC, r.at, r.file, r.from, r.to));
}

let claims = 0;
for (let path in COUNTED) {
	let lines = split(read(path), "\n");
	for (let i = 0; i < length(lines); i++)
		for (let m in match(lines[i], /covers all ([0-9]+) sites/g) ?? []) {
			claims++;
			if (int(m[1]) != length(sites))
				push(problems, sprintf("%s:%d states %s sites, the command finds %d",
				                       path, i + 1, m[1], length(sites)));
		}
}
if (claims == 0)
	push(problems, sprintf("%s states no \"covers all N sites\" count", DOC));

if (length(problems) > 0) {
	printf("FAIL: %d problem(s) with the coverage of %s:\n", length(problems), DOC);
	for (let x in problems) printf("  %s\n", x);
	exit(1);
}

printf("OK: %d sites, each in exactly one of %d rows of %s\n", length(sites), length(rows), DOC);
