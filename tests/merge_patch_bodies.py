# A strict client validates a request body before it sends it, so the PATCH schema has to take
# what the server takes. The server type-checks a merge-patch body, and checks the required
# fields on the stored section that the body merges into, so a body that names one field, or
# none, is valid. lint-openapi-shape checks the shape of each schema. This asks a real JSON
# Schema implementation what a client concludes from it.
import json
import sys
from urllib.parse import quote

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

spec = json.load(open("build/openapi.json"))
schemas = spec["components"]["schemas"]
registry = Registry().with_resource("urn:spec", Resource(contents=spec, specification=DRAFT202012))

# A merge patch removes a field with null, and the server takes it: the type check skips a null,
# the merge drops the field and the write removes the option. A field keeps the nullability of its
# Request where a null is not a removal: `id`, which a PATCH ignores, a write-only secret, which a
# null keeps, a field that the Request requires, which validate() refuses on the merged section,
# and the fields named here.
NULL_KEPT = {"WirelessInterfacesPatch": {"mode"}}


def errors(pointer, instance):
    validator = Draft202012Validator({"$ref": "urn:spec#" + quote(pointer)}, registry=registry)
    return list(validator.iter_errors(instance))


def body_pointer(path):
    return "/paths/%s/patch/requestBody/content/application~1json/schema" % path.replace("~", "~0").replace("/", "~1")


# Each body that sets one field to null, with the Request property whose verdict on null the body
# keeps, or None where the body must take the null.
def null_bodies(schema, request, keep, pointer):
    for k, prop in schema.get("properties", {}).items():
        req = request.get("properties", {}).get(k, {})
        at = "%s/properties/%s" % (pointer, k)
        for sub, kept in null_bodies(prop, req, set(req.get("required", [])), at):
            yield {k: sub}, kept
        yield {k: None}, (at if k in keep or prop.get("writeOnly") else None)


cases = []
nulls = 0
for path, item in spec["paths"].items():
    body = item.get("patch", {}).get("requestBody", {}).get("content", {}).get("application/json")
    if body is None:
        continue
    cases.append((path, {}, None))
    # The raw body is a uci section, where null already removes any option.
    if path.startswith("/raw/"):
        continue
    name = body["schema"]["$ref"].rsplit("/", 1)[1]
    request = name[:-5] + "Request" if name.endswith("Patch") else name
    keep = {"id", *schemas[request].get("required", []), *NULL_KEPT.get(name, ())}
    for b, kept in null_bodies(schemas[name], schemas[request], keep, "/components/schemas/" + request):
        nulls += 1
        refused = kept is not None and errors(kept, None)
        cases.append((path, b, "a null does not remove this field, and %s refuses it" % request if refused else None))
cases += [
    ("/wireless/interfaces/{id}", {"ssid": "x"}, None),
    ("/network/interfaces/{id}", {"proto": "static"}, None),
    ("/firewall/redirects/{id}", {"match": {"src_dport": "8080"}}, None),
    ("/network/interfaces/{id}", {"mtu": "x"}, "it has a wrong type"),
    ("/wireless/interfaces/{id}", {"ssid": 5}, "it has a wrong type"),
]

failed = 0
for path, body, refusal in cases:
    errs = errors(body_pointer(path), body)
    if refusal is None and errs:
        failed += 1
        print("PATCH %s refuses %s, a partial body that the server merges into the stored section: %s" % (path, json.dumps(body), errs[0].message))
    elif refusal is not None and not errs:
        failed += 1
        print("PATCH %s takes %s, but %s" % (path, json.dumps(body), refusal))

if failed:
    print("FAIL: %d merge-patch body case(s) disagree with the server" % failed)
    sys.exit(1)
print("OK: %d merge-patch body cases agree with the server, %d of them a field set to null" % (len(cases), nulls))
