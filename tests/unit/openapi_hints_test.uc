let t = require('harness');
let hints = require('openapi_hints');

t.describe('openapi_hints fragments', () => {
	t.it('match_requires_src_zone has the if/then shape consumers expect', () => {
		let frag = hints.match_requires_src_zone;
		t.assert_deep_equal(frag.if, { type: "object", required: ["match"] });
		t.assert_equal(frag.then.properties.match.type, "object");
		t.assert_deep_equal(frag.then.properties.match.required, ["src_zone"]);
	});
});
