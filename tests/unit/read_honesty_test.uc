let t = require('harness');
let ubus = require('bus');
let handler = require('handler');
let fs = require('fs');
let ph = require('property_harness');

// Read a resource, write the body straight back, read again: nothing may change and
// nothing may be rejected. That is the mechanical statement of an honest read, and it is
// the property an IaC client depends on, since every apply is a read-modify-write.
//
// Every full-replace defect this project has hit is a counterexample to it: `src_dip`
// dropped on a redirect round-trip (2.4.0), write-only secrets destroyed by a PUT that
// could not send them back (2.4.0), `ipaddr` discarded when `ipaddrs` travelled beside it
// and then the pair refused outright (2.4.1), `dns` written as the inverse of the request
// and `tag` typed as a string while returning arrays (2.5.0). Each was found by hand, one
// release at a time.
//
// It takes two forms, because they catch different defects. Writing the body back
// unmodified catches a read the write path cannot reproduce, which is how masked
// credentials were destroyed. Changing one field first catches a read whose fields are not
// independently writable, which is how the `ipaddr` / `ipaddrs` pair became unwritable:
// an unmodified body has the scalar agreeing with the list, so the contradiction only
// appears once the list moves and the previously-read scalar travels beside it. Verified
// by re-introducing both bugs: each form catches its own and not the other's.
//
// Every writable resource carries a case. The earlier version demanded them only from
// resources with a masked field or a merge hook, four of forty-three, which would not have
// demanded `dhcp/hosts` and so would not have caught the `tag` bug that shipped in the
// same release as the property itself.
//
// What none of it can cover: a uci option no resource models at all. PUT deliberately
// drops unmodelled options (uapi owns the section), so a view-level comparison cannot see
// the loss. That gap is curation completeness, checked against real configuration by
// tests/integration/44_stock_config_test.sh, and the read-honesty equivalent on hardware
// is tests/integration/47_read_honesty_test.sh.

function tx_stub() {
	return {
		acquire: function() { return {}; }, release: function() {},
		reload: function() { return null; }, check_services: function() { return null; },
		wg_apply: function() { return null; }, wg_reconcile: function() { return null; },
	};
}

function ctx() { return { request_id: "01hx0000000000000000000000" }; }

let fx = require('resource_fixtures');
const WG_KEY = fx.WG_KEY;
const WG_PUB = fx.WG_PUB;
let world = fx.world;
const CASES = fx.CASES;

function seeded(c) {
	let uci = world();
	if (uci[c.pkg] == null) uci[c.pkg] = {};
	let sec = { '.anonymous': false, ...c.section };
	uci[c.pkg][c.id] = sec;
	return ubus.stub({ uci: uci });
}

function read(h, c, conn) {
	return c.singleton ? h.get(conn, ctx()) : h.get_one(conn, ctx(), c.id);
}

// A singleton has no PUT (see handler.make_singleton), so its round trip is PATCH with the
// body it just served, which is the same shape 44_stock_config_test.sh uses.
function write(h, c, conn, body) {
	return c.singleton ? h.patch(conn, ctx(), body) : h.replace(conn, ctx(), c.id, body);
}

t.describe('property: a read written straight back changes nothing', () => {
	for (let c in CASES) {
		t.it(sprintf("%s/%s", c.file, c.id), () => {
			let mod = loadfile('src/resources/' + c.file)();
			let h = c.singleton ? handler.make_singleton(mod, { tx: tx_stub() })
			                    : handler.make(mod, { tx: tx_stub() });
			let conn = seeded(c);

			let first = read(h, c, conn);
			if (first.status != 200) {
				t.assert_equal(sprintf("GET failed, so the seed is wrong rather than the "
				                       + "resource: %J", first.body), "GET 200");
				return;
			}

			// The body a client would send back verbatim, runtime excluded because it is
			// live state rather than configuration and no client echoes it.
			let sent = { ...first.body };
			delete sent.runtime;

			let put = write(h, c, conn, sent);
			if (put.status != 200) {
				// Surface the reason rather than just the code: a bare 422 here costs
				// the next reader a debugging session.
				t.assert_equal(sprintf("write rejected the body it just served: %J", put.body),
				               "write accepted");
				return;
			}

			let second = read(h, c, conn);
			t.assert_equal(second.status, 200);
			for (let k in first.body) {
				if (k == "runtime") continue;
				if (!ph.json_eq(first.body[k], second.body[k]))
					t.assert_equal(sprintf("%s changed across a round trip: %J -> %J",
					                       k, first.body[k], second.body[k]),
					               "unchanged");
			}

			// The apply shape: change one field, leave the rest as read. A field that is
			// not independently writable shows up here and nowhere else.
			if (c.modify != null) {
				let changed = { ...second.body };
				delete changed.runtime;
				changed[c.modify.key] = c.modify.value;
				let put2 = write(h, c, conn, changed);
				if (put2.status != 200) {
					t.assert_equal(sprintf("write rejected a one-field change to %s: %J",
					                       c.modify.key, put2.body), "write accepted");
					return;
				}
				let third = read(h, c, conn);
				if (!ph.json_eq(third.body[c.modify.key], c.modify.value))
					t.assert_equal(sprintf("%s did not take: %J", c.modify.key,
					                       third.body[c.modify.key]),
					               sprintf("%J", c.modify.value));
			}
		});
	}
});

// A field whose read-back value equals its own declared default is invisible to the
// property above: drop it from toUci and the re-read synthesizes the default again, so
// before and after match and nothing is reported. Measured, not theorised: deleting
// `out.forward` from firewall.zones was invisible while the seed said `REJECT`, which is
// the documented default, and caught immediately once the seed said `DROP`.
//
// The first version of this check compared the SEED against the default, which looked
// equivalent and was not: seeds are keyed by uci option name and schema_properties by wire
// name, so every renamed field (`PasswordAuth` vs `password_auth`, and 20 others) failed
// the lookup and was skipped in silence. It inspected 15 of 140 seeded keys, and deleting
// the `PasswordAuth` write from dropbear.instances.uc -- which silently re-enables SSH
// password authentication across a GET-then-PUT -- passed the entire suite.
//
// Comparing the READ-BACK value needs no name mapping at all, because it asks the question
// the property actually depends on: if toUci dropped this field, would the re-read refill
// it and hide the loss? Any resource whose uci names differ from its wire names is covered
// for free.
t.describe('property: no case hides a field behind its own default', () => {
	for (let c in CASES) {
		t.it(sprintf("%s/%s reads back off-default for every defaulted field", c.file, c.id), () => {
			let mod = loadfile('src/resources/' + c.file)();
			let props = mod.schema_properties ?? {};
			let h = c.singleton ? handler.make_singleton(mod, { tx: tx_stub() })
			                    : handler.make(mod, { tx: tx_stub() });
			let conn = seeded(c);
			let got = read(h, c, conn);
			if (got.status != 200) {
				t.assert_equal(sprintf("GET failed, so the seed is wrong: %J", got.body),
				               "GET 200");
				return;
			}
			let blind = [];
			for (let k in props) {
				if (!exists(props[k], "default")) continue;
				if (ph.json_eq(got.body[k], props[k].default))
					push(blind, sprintf("%s=%J", k, props[k].default));
			}
			if (length(blind) > 0)
				t.assert_equal(sprintf("%s/%s reads back at the default for %s, so a "
				                       + "dropped write would be invisible",
				                       c.file, c.id, join(", ", blind)),
				               "every defaulted field seeded off its default");
		});
	}
});

// The case list must not fall behind the resource tree. Every resource with a validate()
// is writable and therefore has to round-trip; there is no exempt category any more.
t.describe('property: every writable resource has a round-trip case', () => {
	t.it('covers all of them', () => {
		let covered = {};
		for (let c in CASES) covered[c.file] = true;

		let missing = [];
		for (let name in fs.lsdir('src/resources')) {
			if (substr(name, length(name) - 3) != ".uc") continue;
			let src = fs.open('src/resources/' + name, 'r');
			let text = src.read('all');
			src.close();
			// No validate means a read-only collection (the lease views), nothing to write.
			if (index(text, "validate:") < 0) continue;
			if (!covered[name]) push(missing, name);
		}
		if (length(missing) > 0)
			t.assert_equal("resources with no round-trip case: " + join(", ", missing),
			               "all covered");
		t.assert_equal(length(missing), 0);
	});
});
