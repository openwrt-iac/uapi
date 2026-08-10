#!/bin/sh
set -u
# Every gate must fail when the thing it checks is broken. This breaks each one on purpose
# and asserts it says so.
#
# It exists because `lint-emdash` shipped for several releases without ever running in CI:
# it lists tracked files with `git ls-files`, the CI container installed no git, and
# `|| true` turned the resulting failure into a pass. It reported success without reading a
# file, and nobody noticed, because from the outside a green check and a working check look
# identical. "The gate runs" and "the gate works" are different claims, and only a planted
# defect separates them.
#
# Probes run in a throwaway git worktree, so a mutation can never reach the tree you are
# working in and a failed run cannot leave your checkout dirty.
#
# Adding a gate means adding a probe. The completeness check at the end derives the gate
# list from the Makefile rather than a hand-kept copy, so a new gate with no probe fails
# this script instead of passing quietly.

cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)

WT=$(mktemp -d /tmp/uapi-gate-probe.XXXXXX)
cleanup() {
	cd "$REPO" || exit
	git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
}
trap cleanup EXIT INT TERM

git worktree add --detach -q "$WT" HEAD || {
	echo "FAIL: could not create the probe worktree; is this a git checkout?"
	exit 1
}

# The worktree starts at HEAD, so carry uncommitted work across: a gate and its probe
# usually arrive in the same commit, and a self-test that only ever sees HEAD would tell you
# the new gate does not work until after you commit it. Modified files come over as a patch,
# new ones by copy.
if ! git diff --quiet HEAD; then
	git diff --binary HEAD > "$WT/.probe.patch"
	( cd "$WT" && git apply .probe.patch >/dev/null 2>&1 || \
	  echo "  note: could not carry uncommitted changes into the probe worktree" )
	rm -f "$WT/.probe.patch"
fi
git ls-files --others --exclude-standard | while read -r f; do
	case "$f" in build/sdk*|build/sbom*) continue ;; esac
	mkdir -p "$WT/$(dirname "$f")" 2>/dev/null
	cp "$f" "$WT/$f" 2>/dev/null || true
done

# Commit that state inside the throwaway worktree, so the reset between probes returns to
# the tree under test rather than to HEAD. Detached and discarded with the worktree.
( cd "$WT" && git add -A >/dev/null 2>&1 && \
  git -c user.email=probe@localhost -c user.name=probe commit -q -m "probe baseline" \
  >/dev/null 2>&1 ) || true

# --- the mutations. One function each, so quoting stays one level deep. ---

mut_emdash() { printf '\nplanted \342\200\224 here\n' >> docs/testing.md; }

mut_syntax() { printf 'function (((\n' >> src/lib/values.uc; }

mut_reserved() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['System']['properties']['count'] = {'type': 'string'}
json.dump(d, open(p, 'w'))
EOF
}

mut_dangling_ref() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['ProbeDangling'] = {'$ref': '#/components/schemas/Nope'}
json.dump(d, open(p, 'w'))
EOF
}

mut_if_without_then() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['System']['allOf'] = [{'if': {'properties': {'hostname': {'const': 'x'}}}}]
json.dump(d, open(p, 'w'))
EOF
}

mut_unannotated_default() {
	python3 - <<'EOF'
import pathlib
p = pathlib.Path('src/resources/system.uc'); s = p.read_text()
i = s.index('function fromUci')
j = s.index('return {', i) + len('return {')
p.write_text(s[:j] + '\n\t\tprobe_f: section.probe_f ?? "x",' + s[j:])
EOF
}

# The string form was the only probed shape, so when 50 fields moved from normalize_bool
# to shell_bool the gate silently stopped seeing them and kept reporting OK. One probe per
# helper that takes a default, so the next reclassification cannot repeat it.
mut_unannotated_bool_default() {
	python3 - <<'EOF'
import pathlib
p = pathlib.Path('src/resources/dhcp.dnsmasq.uc'); s = p.read_text()
i = s.index('function fromUci')
j = s.index('return {', i) + len('return {')
p.write_text(s[:j] + '\n\t\tprobe_b: shell_bool(section.probe_b, true),' + s[j:])
EOF
}

mut_doc_bad_path()   { printf '\nSee `src/lib/nope.uc`.\n' >> docs/testing.md; }
mut_doc_bad_symbol() { printf '\nHandled by `values.no_such_helper`.\n' >> docs/testing.md; }
mut_doc_bad_target() { printf '\nRun `make nope-target`.\n' >> docs/testing.md; }

# An announcement recorded in the ledger but absent from the published spec: the shape that
# left the list-reads-null change invisible to every generated client.
mut_unannounced_deprecation() {
	python3 - <<'EOF'
import json, re
p = 'build/openapi.json'; d = json.load(open(p))
desc = d['info']['description']
new = re.sub(r'\n- \*\*`dhcp/hosts\.tag`[^\n]*', '', desc, count=1)
assert new != desc, 'upcoming bullet not found'
d['info']['description'] = new
json.dump(d, open(p, 'w'))
EOF
}

mut_doc_bad_claim() { printf '\nIt claims "no test prints this line".\n' >> docs/testing.md; }

mut_code_unemitted() {
	python3 - <<'EOF'
import pathlib
q = chr(96)
p = pathlib.Path('docs/errors.md'); s = p.read_text()
anchor = '| 422  | ' + q + 'validation_failed' + q
row = '| 418  | ' + q + 'probe_teapot' + q + '  | invented for this probe |\n'
assert anchor in s, 'anchor row not found'
p.write_text(s.replace(anchor, row + anchor, 1))
EOF
}

mut_code_undocumented() {
	python3 - <<'EOF'
import pathlib
p = pathlib.Path('src/lib/errors.uc'); s = p.read_text()
a = '\t"batch_partial_failure",'
assert a in s, 'enum anchor not found'
p.write_text(s.replace(a, a + '\n\t"probe_undocumented",', 1))
EOF
}

mut_stale_spec() {
	python3 - <<'EOF'
import pathlib
p = pathlib.Path('src/resources/system.uc'); s = p.read_text()
a = 'System hostname (alphanumerics'
assert a in s, 'description anchor not found'
p.write_text(s.replace(a, 'PROBE hostname (alphanumerics', 1))
EOF
}

# Defined as well as exported: an export with no definition would be a different defect.
mut_dead_export() {
	python3 - <<'EOF'
import pathlib
p = pathlib.Path('src/lib/values.uc'); s = p.read_text()
a = '\trequire_present, section_index,'
assert a in s, 'export anchor not found'
s = s.replace('function require_present(', 'function probe_dead_export() { return 1; }\n\nfunction require_present(', 1)
p.write_text(s.replace(a, '\trequire_present, section_index, probe_dead_export,', 1))
EOF
}

# docs/testing.md claims four shapes for lint-openapi-shape and two rules for
# lint-defaults; one of each was probed, so the rest were documented but unverified.
mut_required_undeclared() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['System']['required'] = ['nope_field']
json.dump(d, open(p, 'w'))
EOF
}

mut_empty_enum() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['System']['properties']['hostname']['enum'] = []
json.dump(d, open(p, 'w'))
EOF
}

mut_then_without_if() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['System']['allOf'] = [{'then': {'required': ['hostname']}}]
json.dump(d, open(p, 'w'))
EOF
}

mut_nan_value() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['System']['properties']['hostname']['maxLength'] = 'NaN'
json.dump(d, open(p, 'w'))
EOF
}

mut_hcl_keyword() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
d['components']['schemas']['System']['properties']['resource'] = {'type': 'string'}
json.dump(d, open(p, 'w'))
EOF
}

mut_default_and_clear_on_omit() {
	python3 - <<'EOF'
import pathlib
p = pathlib.Path('src/resources/system.uc'); s = p.read_text()
a = 'log_remote:   { type: "boolean", default: false }'
assert a in s, 'default-carrying property not found'
p.write_text(s.replace(a, 'log_remote:   { type: "boolean", default: false, "x-uapi-clear-on-omit": true }', 1))
EOF
}

probed=""
failures=0

# probe <gate> <label> <expected-fragment> <mutation-function>
#
# The expected fragment matters as much as the exit code: a gate that fails for an
# unrelated reason (a syntax error in the gate itself, a missing tool) would otherwise read
# as a pass, which is the same mistake in a new costume. An empty fragment means only the
# exit code is checked, for gates whose output is a diff rather than a message.
probe() {
	gate=$1; label=$2; expect=$3; mutate=$4
	case " $probed " in *" $gate "*) : ;; *) probed="$probed $gate" ;; esac

	( cd "$WT" && git checkout -q -- . && $mutate ) >/dev/null 2>&1

	# A probe that changed nothing is a broken probe, not a blind gate. The two are
	# indistinguishable from the exit code alone, and telling them apart is the entire
	# point of this script.
	if ( cd "$WT" && git diff --quiet ); then
		printf '  %-38s PROBE CHANGED NOTHING (broken probe, not a blind gate)\n' "$label"
		failures=$((failures + 1))
		( cd "$WT" && git checkout -q -- . )
		return
	fi

	out=$( cd "$WT" && make "$gate" 2>&1 )
	rc=$?
	if [ "$rc" -eq 0 ]; then
		printf '  %-38s DID NOT FAIL: %s does not notice this\n' "$label" "$gate"
		failures=$((failures + 1))
	elif [ -n "$expect" ] && ! printf '%s' "$out" | grep -qF "$expect"; then
		printf '  %-38s failed, but not for the stated reason\n' "$label"
		printf '      wanted: %s\n' "$expect"
		printf '      got:    %s\n' "$(printf '%s' "$out" | grep -iE 'fail|error' | head -1 | cut -c1-88)"
		failures=$((failures + 1))
	else
		printf '  %-38s fails as designed\n' "$label"
	fi
	( cd "$WT" && git checkout -q -- . )
}

echo "=== each gate, broken on purpose ==="
probe lint-emdash        "em-dash in a tracked file"           "em-dash found in tracked files"    mut_emdash
probe lint-syntax        "ucode that does not parse"           "Syntax error"                      mut_syntax
probe lint-reserved      "a Terraform-reserved property name"  "Terraform meta-arguments"          mut_reserved
probe lint-refs          "a dangling ref"                      "dangling"                          mut_dangling_ref
mut_kernel_header_unpaired() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
r = d['paths']['/network/interfaces/{id}']['put']['responses']['200']
del r['headers']['X-Kernel-Applied']
json.dump(d, open(p, 'w'))
EOF
}

mut_managed_writable() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
del d['components']['schemas']['FirewallRules']['properties']['managed']['readOnly']
json.dump(d, open(p, 'w'))
EOF
}

mut_unaccounted_wire_name() {
	python3 - <<'EOF'
import pathlib
p = pathlib.Path('src/resources/network.routes.uc'); s = p.read_text()
# A second API name for a uci key another field already writes: the alias shape a major
# removes, planted on a resource that has none.
s = s.replace("\tif (json.gateway != null)   out.gateway = json.gateway;",
              "\tif (json.gateway != null)   out.gateway = json.gateway;\n\tif (json.via != null)       out.gateway = json.via;", 1)
s = s.replace('\t\tgateway:   { type: ["string", "null"],',
              '\t\tvia:       { type: ["string", "null"] },\n\t\tgateway:   { type: ["string", "null"],', 1)
p.write_text(s)
EOF
}

mut_deprecated_no_reason() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
del d['components']['schemas']['DhcpHosts']['properties']['mac']['description']
json.dump(d, open(p, 'w'))
EOF
}

mut_etag_on_raw() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
r = d['paths']['/raw/{package}/{id}']['put']['responses']['200']
r.setdefault('headers', {})['ETag'] = {'$ref': '#/components/headers/ETag'}
json.dump(d, open(p, 'w'))
EOF
}

mut_etag_undeclared_on_curated() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
del d['paths']['/firewall/rules/{id}']['get']['responses']['200']['headers']['ETag']
json.dump(d, open(p, 'w'))
EOF
}

mut_reload_header_on_raw() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
r = d['paths']['/raw/{package}/{id}']['put']['responses']['200']
r.setdefault('headers', {})['X-Reload-Status'] = {'$ref': '#/components/headers/XReloadStatus'}
json.dump(d, open(p, 'w'))
EOF
}

mut_mgmt_header_undeclared() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
for verb in ('put', 'patch', 'delete'):
    for r in d['paths']['/network/interfaces/{id}'][verb]['responses'].values():
        (r.get('headers') or {}).pop('X-Mgmt-Path-Warning', None)
json.dump(d, open(p, 'w'))
EOF
}

mut_mgmt_header_wrong_verb() {
	python3 - <<'EOF'
import json
p = 'build/openapi.json'; d = json.load(open(p))
r = d['paths']['/network/interfaces/{id}']['get']['responses']['200']
r.setdefault('headers', {})['X-Mgmt-Path-Warning'] = {'$ref': '#/components/headers/XMgmtPathWarning'}
json.dump(d, open(p, 'w'))
EOF
}

probe lint-openapi-shape "an if with no then"                  "constrains nothing"                mut_if_without_then
probe lint-openapi-shape "a then with no if"                   "then/else with no if"              mut_then_without_if
probe lint-openapi-shape "required names an undeclared prop"   "which the schema does not declare" mut_required_undeclared
probe lint-openapi-shape "an empty enum"                       "nothing can validate against it"   mut_empty_enum
probe lint-openapi-shape "a value that is the string NaN"      "evaluated to NaN"                  mut_nan_value
probe lint-openapi-shape "a transaction header without its set" "declares only"                    mut_kernel_header_unpaired
probe lint-openapi-shape "a reload header on a raw write"      "never reaches attach_reload_headers" mut_reload_header_on_raw
probe lint-openapi-shape "an ETag on a raw write"              "set_etag_header is never reached"  mut_etag_on_raw
probe lint-openapi-shape "a writable managed property"        "must be readOnly"                 mut_managed_writable
probe lint-openapi-shape "a deprecation with no reason"       "does not open with"               mut_deprecated_no_reason
probe lint-wire-names    "an unaccounted alias name"            "is read by toUci but never written" mut_unaccounted_wire_name
probe lint-openapi-shape "a curated GET not declaring its ETag" "does not declare it"              mut_etag_undeclared_on_curated
probe lint-openapi-shape "an emitted header declared nowhere"  "path(s) should declare the header" mut_mgmt_header_undeclared
probe lint-openapi-shape "a header on a verb that cannot emit it" "attach_mgmt_warning reaches"      mut_mgmt_header_wrong_verb
probe lint-reserved      "an HCL block keyword as a property"  "HCL block keywords"                mut_hcl_keyword
probe lint-defaults      "a fromUci default, unannotated"      "absent from schema_properties"     mut_unannotated_default
probe lint-defaults      "an unannotated shell_bool default"   "has fromUci default true but"      mut_unannotated_bool_default
probe lint-defaults      "default and clear-on-omit together"  ""                                  mut_default_and_clear_on_omit
# lint-doc-refs carries five distinct checks, so it gets five probes: one passing check
# would otherwise vouch for four that were never exercised.
probe lint-doc-refs      "doc cites a missing path"            "path does not exist"               mut_doc_bad_path
probe lint-doc-refs      "doc cites a missing export"          "does not export"                   mut_doc_bad_symbol
probe lint-doc-refs      "doc cites a missing make target"     "defines no target"                 mut_doc_bad_target
probe lint-doc-refs      "a deprecation the spec omits"         "ledger announces"                  mut_unannounced_deprecation
probe lint-doc-refs      "a claim no test prints"               "no test prints this claim"         mut_doc_bad_claim
probe lint-doc-refs      "an error code nothing emits"         "nothing in src/ emits it"          mut_code_unemitted
probe lint-doc-refs      "an enum code nothing documents"      "appears nowhere in docs/errors.md" mut_code_undocumented
probe openapi-check      "a schema change not regenerated"     ""                                  mut_stale_spec
probe coverage           "a lib export nothing uses"           "DEAD LIB EXPORTS"                  mut_dead_export

echo
echo "=== every gate has a probe ==="
# Derived from the Makefile, not hand-listed, so a new gate cannot slip in unprobed.
chain=$(sed -n 's/^lint:[[:space:]]*//p' Makefile)
missing=""
for g in $chain; do
	case " $probed " in *" $g "*) : ;; *) missing="$missing $g" ;; esac
done
for g in openapi-check coverage; do
	case " $probed " in *" $g "*) : ;; *) missing="$missing $g" ;; esac
done
if [ -n "$missing" ]; then
	echo "  gates with no demonstrated failure:$missing"
	echo ""
	echo "  Add a probe to tests/gate_selftest.sh. A gate nobody has seen fail is a gate"
	echo "  nobody knows works: lint-emdash passed in CI for releases without reading a file."
	failures=$((failures + 1))
else
	echo "  $(printf '%s' "$probed" | wc -w) gates probed, covering the Makefile lint chain plus openapi-check and coverage"
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "FAIL: $failures gate(s) did not demonstrate a failure"
	exit 1
fi
echo "OK: every gate fails when the thing it checks is broken"
