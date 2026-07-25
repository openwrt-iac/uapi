let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let nat = loadfile('src/resources/firewall.nat.uc')();

function full_validate(r, body, conn) {
	let out = [];
	for (let e in handler.check_schema_types(r.schema_properties, body)) push(out, e);
	for (let e in r.validate(body, conn)) push(out, e);
	return out;
}

t.describe('firewall.nat contract', () => {
	t.it('declares package, type, and reload services', () => {
		t.assert_equal(nat.package, "firewall");
		t.assert_equal(nat.type, "nat");
		t.assert_deep_equal(nat.reload, ["firewall"]);
	});
});

t.describe('firewall.nat.fromUci', () => {
	t.it('defaults target to MASQUERADE', () => {
		let r = nat.fromUci({ '.name': 'n1', '.anonymous': false, '.type': 'nat' });
		t.assert_equal(r.target, 'MASQUERADE');
	});

	// fw4 treats an absent family on a nat section as IPv4-only for backwards
	// compatibility, so synthesizing "any" here would misreport the box.
	t.it('leaves family null when absent rather than defaulting to any', () => {
		let r = nat.fromUci({ '.name': 'n1', '.anonymous': false, '.type': 'nat' });
		t.assert_equal(r.match.family, null);
	});

	t.it('maps src to the outbound zone and keeps scalar options scalar', () => {
		let r = nat.fromUci({
			'.name': 'n1', '.anonymous': false, '.type': 'nat',
			src: 'wan', device: 'eth0', proto: 'tcp', src_port: '1024-65535',
		});
		t.assert_equal(r.match.src_zone, 'wan');
		t.assert_equal(r.match.device, 'eth0');
		t.assert_deep_equal(r.match.proto, ['tcp']);
		t.assert_equal(r.match.src_port, '1024-65535');
	});
});

// fw4's `config nat` marks only `proto` PARSE_LIST; src_ip, src_port, dest_ip
// and dest_port are scalars, and parse_opt returns NaN on a list ("option must
// not be a list"), which makes fw4 discard the entire section. Emitting uci
// lists here would be a silent no-op on every NAT rule that matches on an
// address or port.
t.describe('firewall.nat uci arity', () => {
	t.it('never emits a uci list for a scalar-typed option', () => {
		let u = nat.toUci({
			target: 'MASQUERADE',
			match: { src_ip: '10.0.0.0/8', src_port: '80',
			         dest_ip: '192.0.2.1', dest_port: '443', proto: ['tcp'] },
		});
		for (let k in ['src_ip', 'src_port', 'dest_ip', 'dest_port'])
			t.assert_false(type(u[k]) == "array");
		t.assert_deep_equal(u.proto, ['tcp']);
	});
});

t.describe('firewall.nat round-trip', () => {
	t.it('fromUci then toUci recovers the canonical uci shape', () => {
		let section = {
			'.name': 'n_01hx', '.anonymous': false, '.type': 'nat',
			name: 'snat-out', target: 'SNAT', enabled: '1',
			src: 'wan', snat_ip: '203.0.113.5', proto: ['tcp'],
			dest_ip: '198.51.100.10', mark: '0x1', family: 'ipv4',
		};
		let u = nat.toUci(nat.fromUci(section));
		t.assert_equal(u.target, 'SNAT');
		t.assert_equal(u.src, 'wan');
		t.assert_equal(u.snat_ip, '203.0.113.5');
		t.assert_equal(u.mark, '0x1');
		t.assert_equal(u.family, 'ipv4');
		t.assert_equal(u.dest_ip, '198.51.100.10');
	});

	t.it('omits family entirely when null', () => {
		let u = nat.toUci(nat.fromUci({ '.name': 'n1', '.anonymous': false, '.type': 'nat' }));
		t.assert_equal(u.family, null);
	});
});

t.describe('firewall.nat.validate', () => {
	t.it('rejects body that is not an object', () => {
		let errs = nat.validate(null, null);
		t.assert_equal(length(errs), 1);
		t.assert_equal(errs[0].code, "invalid_type");
	});

	// fw4 discards a SNAT section carrying neither, so accepting it would be a
	// silent no-op.
	t.it('requires snat_ip or snat_port when target is SNAT', () => {
		let errs = nat.validate({ target: 'SNAT', match: { src_zone: 'wan' } }, null);
		let e = filter(errs, function(x) { return x.field == "snat_ip"; });
		t.assert_equal(e[0].code, "required");
	});

	t.it('accepts SNAT with either snat_ip or snat_port alone', () => {
		for (let body in [{ target: 'SNAT', snat_ip: '203.0.113.5' },
		                  { target: 'SNAT', snat_port: '1024-2048' }]) {
			body.match = { src_zone: 'wan' };
			t.assert_equal(length(nat.validate(body, null)), 0);
		}
	});

	t.it('rejects snat_ip or snat_port on a non-SNAT target', () => {
		for (let f in ['snat_ip', 'snat_port']) {
			let body = { target: 'MASQUERADE', match: { src_zone: 'wan' } };
			body[f] = (f == 'snat_ip') ? '203.0.113.5' : '1024';
			let e = filter(nat.validate(body, null), function(x) { return x.field == f; });
			t.assert_equal(e[0].code, "conflict");
		}
	});

	t.it('rejects a negated snat_ip', () => {
		let errs = nat.validate({ target: 'SNAT', snat_ip: '!203.0.113.5', match: {} }, null);
		let e = filter(errs, function(x) { return x.field == "snat_ip"; });
		t.assert_equal(e[0].code, "invalid_format");
	});

	// fw4 types these as networks, resolving an address, a prefix in either
	// family, or a uci network name. Validating them as bare IPv4 rejected
	// ordinary NAT configurations the router accepts.
	t.it('accepts every address form fw4 resolves', () => {
		for (let v in ['203.0.113.5', '203.0.113.0/24', '2001:db8::1', 'lan']) {
			let errs = nat.validate({ target: 'SNAT', snat_ip: v, match: {} }, null);
			t.assert_equal(length(errs), 0);
		}
		for (let v in ['10.0.0.0/8', '2001:db8::/32', '!10.0.0.1', 'lan']) {
			let errs = nat.validate(
				{ target: 'MASQUERADE', match: { dest_ip: v, src_ip: v } }, null);
			t.assert_equal(length(errs), 0);
		}
	});

	// fw4 rewrites a wildcard proto to tcp+udp when ports are present, so only
	// an explicitly non-TCP/UDP proto conflicts.
	t.it('rejects ports on a non-TCP/UDP protocol but allows the wildcard', () => {
		let bad = nat.validate(
			{ target: 'MASQUERADE', match: { src_zone: 'wan', proto: ['icmp'], src_port: '80' } }, null);
		t.assert_equal(filter(bad, function(x) { return x.field == "match.proto"; })[0].code, "conflict");

		let ok = nat.validate(
			{ target: 'MASQUERADE', match: { src_zone: 'wan', proto: ['all'], src_port: '80' } }, null);
		t.assert_equal(length(ok), 0);
	});

	// fw4 parses a port as N or a min-max/min:max range within 0..65535, and
	// negates match ports but not snat_port. A value outside that is a section
	// fw4 discards, so uapi must reject it rather than pass it through.
	t.it('accepts every port form fw4 parses', () => {
		for (let v in ['80', '1000-2000', '1000:2000', '!80', '65535']) {
			let errs = nat.validate(
				{ target: 'MASQUERADE', match: { proto: ['tcp'], src_port: v } }, null);
			t.assert_equal(length(errs), 0);
		}
		let snat = nat.validate({ target: 'SNAT', snat_port: '1000:2000', match: { proto: ['tcp'] } }, null);
		t.assert_equal(length(snat), 0);
	});

	t.it('rejects ports fw4 would discard', () => {
		for (let v in ['65536', '99999', '2000-1000']) {
			let errs = nat.validate(
				{ target: 'MASQUERADE', match: { proto: ['tcp'], src_port: v } }, null);
			let e = filter(errs, function(x) { return x.field == "match.src_port"; });
			t.assert_equal(e[0].code, "out_of_range");
		}
	});

	t.it('rejects a negated snat_port, which fw4 marks NO_INVERT', () => {
		let errs = nat.validate({ target: 'SNAT', snat_port: '!80', match: { proto: ['tcp'] } }, null);
		t.assert_equal(filter(errs, function(x) { return x.field == "snat_port"; })[0].code, "invalid_format");
	});

	t.it('rejects a mark past the 32-bit ceiling', () => {
		let errs = nat.validate({ target: 'MASQUERADE', match: { mark: '4294967296' } }, null);
		t.assert_equal(filter(errs, function(x) { return x.field == "match.mark"; })[0].code, "out_of_range");
	});

	t.it('rejects unknown target and family via the schema enums', () => {
		let errs = full_validate(nat, { target: 'DNAT', match: { family: 'ipxx' } }, null);
		t.assert_equal(filter(errs, function(x) { return x.field == "target"; })[0].code, "not_in_enum");
		t.assert_equal(filter(errs, function(x) { return x.field == "match.family"; })[0].code, "not_in_enum");
	});

	// A nat section without a source zone lands in the base srcnat chain and
	// matches all egress, so it must not be rejected.
	t.it('accepts a missing source zone', () => {
		t.assert_equal(length(nat.validate({ target: 'MASQUERADE', match: {} }, null)), 0);
	});

	t.it('reports a nonexistent source zone', () => {
		let conn = ubus.stub({ uci: { firewall: { z_lan: { '.type': 'zone', name: 'lan' } } } });
		let errs = nat.validate({ target: 'MASQUERADE', match: { src_zone: 'nope' } }, conn);
		t.assert_equal(filter(errs, function(x) { return x.field == "match.src_zone"; })[0].code, "conflict");
		t.assert_equal(length(nat.validate({ target: 'MASQUERADE', match: { src_zone: 'lan' } }, conn)), 0);
	});
});
