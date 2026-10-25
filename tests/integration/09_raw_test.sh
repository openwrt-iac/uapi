#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
FW_RO="Authorization: Bearer $FW_RO_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- GET /raw/firewall (admin) lists raw sections ---"
listed=$(call "$URL/raw/firewall")
echo "$listed" | tail -1 | grep -q '^200$' || fail "list expected 200"
echo "$listed" | grep -q '"\.type":' || fail "missing .type field"
echo "$listed" | grep -q '"id":'     || fail "missing id field"

echo "--- POST /raw/firewall creates a rule with .type ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule",
	"target": "ACCEPT",
	"src": "lan",
	"dest_port": "8080",
	"proto": "tcp"
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"
echo "$created" | grep -q '"reloaded": true' || fail "expected reloaded:true"
echo "  new id: $id"

echo "--- GET /raw/firewall/$id ---"
got=$(call "$URL/raw/firewall/$id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"\.type": "rule"' || fail "GET missing .type"

echo "--- PATCH /raw/firewall/$id updates target ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/firewall/$id" -d '{"target":"DROP"}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"target": "DROP"' || fail "PATCH did not update target"

echo "--- POST without .type returns 422 ---"
no_type=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{"target":"ACCEPT"}')
echo "$no_type" | tail -1 | grep -q '^422$' || fail "missing .type expected 422"

echo "--- an option that uci cannot store returns 422 instead of a 200 that stored nothing ---"
for body in '{"bad-name":"1"}' '{"comment":{"x":1}}' '{"comment":["a",null]}' '{"comment":["","x"]}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/firewall/$id" -d "$body")
	echo "$r" | tail -1 | grep -q '^422$' || fail "PATCH $body expected 422: $r"
done

echo "--- raw POST with only firewall:ro denies (composition check) ---"
denied=$(curl -sS -H "$FW_RO" -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule", "target": "ACCEPT", "src": "lan"
}')
echo "$denied" | tail -1 | grep -q '^403$' || fail "ro POST via /raw/ expected 403"

# Clearing a list through raw. uci cannot store an empty list, so `[]` means "no option";
# the binding silently discarded it and the option survived a 200. raw.uc hard-codes the
# transaction lock path, so this cannot be exercised from the unit suite. Driven entirely
# over HTTP like the rest of this file: the first version shelled into the VM and hung the
# job to its 15 minute timeout.
echo "--- raw: an empty list clears the option instead of being silently dropped ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule", "name": "uapi_list_probe", "target": "ACCEPT", "src": "lan",
	"proto": ["tcp", "udp"]
}')
echo "$created" | tail -1 | grep -q '^200$' || fail "list-probe create expected 200"
probe_id=$(echo "$created" | sed -n 's/.*"id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$probe_id" ] || fail "no id returned for the list probe"
echo "$created" | grep -q '"tcp"' || fail "seed did not store the list"

cleared=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/raw/firewall/$probe_id" -d '{"proto":[]}')
echo "$cleared" | tail -1 | grep -q '^200$' || fail "raw PATCH clearing a list expected 200"

after=$(call "$URL/raw/firewall/$probe_id")
echo "$after" | tail -1 | grep -q '^200$' || fail "re-read after clearing expected 200"
echo "$after" | grep -q '"proto"' \
	&& fail "raw PATCH answered 200 but proto survived: $(echo "$after" | head -1)"
echo "  proto cleared and stays cleared on re-read"
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/raw/firewall/$probe_id"

# `managed` is derived from uci's `.anonymous` flag, never stored. Raw copies the body
# wholesale, so before this guard a read-modify-write client wrote a literal
# `option managed` into the section, and normalize_section then let that stored option
# shadow the derived value: `managed` came back as the string "0" where the schema
# promises a boolean.
echo "--- raw: managed is never written into uci, and never shadows the derived value ---"
mg=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule", "name": "uapi_managed_probe", "target": "ACCEPT", "src": "lan"
}')
echo "$mg" | tail -1 | grep -q '^200$' || fail "managed-probe create expected 200"
mg_id=$(echo "$mg" | sed -n 's/.*"id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$mg_id" ] || fail "no id for the managed probe"

patched=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/raw/firewall/$mg_id" -d '{"managed": false}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "raw PATCH with managed expected 200"

stored=$($SSH "uci -q get firewall.$mg_id.managed" | tr -d '\r')
[ -z "$stored" ] || fail "raw wrote option managed into uci: $stored"
echo "$patched" | head -1 | grep -q '"managed":[[:space:]]*true' \
	|| fail "managed did not read back as the derived boolean: $(echo "$patched" | head -1)"
echo "  managed stayed derived and out of uci"
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/raw/firewall/$mg_id"

# A section written by a client from before the guard above carries a literal
# `option managed`, and normalize_section used to let that stored string overwrite the
# derived boolean, so the response came back as "0" against a schema declaring boolean.
# Deriving after the copy fixes the read; the sweep removes the residue, which previously
# only a full replace could do.
echo "--- raw: a stored managed neither shadows the read nor survives a patch, nor do the reload fields ---"
$SSH "uci -q delete firewall.uapi_legacy_mg
      uci set firewall.uapi_legacy_mg=rule
      uci set firewall.uapi_legacy_mg.name=uapi_legacy_mg
      uci set firewall.uapi_legacy_mg.target=ACCEPT
      uci set firewall.uapi_legacy_mg.src=lan
      uci set firewall.uapi_legacy_mg.managed=0
      uci set firewall.uapi_legacy_mg.reloaded=0
      uci add_list firewall.uapi_legacy_mg.reload_services=x
      uci set firewall.uapi_legacy_mg.reload_note=stale
      uci commit firewall" >/dev/null 2>&1
seeded=$($SSH "uci -q get firewall.uapi_legacy_mg.managed" | tr -d '\r')
[ "$seeded" = "0" ] || fail "seed did not take"

read_back=$(call "$URL/raw/firewall/uapi_legacy_mg")
echo "$read_back" | head -1 | grep -q '"managed":[[:space:]]*true' \
	|| fail "a stored managed shadowed the derived value: $(echo "$read_back" | head -1)"

patched=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/raw/firewall/uapi_legacy_mg" -d '{"name":"uapi_legacy_mg2"}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "patch over a legacy section expected 200"
echo "$patched" | grep -q '"reload_note"' && fail "a stored reload_note showed in the response: $patched"
left=$($SSH "for o in managed reloaded reload_services reload_note; do uci -q get firewall.uapi_legacy_mg.\$o; done" | tr -d '\r')
[ -z "$left" ] || fail "a stale derived option survived a patch: $left"
echo "  read stays boolean, and the stale option is swept"
$SSH "uci -q delete firewall.uapi_legacy_mg; uci commit firewall" >/dev/null 2>&1

# A package with no daemon keeps these probes away from any reload.
P=uapi_raw_probe
$SSH "rm -f /etc/config/$P; touch /etc/config/$P"

echo "--- null and \"\" remove an option, and the response is what uci stored, as a GET reads it ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/$P" \
	-d '{".type":"thing","id":"s1","keep":"x","flag":true,"n":5,"one":[""],"gone":"","none":null,"e":[]}')
echo "$created" | tail -1 | grep -q '^200$' || fail "probe create expected 200: $created"
got=$(call "$URL/raw/$P/s1")
for r in "$created" "$got"; do
	echo "$r" | grep -q '"flag": "1"' || fail "true did not read as the stored \"1\": $r"
	echo "$r" | grep -q '"n": "5"' || fail "5 did not read as the stored \"5\": $r"
	echo "$r" | grep -Eq '"(gone|none|e)"' && fail "a removed option showed: $r"
done
$SSH "uci -q get $P.s1.one" >/dev/null || fail "a list of one empty item was not stored"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/$P/s1" -d '{"keep":null,"flag":""}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "removal PATCH expected 200: $patched"
echo "$patched" | grep -Eq '"(keep|flag)"' && fail "the response showed a removed option: $patched"
[ -z "$($SSH "uci -q get $P.s1.keep; uci -q get $P.s1.flag")" ] || fail "null or \"\" did not remove the option"

echo "--- a .type that uci writes unquoted as syntax answers 422, and the package still parses ---"
for t in 'rule#x' 'a;b' "a'b" 'a\"b' 'a\\b'; do
	r=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/$P" -d "{\".type\":\"$t\",\"id\":\"t1\"}")
	echo "$r" | tail -1 | grep -q '^422$' || fail ".type $t expected 422: $r"
done
$SSH "uci show $P" >/dev/null || fail "the package no longer parses"

echo "--- a PUT or PATCH refuses another .type or id, and takes an echo ---"
for body in '{".type":"other"}' '{"id":"s2"}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/$P/s1" -d "$body")
	echo "$r" | tail -1 | grep -q '^422$' || fail "PATCH $body expected 422: $r"
	echo "$r" | grep -q '"code": "read_only"' || fail "PATCH $body expected read_only: $r"
done
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/$P/s1" -d '{".type":"thing","id":"s1","x":"1"}')
echo "$r" | tail -1 | grep -q '^200$' || fail "PATCH with an echo expected 200: $r"

echo "--- a write response sent back stores none of its reload fields ---"
r=$(echo "$r" | sed '$d' | call -X PUT -H 'Content-Type: application/json' "$URL/raw/$P/s1" --data-binary @-)
echo "$r" | tail -1 | grep -q '^200$' || fail "PUT of a write response expected 200: $r"
[ -z "$($SSH "uci -q get $P.s1.reloaded; uci -q get $P.s1.reload_services; uci -q get $P.s1.reload_note")" ] \
	|| fail "a reload field was stored as an option"

echo "--- a stored option id stays out of the read, and a PUT of the read keeps it ---"
$SSH "uci set $P.zt=network; uci set $P.zt.id=8056c2e21c000001; uci commit $P"
got=$(call "$URL/raw/$P/zt")
echo "$got" | grep -q '"id": "zt"' || fail "id did not read as the section name: $got"
r=$(echo "$got" | sed '$d' | call -X PUT -H 'Content-Type: application/json' "$URL/raw/$P/zt" --data-binary @-)
echo "$r" | tail -1 | grep -q '^200$' || fail "PUT of the read expected 200: $r"
[ "$($SSH "uci -q get $P.zt.id" | tr -d '\r')" = "8056c2e21c000001" ] || fail "a PUT of the read deleted option id"

echo "--- an id by position reads and writes the section under its name ---"
r=$(call -g "$URL/raw/$P/@network[0]")
echo "$r" | grep -q '"id": "zt"' || fail "@network[0] did not read as zt: $r"
r=$(call -g -X PATCH -H 'Content-Type: application/json' "$URL/raw/$P/@network[0]" -d '{"id":"zt","y":"1"}')
echo "$r" | tail -1 | grep -q '^200$' || fail "PATCH of @network[0] with its name expected 200: $r"
[ "$($SSH "uci -q get $P.zt.y" | tr -d '\r')" = "1" ] || fail "PATCH of @network[0] did not reach zt"

echo "--- a POST without id takes the lowercase first letter of the type ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/$P" -d '{".type":"Thing"}')
echo "$r" | tail -1 | grep -q '^200$' || fail "POST of type Thing expected 200: $r"
echo "$r" | grep -q '"id": "t_' || fail "the generated id did not start with t_: $r"

echo "--- a NUL or a control byte answers 400 ---"
for body in '{"v":"a\u0000b"}' '{"k\u0000x":"1"}' '{"v":"a\u0001b"}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/$P/s1" -d "$body")
	echo "$r" | tail -1 | grep -q '^400$' || fail "PATCH $body expected 400: $r"
done
[ -z "$($SSH "uci -q get $P.s1.v; uci -q get $P.s1.k")" ] || fail "a refused body was stored"

echo "--- without the config file, PUT, PATCH and DELETE answer 404 ---"
$SSH "rm -f /etc/config/$P"
for m in PUT PATCH DELETE; do
	r=$(call -X $m -H 'Content-Type: application/json' "$URL/raw/$P/s1" -d '{"x":"1"}')
	echo "$r" | tail -1 | grep -q '^404$' || fail "$m without the file expected 404: $r"
done

echo "--- POST to a package with no config file answers 503 config_missing and creates nothing ---"
$SSH 'rm -f /etc/config/uapi_test_unknown'
unknown=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/uapi_test_unknown" -d '{
	".type": "thing", "color": "red"
}')
echo "$unknown"
echo "$unknown" | tail -1 | grep -q '^503$' || fail "POST without a config file expected 503"
echo "$unknown" | grep -q '"code": "config_missing"' || fail "expected config_missing"
$SSH 'test ! -e /etc/config/uapi_test_unknown' || fail "a refused write created the config file"

echo "--- POST to a package uapi cannot reload stores the section and reports reloaded:false ---"
$SSH 'touch /etc/config/uapi_test_unknown'
unknown=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/uapi_test_unknown" -d '{
	".type": "thing", "color": "red"
}')
echo "$unknown"
echo "$unknown" | tail -1 | grep -q '^200$' || fail "unknown pkg POST expected 200"
echo "$unknown" | grep -q '"reloaded": false' || fail "expected reloaded:false for unknown package"
echo "$unknown" | grep -q '"reload_note"' || fail "expected reload_note for unknown package"
$SSH 'uci -q show uapi_test_unknown' | grep -q "color='red'" || fail "the section was not stored"
$SSH 'rm -f /etc/config/uapi_test_unknown'

echo "--- DELETE the rule ---"
deleted=$(call -X DELETE "$URL/raw/firewall/$id")
echo "$deleted" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "raw passthrough ok"
