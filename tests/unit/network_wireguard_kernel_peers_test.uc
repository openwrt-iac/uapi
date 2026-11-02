let t = require('harness');
let ids = require('ids');
let wkp = loadfile('src/resources/network.wireguard_kernel_peers.uc')();

t.describe('network.wireguard_kernel_peers contract', () => {
	t.it('declares package, type, id_field, read-only shape', () => {
		t.assert_equal(wkp.package, "network");
		t.assert_equal(wkp.type, "wireguard_kernel_peer");
		t.assert_equal(wkp.id_field, "id");
		t.assert_equal(wkp.toUci, null);
		t.assert_equal(wkp.validate, null);
	});
	t.it('gives every field of the kernel dump beside the stable id', () => {
		t.assert_deep_equal(keys(wkp.schema_properties),
		                    [ "id", "interface", "public_key", "endpoint", "allowed_ips",
		                      "persistent_keepalive", "latest_handshake", "rx_bytes", "tx_bytes" ]);
	});
	t.it('declares the id pattern that ids.content_id derives', () => {
		let made = ids.content_id("wg1 QDOrIy8Zr31CrRFTGiUoVO0Ib3qSChv5U6gCqjiDrB4=");
		t.assert_true(match(made, regexp(wkp.schema_properties.id.pattern)), made);
	});
});
