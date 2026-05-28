let t = require('harness');
let bus = require('bus');
let handler = require('handler');
let leases_mod = loadfile('src/resources/dhcp.leases.uc')();
let leases = handler.make_collection(leases_mod);

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

const SAMPLE =
	"1735689600 aa:bb:cc:dd:ee:01 192.168.1.50 printer 01:aa:bb:cc:dd:ee:01\n" +
	"1735689700 aa:bb:cc:dd:ee:02 192.168.1.51 * *\n" +
	"\n" +
	"1735689800 aa:bb:cc:dd:ee:03 192.168.1.52 phone\n";

t.describe('dhcp.leases parser', () => {
	t.it('parses a typical leases file', () => {
		let out = leases_mod.parse_leases(SAMPLE);
		t.assert_equal(length(out), 3);
		t.assert_equal(out[0].expires_at, 1735689600);
		t.assert_equal(out[0].mac, "aa:bb:cc:dd:ee:01");
		t.assert_equal(out[0].ip, "192.168.1.50");
		t.assert_equal(out[0].hostname, "printer");
		t.assert_equal(out[0].duid, "01:aa:bb:cc:dd:ee:01");
	});

	t.it('treats "*" hostname as null', () => {
		let out = leases_mod.parse_leases(SAMPLE);
		t.assert_equal(out[1].hostname, null);
	});

	t.it('handles missing duid as null', () => {
		let out = leases_mod.parse_leases(SAMPLE);
		t.assert_equal(out[2].duid, null);
	});

	t.it('skips blank lines', () => {
		t.assert_equal(length(leases_mod.parse_leases("\n\n  \n")), 0);
	});

	t.it('skips malformed lines (fewer than 4 fields)', () => {
		t.assert_equal(length(leases_mod.parse_leases("123 ab:cd")), 0);
	});

	t.it('handles non-string input safely', () => {
		t.assert_deep_equal(leases_mod.parse_leases(null), []);
		t.assert_deep_equal(leases_mod.parse_leases(42), []);
	});
});

t.describe('handler.make_collection, list', () => {
	function fixture(items) {
		let mod = {
			package: "dhcp", type: "lease", id_field: "mac",
			list_fn: function() { return items; },
		};
		return handler.make_collection(mod);
	}

	t.it('list returns 200 with the items', () => {
		let h = fixture([{ mac: "aa", ip: "1.1.1.1" }]);
		let r = h.list(bus.stub(), ctx(), {});
		t.assert_equal(r.status, 200);
		t.assert_equal(length(r.body), 1);
		t.assert_equal(r.body[0].mac, "aa");
	});

	t.it('list returns empty array when source is empty', () => {
		let h = fixture([]);
		let r = h.list(bus.stub(), ctx(), {});
		t.assert_deep_equal(r.body, []);
	});
});

t.describe('handler.make_collection, get_one', () => {
	function fixture(items, id_field) {
		let mod = {
			package: "dhcp", type: "lease", id_field: id_field,
			list_fn: function() { return items; },
		};
		return handler.make_collection(mod);
	}

	t.it('returns the matching item by id_field', () => {
		let h = fixture([{ mac: "aa", ip: "1" }, { mac: "bb", ip: "2" }], "mac");
		let r = h.get_one(bus.stub(), ctx(), "bb");
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.ip, "2");
	});

	t.it('returns 404 for unknown id', () => {
		let h = fixture([{ mac: "aa" }], "mac");
		let r = h.get_one(bus.stub(), ctx(), "zz");
		t.assert_equal(r.status, 404);
	});

	t.it('returns 405 when resource has no id_field', () => {
		let h = fixture([{ x: 1 }], null);
		let r = h.get_one(bus.stub(), ctx(), "anything");
		t.assert_equal(r.status, 405);
	});
});

t.describe('handler.make_collection, write methods all return 405', () => {
	let h = handler.make_collection({
		package: "dhcp", type: "lease", id_field: "mac",
		list_fn: function() { return []; },
	});
	let c = bus.stub();

	t.it('create returns 405', () => {
		t.assert_equal(h.create(c, ctx(), {}).status, 405);
	});
	t.it('replace returns 405', () => {
		t.assert_equal(h.replace(c, ctx(), "x", {}).status, 405);
	});
	t.it('patch returns 405', () => {
		t.assert_equal(h.patch(c, ctx(), "x", {}).status, 405);
	});
	t.it('remove returns 405', () => {
		t.assert_equal(h.remove(c, ctx(), "x").status, 405);
	});
	t.it('adopt returns 405', () => {
		t.assert_equal(h.adopt(c, ctx(), "x").status, 405);
	});
});
