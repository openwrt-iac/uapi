let t = require('harness');
let ubus = require('bus');
let fs = require('fs');
let fx = require('resource_fixtures');

// A keyword under x-uapi-write, or in openapi_write_conditional, narrows only the request schema
// and nothing at runtime reads it, so it holds only while validate() refuses the same values.

function set_path(obj, parts, value) {
	let out = { ...(type(obj) == "object" ? obj : {}) };
	out[parts[0]] = (length(parts) == 1) ? value : set_path(out[parts[0]], slice(parts, 1), value);
	return out;
}

function errors_on(mod, c, o, value) {
	let uci = fx.world();
	if (uci[c.pkg] == null) uci[c.pkg] = {};
	uci[c.pkg][c.id] = { '.anonymous': false, ...c.section };
	let conn = ubus.stub({ uci: uci });
	let view = mod.fromUci({ '.name': c.id, '.anonymous': false, ...c.section }, conn);
	delete view.runtime;
	let v = o.element ? [ value ] : value;
	return filter(mod.validate(set_path(view, o.parts, v), conn, c.id, set_path({}, o.parts, v)) ?? [],
	              (e) => e.field == o.field);
}

// One record per keyword, with where its probe goes and the field that validate() reports for it.
// An element under `items` is probed as the only element of its array, which validate() names
// `<path>[0]`. Anything nested below an element gets a record that check() refuses, rather than
// a probe that would miss it.
function bound_keywords(kws, parts, element, out) {
	for (let keyword, bound in kws) {
		let nesting = (keyword == "properties" || keyword == "items");
		if (keyword == "properties" && !element)
			for (let k, s in bound) bound_keywords(s, [ ...parts, k ], false, out);
		else if (keyword == "items" && !element)
			bound_keywords(bound, parts, true, out);
		else
			push(out, { field: join(".", parts) + (element ? "[0]" : ""), parts, element,
			            keyword: nesting ? "nested " + keyword : keyword, bound });
	}
	return out;
}

// The x-uapi-write keywords of a property and of what it nests, in the shape of the schema, so
// that bound_keywords() reads them as it reads an openapi_write_conditional.
function overlay_of(spec) {
	if (type(spec) != "object") return {};
	let km = { ...(spec["x-uapi-write"] ?? {}) };
	let p = {};
	for (let k, s in spec.properties ?? {}) {
		let child = overlay_of(s);
		if (length(child) > 0) p[k] = child;
	}
	if (length(p) > 0) km.properties = p;
	let items = overlay_of(spec.items);
	if (length(items) > 0) km.items = items;
	return km;
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
function check(mod, cases, o) {
	let p = probes(o.keyword, o.bound);
	if (p == null) {
		t.assert_equal(sprintf("no probe for %s %s", o.field, o.keyword), "a probe");
		return;
	}
	if (length(cases) == 0) {
		t.assert_equal(sprintf("no fixture case for %s", o.field), "a case");
		return;
	}
	for (let v in p.past) {
		let own = false;
		for (let c in cases) {
			let errs = errors_on(mod, c, o, v);
			if (length(errs) == 0)
				t.assert_equal(sprintf("%s accepted %s %J", c.id, o.field, v), "refused");
			for (let e in errs) if (e.code == p.code) own = true;
		}
		if (!own)
			t.assert_equal(sprintf("no case refuses %s %J with %s", o.field, v, p.code), "refused");
	}
	for (let v in p.at) {
		let passes = false;
		for (let c in cases)
			if (length(errors_on(mod, c, o, v)) == 0) passes = true;
		if (!passes)
			t.assert_equal(sprintf("no case accepts %s %J", o.field, v), "accepted");
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
			for (let o in bound_keywords(overlay_of(spec), [ field ], false, [])) {
				found++;
				t.it(sprintf("%s %s %s", f, o.field, o.keyword), () => check(mod, cases, o));
			}
		for (let cond in mod.openapi_write_conditional ?? []) {
			let matching = filter(cases, (c) => matches(mod, c, cond));
			for (let field, spec in cond.then?.properties ?? {})
				for (let o in bound_keywords(spec, [ field ], false, [])) {
					found++;
					t.it(sprintf("%s %s %s when %J", f, o.field, o.keyword, cond.if?.properties),
					     () => check(mod, matching, o));
				}
		}
	}
	t.it('finds keywords to check', () => t.assert_true(found > 0));
});
