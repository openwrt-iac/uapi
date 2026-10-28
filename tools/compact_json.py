# Why the spec is installed compact: docs/packaging.md, step 2 of the build.
import json
import sys

src, dst = sys.argv[1:]
with open(src, "rb") as f:
    doc = json.load(f)
# ucode writes a NaN or an infinity as 1e309, which Python reads as inf and would write as
# Infinity, which is not JSON.
with open(dst, "w") as f:
    json.dump(doc, f, separators=(",", ":"), allow_nan=False)


# A dict comparison ignores key order and takes true for 1. The repr of the pairs keeps the
# order, a duplicate key and the type of each value.
def pairs(path):
    with open(path, "rb") as f:
        return repr(json.load(f, object_pairs_hook=tuple))


if pairs(dst) != pairs(src):
    sys.exit("%s does not parse to the same JSON value as %s" % (dst, src))
