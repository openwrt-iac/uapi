# A strict client validates a request body before it sends it, so the PATCH schema has to take
# what the server takes. The server merges a merge-patch body into the stored section and
# validates the result, so a body that names one field, or none, is valid. lint-openapi-shape
# checks the shape of each schema. This asks a real JSON Schema implementation what a client
# concludes from it.
import json
import sys
from urllib.parse import quote

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

spec = json.load(open("build/openapi.json"))
registry = Registry().with_resource("urn:spec", Resource(contents=spec, specification=DRAFT202012))


def errors(path, body):
    pointer = "/paths/%s/patch/requestBody/content/application~1json/schema" % path.replace("~", "~0").replace("/", "~1")
    validator = Draft202012Validator({"$ref": "urn:spec#" + quote(pointer)}, registry=registry)
    return list(validator.iter_errors(body))


cases = [(p, {}, True) for p, item in spec["paths"].items()
         if "application/json" in item.get("patch", {}).get("requestBody", {}).get("content", {})]
cases += [
    ("/wireless/interfaces/{id}", {"ssid": "x"}, True),
    ("/network/interfaces/{id}", {"proto": "static"}, True),
    ("/firewall/redirects/{id}", {"match": {"src_dport": "8080"}}, True),
    ("/network/interfaces/{id}", {"mtu": "x"}, False),
    ("/wireless/interfaces/{id}", {"ssid": 5}, False),
]

failed = 0
for path, body, valid in cases:
    errs = errors(path, body)
    if valid and errs:
        failed += 1
        print("PATCH %s refuses %s, a partial body that the server merges into the stored section: %s" % (path, json.dumps(body), errs[0].message))
    elif not valid and not errs:
        failed += 1
        print("PATCH %s takes %s, which has a wrong type" % (path, json.dumps(body)))

if failed:
    print("FAIL: %d merge-patch body case(s) disagree with the server" % failed)
    sys.exit(1)
print("OK: %d merge-patch body cases agree with the server" % len(cases))
