let t = require('harness');
let handler = require('handler');
let system = loadfile('src/resources/system.uc')();
let ifaces = loadfile('src/resources/network.interfaces.uc')();
let fw = loadfile('src/resources/firewall.rules.uc')();

function field_code(spec, body, field) {
	for (let e in handler.check_schema_types(spec, body))
		if (e.field == field) return e.code;
	return null;
}

t.describe('newline and CR refusal in curated strings (#276)', () => {
	t.it('refuses a newline and a carriage return in a plain string field', () => {
		t.assert_equal(field_code(ifaces.schema_properties, { hostname: 'a\nb' }, 'hostname'), 'invalid_format');
		t.assert_equal(field_code(ifaces.schema_properties, { hostname: 'a\rb' }, 'hostname'), 'invalid_format');
		t.assert_equal(field_code(ifaces.schema_properties, { hostname: 'ab' }, 'hostname'), null);
	});

	t.it('refuses them in nested objects and array items', () => {
		t.assert_equal(field_code(fw.schema_properties, { match: { src_zone: 'a\nb' } }, 'match.src_zone'), 'invalid_format');
		t.assert_equal(field_code(ifaces.schema_properties, { dns: ['1.1.1.1', 'a\rb'] }, 'dns[1]'), 'invalid_format');
	});

	t.it('system.notes opts out with x-uapi-multiline', () => {
		t.assert_equal(field_code(system.schema_properties, { notes: 'line1\nline2\r\nline3' }, 'notes'), null);
		t.assert_equal(field_code(system.schema_properties, { hostname: 'a\nb' }, 'hostname'), 'invalid_format');
	});
});
