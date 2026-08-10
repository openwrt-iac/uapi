let t = require('harness');
let hosts = loadfile('src/resources/dhcp.hosts.uc')();

t.describe('dhcp.hosts contract', () => {
	t.it('declares package, type, and reload services', () => {
		t.assert_equal(hosts.package, "dhcp");
		t.assert_equal(hosts.type, "host");
		t.assert_deep_equal(hosts.reload, ["dnsmasq"]);
	});
});

t.describe('dhcp.hosts.fromUci', () => {
	t.it('renders a named section as managed', () => {
		let r = hosts.fromUci({
			'.name': 'h_01hx', '.anonymous': false, '.type': 'host',
			name: 'printer', mac: 'aa:bb:cc:dd:ee:ff', ip: '192.168.1.50',
		});
		t.assert_equal(r.id, 'h_01hx');
		t.assert_true(r.managed);
		t.assert_equal(r.name, 'printer');
		t.assert_deep_equal(r.macs, ['aa:bb:cc:dd:ee:ff']);
		t.assert_equal(r.ip, '192.168.1.50');
	});

	t.it('renders an anonymous section as unmanaged', () => {
		let r = hosts.fromUci({
			'.name': 'cfg00', '.anonymous': true, '.type': 'host',
			mac: 'aa:bb:cc:dd:ee:ff', ip: '10.0.0.5',
		});
		t.assert_false(r.managed);
	});

	t.it('normalizes dns to a boolean', () => {
		let on = hosts.fromUci({ '.name': 'h1', '.anonymous': false, '.type': 'host', dns: '1' });
		let off = hosts.fromUci({ '.name': 'h2', '.anonymous': false, '.type': 'host', dns: '0' });
		t.assert_true(on.dns);
		t.assert_false(off.dns);
	});
});

t.describe('dhcp.hosts.toUci', () => {
	t.it('emits the standard host options', () => {
		let u = hosts.toUci({
			name: 'router', macs: ['00:11:22:33:44:55'],
			ip: '192.168.1.1', leasetime: '12h', dns: true,
		});
		t.assert_equal(u.name, 'router');
		t.assert_equal(u.mac, '00:11:22:33:44:55');
		t.assert_equal(u.ip, '192.168.1.1');
		t.assert_equal(u.leasetime, '12h');
		t.assert_equal(u.dns, '1');
	});

	t.it('omits absent fields', () => {
		let u = hosts.toUci({ macs: ['00:11:22:33:44:55'], ip: '10.0.0.1' });
		t.assert_equal(u.leasetime, null);
		t.assert_equal(u.tag, null);
		t.assert_equal(u.dns, null);
	});
});

t.describe('dhcp.hosts.validate', () => {
	t.it('rejects an entry with neither mac nor duid (no identifier)', () => {
		let errs = hosts.validate({ ip: '10.0.0.1' }, null);
		let me = filter(errs, function(e) { return e.field == "macs" && e.code == "required"; });
		t.assert_equal(length(me), 1);
	});

	t.it('accepts a DNS-only entry: mac + name, no ip', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], name: 'host.lan' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects malformed mac', () => {
		let errs = hosts.validate({ macs: ['not-a-mac'], ip: '10.0.0.1' }, null);
		let me_errs = filter(errs, function(e) { return e.field == "macs[0]"; });
		t.assert_equal(me_errs[0].code, 'invalid_format');
	});

	t.it('accepts a valid MAC', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '10.0.0.1' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects malformed IPv4', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '999.0.0.1' }, null);
		let ip_errs = filter(errs, function(e) { return e.field == "ip"; });
		t.assert_equal(ip_errs[0].code, 'invalid_format');
	});

	t.it('accepts an IPv6 address', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], ip: 'fd00::1' }, null);
		t.assert_equal(length(errs), 0);
	});

	t.it('rejects bad leasetime', () => {
		let errs = hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '10.0.0.1', leasetime: 'forever' }, null);
		let le = filter(errs, function(e) { return e.field == "leasetime"; });
		t.assert_equal(le[0].code, 'invalid_format');
	});

	t.it('accepts valid leasetime formats', () => {
		t.assert_equal(length(hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '10.0.0.1', leasetime: '12h' }, null)), 0);
		t.assert_equal(length(hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '10.0.0.1', leasetime: '1d' }, null)), 0);
		t.assert_equal(length(hosts.validate({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '10.0.0.1', leasetime: '3600' }, null)), 0);
	});
});

let ubus = require('bus');


// name, tag and dns were written by toUci but absent from schema_properties, so the
// central type gate never saw them: `dns: "0"` was a truthy string in ucode and wrote
// dns=1, the inverse of the request. These assert the gate now covers them.
t.describe('dhcp.hosts central type gate covers name, tag and dns', () => {
	let handler = require('handler');
	function types(body) { return handler.check_schema_types(hosts.schema_properties, body); }
	function has(errs, field, code) {
		for (let e in errs) if (e.field == field && e.code == code) return true;
		return false;
	}

	// The inverted write: a string "0" asked for dns off and got dns=1.
	t.it('rejects a stringly-typed dns instead of coercing it', () => {
		t.assert_true(has(types({ dns: "0" }), "dns", "invalid_type"));
	});

	t.it('still accepts a real boolean dns', () => {
		t.assert_equal(length(types({ dns: false })), 0);
		t.assert_equal(length(types({ dns: true })), 0);
	});

	t.it('rejects a non-string name', () => {
		t.assert_true(has(types({ name: 123 }), "name", "invalid_type"));
	});

	t.it('accepts the null and string forms name declares', () => {
		t.assert_equal(length(types({ name: "host.lan" })), 0);
		t.assert_equal(length(types({ name: null })), 0);
	});

	// `tag` keeps the union on the request side only: the 2.4.1 spec declared a
	// string, so clients generated against it send one, and dnsmasq word-splits a
	// scalar identically. Responses are always an array (see the round-trip test
	// below); v3 removes the write form.
	t.it('accepts both shapes a client may send, and null', () => {
		t.assert_equal(length(types({ tag: ["a", "b"] })), 0);
		t.assert_equal(length(types({ tag: "a b" })), 0);
		t.assert_equal(length(types({ tag: null })), 0);
	});

	// Undeclared meant unchecked, and unchecked meant an object reached toUci and
	// was handed to uci as an option value.
	t.it('rejects shapes uci cannot hold', () => {
		t.assert_true(has(types({ tag: 123 }), "tag", "invalid_type"));
		t.assert_true(has(types({ tag: { a: 1 } }), "tag", "invalid_type"));
	});

	t.it('rejects a non-string inside the list', () => {
		t.assert_true(has(types({ tag: ["ok", 7] }), "tag[1]", "invalid_type"));
	});
});

// Writes persist the shape they were given. Normalizing a scalar into a list would
// make a body written back unchanged come back changed, which is the one thing the
// read-honesty property forbids; v3 reconciles the shapes on the read side instead.
t.describe('dhcp.hosts tag write shape', () => {
	t.it('keeps an array an array, so uci gets a list', () => {
		let u = hosts.toUci({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '10.0.0.1',
		                      tag: ['guest', 'iot'] });
		t.assert_equal(type(u.tag), 'array');
		t.assert_equal(u.tag[0], 'guest');
		t.assert_equal(u.tag[1], 'iot');
	});

	t.it('keeps a scalar a scalar, so a verbatim round trip does not rewrite it', () => {
		let u = hosts.toUci({ macs: ['aa:bb:cc:dd:ee:ff'], ip: '10.0.0.1',
		                      tag: 'guest iot' });
		t.assert_equal(type(u.tag), 'string');
		t.assert_equal(u.tag, 'guest iot');
	});
});


// A reservation storing `option tag 'a b'` used to read back as the string "a b" while an
// identical one storing `list tag` read back as ["a","b"]. Same configuration to dnsmasq,
// two shapes on the wire, and a generated client had to handle both to learn one thing.
// The read is settled on the array. A read never touches storage; a write does converge
// it, which the block below covers.
t.describe('dhcp.hosts tag always reads as an array', () => {
	function view(v) {
		let sec = { '.name': 'ht', '.type': 'host', mac: '00:11:22:33:44:55' };
		if (v != null) sec.tag = v;
		return hosts.fromUci(sec, null);
	}
	t.it('a stored scalar is split the way dnsmasq splits it', () => {
		t.assert_deep_equal(view('a b').tag, ['a', 'b']);
		t.assert_deep_equal(view('  a   b  ').tag, ['a', 'b']);
	});
	t.it('a single tag is still an array', () => {
		t.assert_deep_equal(view('guest').tag, ['guest']);
	});
	t.it('a stored list is unchanged', () => {
		t.assert_deep_equal(view(['x', 'y']).tag, ['x', 'y']);
	});
	t.it('absent stays null, not an empty array', () => {
		t.assert_equal(view(null).tag, null);
	});
	// The view has to survive a round trip even though the storage shape changes: read a
	// scalar, write the array back, read again, and the client sees what it sent.
	t.it('a scalar-stored reservation round-trips at the view level', () => {
		let first = view('a b');
		let second = hosts.fromUci({ '.name': 'ht', '.type': 'host',
		                             ...hosts.toUci(first) }, null);
		t.assert_deep_equal(second.tag, first.tag);
	});
	t.it('a string is still accepted on write, for 2.4.1-era clients', () => {
		t.assert_equal(hosts.toUci({ tag: 'a b' }).tag, 'a b');
	});
});

// Writing the array back converges the storage shape, which is intentional and is the
// half the original design balked at. It is safe because it is invisible on the wire:
// dnsmasq compiles `option tag 'a b'` and `list tag` identically, and the view is stable.
t.describe('dhcp.hosts tag storage converges on write, invisibly', () => {
	t.it('toUci emits the array, which uci stores as a list', () => {
		t.assert_deep_equal(hosts.toUci({ tag: ['guest', 'iot'] }).tag, ['guest', 'iot']);
	});
	t.it('the view is identical before and after that conversion', () => {
		let scalar = hosts.fromUci({ '.name': 'h', '.type': 'host',
		                             mac: '00:11:22:33:44:55', tag: 'guest iot' }, null);
		let listed = hosts.fromUci({ '.name': 'h', '.type': 'host',
		                             mac: '00:11:22:33:44:55', tag: ['guest', 'iot'] }, null);
		t.assert_deep_equal(scalar.tag, listed.tag);
	});
});
