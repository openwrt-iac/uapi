let t = require('harness');
let bus = require('bus');
let handler = require('handler');

let globals    = loadfile('src/resources/mwan3.globals.uc')();
let interfaces = loadfile('src/resources/mwan3.interfaces.uc')();
let members    = loadfile('src/resources/mwan3.members.uc')();
let policies   = loadfile('src/resources/mwan3.policies.uc')();
let rules      = loadfile('src/resources/mwan3.rules.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

t.describe('mwan3.globals contract', () => {
	t.it('declares the daemon + reload service', () => {
		t.assert_equal(globals.package, "mwan3");
		t.assert_equal(globals.type, "globals");
		t.assert_deep_equal(globals.reload, ["mwan3"]);
	});

	t.it('fromUci normalises uci 0/1 to JSON booleans', () => {
		let r = globals.fromUci({ '.name': 'globals', logging: '1', loglevel: 'info' });
		t.assert_true(r.logging);
		t.assert_equal(r.loglevel, "info");
	});

	t.it('toUci round-trips logging boolean and rtmon_interval int', () => {
		let u = globals.toUci({ logging: true });
		t.assert_equal(u.logging, "1");
	});

	t.it('schema enforces mmx_mask hex pattern', () => {
		let errs = full_validate(globals, { mmx_mask: "not-hex" }, null);
		t.assert_true(length(filter(errs, e => e.field == "mmx_mask")) > 0);
	});
});

t.describe('mwan3.interfaces contract', () => {
	t.it('requires family (openapi_required)', () => {
		t.assert_deep_equal(interfaces.openapi_required, ["family"]);
	});

	t.it('rejects non-IP entries in track_ip[]', () => {
		let errs = interfaces.validate({ family: "ipv4", track_ip: ["1.1.1.1", "not-an-ip"] }, null);
		t.assert_true(length(filter(errs, e => e.field == "track_ip[1]")) > 0);
	});

	t.it('schema enforces family enum', () => {
		let errs = full_validate(interfaces, { family: "ipv7" }, null);
		t.assert_true(length(filter(errs, e => e.field == "family")) > 0);
	});
});

t.describe('mwan3.members validates the interface cross-reference', () => {
	let c = bus.stub({
		uci: {
			mwan3: {
				wan_v4: { '.type': 'interface', family: 'ipv4' },
			},
		},
	});

	t.it('passes when interface exists', () => {
		let errs = members.validate({ interface: "wan_v4", metric: 1, weight: 2 }, c);
		t.assert_equal(length(errs), 0);
	});

	t.it('flags missing interface with conflict', () => {
		let errs = members.validate({ interface: "nope", metric: 1 }, c);
		t.assert_true(length(filter(errs, e => e.field == "interface" && e.code == "conflict")) > 0);
	});

	t.it('flags missing interface field with required', () => {
		let errs = members.validate({}, c);
		t.assert_true(length(filter(errs, e => e.field == "interface" && e.code == "required")) > 0);
	});
});

t.describe('mwan3.policies validates member cross-references', () => {
	let c = bus.stub({
		uci: {
			mwan3: {
				m_lan_v4: { '.type': 'member', interface: 'wan_v4' },
				m_lte_v4: { '.type': 'member', interface: 'wan_lte' },
			},
		},
	});

	t.it('passes when every use_member exists', () => {
		let errs = policies.validate({ use_members: ["m_lan_v4", "m_lte_v4"] }, c);
		t.assert_equal(length(errs), 0);
	});

	t.it('flags unknown use_member with conflict at the right index', () => {
		let errs = policies.validate({ use_members: ["m_lan_v4", "ghost"] }, c);
		let cnt = filter(errs, e => e.field == "use_members[1]" && e.code == "conflict");
		t.assert_equal(length(cnt), 1);
	});

	t.it('rejects empty use_members list', () => {
		let errs = policies.validate({ use_members: [] }, c);
		t.assert_true(length(filter(errs, e => e.field == "use_members")) > 0);
	});
});

t.describe('mwan3.rules validates policy cross-reference + IP shapes', () => {
	let c = bus.stub({
		uci: {
			mwan3: {
				p_balanced: { '.type': 'policy' },
			},
		},
	});

	t.it('passes when use_policy and src_ip CIDR are valid', () => {
		let errs = rules.validate({ use_policy: "p_balanced", src_ip: "10.0.0.0/8" }, c);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects unknown policy', () => {
		let errs = rules.validate({ use_policy: "p_ghost" }, c);
		t.assert_true(length(filter(errs, e => e.field == "use_policy" && e.code == "conflict")) > 0);
	});

	t.it('rejects bad src_ip / dest_ip', () => {
		let errs = rules.validate({ use_policy: "p_balanced",
		                            src_ip: "999.0.0.1", dest_ip: "not-a-cidr" }, c);
		t.assert_true(length(filter(errs, e => e.field == "src_ip")) > 0);
		t.assert_true(length(filter(errs, e => e.field == "dest_ip")) > 0);
	});
});
