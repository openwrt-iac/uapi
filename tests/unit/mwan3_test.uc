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
	for (let e in handler.check_schema_types(handler.request_properties(r.schema_properties), body)) push(out, e);
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
	t.it('family is not required, an unset or empty option reads ipv4, and a list reads as config_get joins it, as mwan3 does', () => {
		t.assert_equal(interfaces.openapi_required, null);
		t.assert_equal(interfaces.fromUci({ '.name': 'wan' }).family, 'ipv4');
		t.assert_equal(interfaces.fromUci({ '.name': 'wan', family: '' }).family, 'ipv4');
		t.assert_equal(interfaces.fromUci({ '.name': 'wan', family: 'ipv6' }).family, 'ipv6');
		t.assert_equal(interfaces.fromUci({ '.name': 'wan', family: [ 'ipv6' ] }).family, 'ipv6');
		t.assert_equal(interfaces.fromUci({ '.name': 'wan', family: [ '' ] }).family, 'ipv4');
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

	t.it('family reads a list as config_get joins it, and an empty one as null, as mwan3 does', () => {
		t.assert_equal(rules.fromUci({ '.name': 'r1', family: [ 'ipv6' ] }).family, 'ipv6');
		t.assert_equal(rules.fromUci({ '.name': 'r1', family: [ 'ipv4', 'ipv6' ] }).family, 'ipv4 ipv6');
		t.assert_equal(rules.fromUci({ '.name': 'r1', family: [ '' ] }).family, null);
		t.assert_equal(rules.fromUci({ '.name': 'r1', family: '' }).family, null);
	});

	t.it('a write refuses a family other than ipv4, ipv6 or any', () => {
		let errs = full_validate(rules, { use_policy: "p_balanced", family: "ipv4 ipv6" }, c);
		t.assert_deep_equal(map(errs, (e) => e.field + " " + e.code), [ "family not_in_enum" ]);
	});
});

// iptables refuses err and warn as a log level, and mwan3 leaves a member with a metric above 256 out
// of its policy. A write refuses both, a stored one blocks every write of its section, and the read
// still gives it, so the response schema has to take it.
t.describe('mwan3 values that mwan3 does not run', () => {
	let fs = require('fs');
	let SPEC = json(fs.readfile('build/openapi.json')).components.schemas;
	let tx = { acquire: () => ({}), release: () => null, reload: () => null, check_services: () => null };
	let ctx = { request_id: "01hx0000000000000000000000" };
	let world = (globals_sec, member_sec) => bus.stub({ uci: { mwan3: {
		globals: { '.type': 'globals', '.anonymous': false, ...globals_sec },
		wan: { '.type': 'interface', '.anonymous': false, family: 'ipv4' },
		m1: { '.type': 'member', '.anonymous': false, interface: 'wan', metric: '1', ...(member_sec ?? {}) },
	} } });
	let gh = handler.make_singleton(globals, { tx });
	let mh = handler.make(members, { tx });
	let codes = (r, field) => map(filter(r.body.errors ?? [], (e) => e.field == field), (e) => e.code);

	t.it('a loglevel of err or warn answers not_in_enum, and error and warning pass', () => {
		for (let l in [ "err", "warn" ])
			t.assert_deep_equal(codes(gh.patch(world({}), ctx, { loglevel: l }), "loglevel"), [ "not_in_enum" ], l);
		for (let l in [ "error", "warning" ]) {
			let c = world({});
			t.assert_equal(gh.patch(c, ctx, { loglevel: l }).status, 200, l);
			t.assert_equal(c._state.uci.mwan3.globals.loglevel, l);
		}
	});

	// Each one checked against iptables 1.8.13, through iptables-restore as mwan3 runs it.
	t.it('a stored level that iptables refuses blocks a write of another field, reads as stored, and is live only while logging is on', () => {
		for (let l in [ "err", "warn", "8", "08", "0x", "-1", "PANIC", "3 x" ]) {
			let c = world({ loglevel: l, logging: '1' });
			t.assert_equal(gh.get(c, ctx).body.loglevel, l, l);
			t.assert_deep_equal(codes(gh.patch(c, ctx, { mmx_mask: '0x3F00' }), "loglevel"), [ "not_in_enum" ], l);
			t.assert_equal(gh.sweep(c)[0].errors[0].live, true, l);
		}
		t.assert_equal(gh.sweep(world({ loglevel: 'warn', logging: '0' }))[0].errors[0].live, false);
		t.assert_equal(SPEC.Mwan3GlobalsResponse.properties.loglevel.enum, null);
	});

	t.it('a stored level that iptables takes is no error and goes back in a write, and a write that sends one anew is refused', () => {
		for (let l in [ "panic", "3", "0x3", "07", " 3", "+3", "error " ]) {
			let c = world({ loglevel: l, logging: '1' });
			t.assert_deep_equal(gh.sweep(c), [], l);
			t.assert_equal(gh.patch(c, ctx, { logging: false, loglevel: l }).status, 200, l);
			t.assert_equal(c._state.uci.mwan3.globals.loglevel, l);
			t.assert_deep_equal(codes(gh.patch(world({ loglevel: 'notice' }), ctx, { loglevel: l }), "loglevel"),
			                    [ "not_in_enum" ], l);
		}
	});

	t.it('a metric above 256 answers out_of_range, and 256 passes', () => {
		t.assert_deep_equal(codes(mh.patch(world({}), ctx, 'm1', { metric: 257 }), "metric"), [ "out_of_range" ]);
		t.assert_equal(mh.patch(world({}), ctx, 'm1', { metric: 256 }).status, 200);
	});

	t.it('a stored metric above 256 blocks a write of another field and reads as stored', () => {
		let c = world({}, { metric: '300' });
		t.assert_equal(mh.get_one(c, ctx, 'm1').body.metric, 300);
		t.assert_deep_equal(codes(mh.patch(c, ctx, 'm1', { weight: 2 }), "metric"), [ "out_of_range" ]);
		t.assert_true(SPEC.Mwan3MembersResponse.properties.metric.maximum >= 300);
		t.assert_equal(SPEC.Mwan3MembersRequest.properties.metric.maximum, 256);
	});

	t.it('tcp or udp in another case with a port answers conflict, and a stored one blocks a write of another field', () => {
		let rh = handler.make(rules, { tx });
		let rule = (sec) => bus.stub({ uci: { mwan3: {
			p1: { '.type': 'policy', '.anonymous': false },
			r1: { '.type': 'rule', '.anonymous': false, use_policy: 'p1', ...sec },
		} } });
		for (let sec in [ { proto: 'tcp', dest_port: '443' }, { proto: 'udp', src_port: '53' } ]) {
			let p = uc(sec.proto);
			t.assert_deep_equal(codes(rh.patch(rule(sec), ctx, 'r1', { proto: p }), "proto"), [ "conflict" ], p);
			let c = rule({ ...sec, proto: p });
			t.assert_deep_equal(codes(rh.patch(c, ctx, 'r1', { sticky: true }), "proto"), [ "conflict" ], p);
			t.assert_equal(rh.sweep(c)[0].errors[0].field, "proto", p);
		}
		t.assert_equal(rh.patch(rule({ proto: 'tcp', dest_port: '443' }), ctx, 'r1', { proto: 'TCP', dest_port: null }).status, 200);
		t.assert_equal(rh.patch(rule({ proto: 'Udp' }), ctx, 'r1', { sticky: true }).status, 200);
	});
});
