let t = require('harness');
let ubus = require('bus');
let fs = require('fs');
let fx = require('resource_fixtures');

// A keyword under x-uapi-write, or in openapi_write_conditional, narrows only the request schema
// and nothing at runtime reads it, so it holds only while validate() refuses the same values.

function errors_on(mod, c, field, value) {
	let uci = fx.world();
	if (uci[c.pkg] == null) uci[c.pkg] = {};
	uci[c.pkg][c.id] = { '.anonymous': false, ...c.section };
	let conn = ubus.stub({ uci: uci });
	let view = mod.fromUci({ '.name': c.id, '.anonymous': false, ...c.section }, conn);
	delete view.runtime;
	let delta = { [field]: value };
	return filter(mod.validate({ ...view, ...delta }, conn, c.id, delta) ?? [], (e) => e.field == field);
}

function chars(n) {
	let s = "";
	for (let i = 0; i < n; i++) s += "a";
	return s;
}

function probes(keyword, bound) {
	switch (keyword) {
	case "minimum":   return { code: "out_of_range", past: [ bound - 1 ], at: [ bound ] };
	case "maximum":   return { code: "out_of_range", past: [ bound + 1 ], at: [ bound ] };
	case "maxLength": return { code: "out_of_range", past: [ chars(bound + 1) ], at: [ chars(bound) ] };
	case "enum":      return { code: "not_in_enum", past: [ "uapi_not_listed" ], at: bound };
	}
	return null;
}

// Some cases refuse the value for another reason, as a listen_port on a static interface is a
// conflict, so the keyword's own code only has to come from one of them.
function check(mod, cases, field, keyword, bound) {
	let p = probes(keyword, bound);
	if (p == null) {
		t.assert_equal(sprintf("no probe for keyword %s", keyword), "a probe");
		return;
	}
	if (length(cases) == 0) {
		t.assert_equal(sprintf("no fixture case for %s", field), "a case");
		return;
	}
	for (let v in p.past) {
		let own = false;
		for (let c in cases) {
			let errs = errors_on(mod, c, field, v);
			if (length(errs) == 0)
				t.assert_equal(sprintf("%s accepted %s %J", c.id, field, v), "refused");
			for (let e in errs) if (e.code == p.code) own = true;
		}
		if (!own)
			t.assert_equal(sprintf("no case refuses %s %J with %s", field, v, p.code), "refused");
	}
	for (let v in p.at) {
		let passes = false;
		for (let c in cases)
			if (length(errors_on(mod, c, field, v)) == 0) passes = true;
		if (!passes)
			t.assert_equal(sprintf("no case accepts %s %J", field, v), "accepted");
	}
}

function matches(mod, c, cond) {
	let view = mod.fromUci({ '.name': c.id, '.anonymous': false, ...c.section }, null);
	for (let k, spec in cond.if?.properties ?? {})
		if (exists(spec, "const") ? spec.const != view[k] : index(spec.enum ?? [], view[k]) == -1)
			return false;
	return true;
}

t.describe('property: every request-only keyword is a refusal in validate()', () => {
	let found = 0;
	let files = fs.lsdir('src/resources') ?? [];
	sort(files);
	for (let f in files) {
		if (!match(f, /\.uc$/)) continue;
		let mod = loadfile('src/resources/' + f)();
		let cases = filter(fx.CASES, (c) => c.file == f);
		for (let field, spec in mod.schema_properties ?? {})
			for (let keyword, bound in (type(spec) == "object" ? spec["x-uapi-write"] : null) ?? {}) {
				found++;
				t.it(sprintf("%s %s %s", f, field, keyword), () => check(mod, cases, field, keyword, bound));
			}
		for (let cond in mod.openapi_write_conditional ?? []) {
			let matching = filter(cases, (c) => matches(mod, c, cond));
			for (let field, spec in cond.then?.properties ?? {})
				for (let keyword, bound in spec) {
					found++;
					t.it(sprintf("%s %s %s when %J", f, field, keyword, cond.if?.properties),
					     () => check(mod, matching, field, keyword, bound));
				}
		}
	}
	t.it('finds keywords to check', () => t.assert_true(found > 0));
});
