#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Validate real response bodies against the schemas the spec publishes for them. Every other
# layer checks the document against itself: lint-openapi-shape walks it structurally,
# lint-response-nullability derives null-permission from each resource's fromUci. Neither reads
# a body off the wire, and two defects lived in exactly that gap. TokenMetadata was `allOf` over
# WhoamiResponse and so demanded `token_id` and `source_ip` from entries that carry neither,
# which is unsatisfiable only in composition and only against a real response. And
# network/interfaces declares its dhcp keys non-nullable while a static interface returns them
# null; a bare probe section omits those keys entirely, so no code-side derivation sees them.
#
# The spec is fetched from the box rather than read out of build/, so a packaged document that
# disagrees with the tree fails here too.

echo "--- the served spec matches the one in the tree ---"
curl -sS -o /tmp/uapi_conf_spec.json -H "$ADMIN" "$URL/openapi.json" >/dev/null
python3 - <<'PY' || fail "served spec differs from build/openapi.json"
import json, sys
a = json.load(open('/tmp/uapi_conf_spec.json'))
b = json.load(open('build/openapi.json'))
sys.exit(0 if a == b else 1)
PY

echo "--- every parameterless GET body validates against its declared 200 schema ---"
python3 - <<'PY' > /tmp/uapi_conf_paths.txt
import json
d = json.load(open('/tmp/uapi_conf_spec.json'))
for p, ops in sorted(d['paths'].items()):
    op = ops.get('get')
    if not isinstance(op, dict) or '{' in p:
        continue
    sch = op.get('responses', {}).get('200', {}).get('content', {}).get('application/json', {}).get('schema')
    if sch:
        print(p)
PY

: > /tmp/uapi_conf_bodies.jsonl
while read -r p; do
	[ -z "$p" ] && continue
	code=$(curl -sS -o /tmp/uapi_conf_one.json -w '%{http_code}' -H "$ADMIN" "$URL$p")
	# A resource whose package is not installed answers 404 by design; it has no body to check.
	[ "$code" = "200" ] || continue
	printf '%s\t' "$p" >> /tmp/uapi_conf_bodies.jsonl
	tr -d '\n' < /tmp/uapi_conf_one.json >> /tmp/uapi_conf_bodies.jsonl
	printf '\n' >> /tmp/uapi_conf_bodies.jsonl
done < /tmp/uapi_conf_paths.txt

# Separated from the validation below so a missing dependency cannot be reported as a schema
# violation. The first CI run of this test failed with "a response body does not match its
# published schema" when the real cause was an ImportError, which is the exact shape of broken
# check this file exists to prevent.
python3 - <<'DEPS' || fail "the validator could not run, which says nothing about the responses"
try:
	import jsonschema, referencing  # noqa: F401
except ImportError as e:
	raise SystemExit("missing dependency: %s" % e)
DEPS

python3 - <<'PY' || fail "a response body does not match its published schema"
import json, sys
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

spec = json.load(open('/tmp/uapi_conf_spec.json'))
registry = Registry().with_resource(
    uri='urn:spec', resource=Resource(contents=spec, specification=DRAFT202012))

# The response schemas reference #/components/... , which resolves against the document root
# rather than against the fragment handed to the validator, so each ref is rebased onto the
# registered spec before validating.
def rebase(s):
    if isinstance(s, dict):
        return {k: ('urn:spec' + v) if k == '$ref' and isinstance(v, str) and v.startswith('#/')
                else rebase(v) for k, v in s.items()}
    if isinstance(s, list):
        return [rebase(x) for x in s]
    return s

checked = failed = 0
for line in open('/tmp/uapi_conf_bodies.jsonl'):
    line = line.rstrip('\n')
    if not line:
        continue
    path, raw = line.split('\t', 1)
    schema = spec['paths'][path]['get']['responses']['200']['content']['application/json']['schema']
    errors = sorted(Draft202012Validator(rebase(schema), registry=registry).iter_errors(json.loads(raw)),
                    key=lambda e: list(e.absolute_path))
    checked += 1
    if errors:
        failed += 1
        print('  %s: %d violation(s)' % (path, len(errors)))
        for e in errors[:5]:
            print('      %s: %s' % ('/'.join(str(x) for x in e.absolute_path) or '<root>', e.message))

if checked == 0:
    print('  no bodies were checked, which means this test proved nothing')
    sys.exit(1)
print('  %d bodies validated, %d violating' % (checked, failed))
sys.exit(1 if failed else 0)
PY

echo "PASS 50_response_conformance_test"
