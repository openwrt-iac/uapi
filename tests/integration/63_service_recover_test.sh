#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v4
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

cleanup() {
	for n in t63_services t63_dhcp t63_system_ro; do
		$SSH "uapi-token revoke $n" >/dev/null 2>&1 || true
	done
	$SSH 'ubus call service delete "{\"name\":\"uapi_t63_oneshot\"}"; /etc/init.d/dnsmasq restart' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

# The body, then the status on a line of its own.
recover() {
	curl -sS -H "Authorization: Bearer $1" -X POST -w '\n%{http_code}' "$URL/uapi/services/$2/recover"
}
status_of() { echo "$1" | tail -1; }
field() { $SSH "ubus call service list '{\"name\":\"dnsmasq\"}' | jsonfilter -e '@.dnsmasq.instances.$1.$2'" || true; }

wait_running() {
	n=0
	until [ "$(field "$1" running)" = "true" ]; do
		n=$((n + 1))
		[ $n -lt 15 ] || fail "dnsmasq/$1 does not run: $($SSH "ubus call service list '{\"name\":\"dnsmasq\"}'")"
		sleep 1
	done
}

# respawn ["3600", "0", "1"]: procd starts /bin/false again at once, and gives up at its second death.
give_up() {
	$SSH "ubus call service add '{\"name\":\"dnsmasq\",\"instances\":{\"$1\":{\"command\":[\"/bin/false\"],\"respawn\":[\"3600\",\"0\",\"1\"]}}}'"
	n=0
	until [ "$(field "$1" running)" = "false" ] && [ -z "$(field "$1" respawn)" ]; do
		n=$((n + 1))
		[ $n -lt 10 ] || fail "procd did not give up on dnsmasq/$1"
		sleep 1
	done
}

name=$($SSH "ucode -e 'print(keys(require(\"ubus\").connect().call(\"service\", \"list\", { name: \"dnsmasq\" }).dnsmasq.instances)[0])'")
[ -n "$name" ] || fail "procd lists no dnsmasq instance"
wait_running "$name"

SERVICES=$($SSH "uapi-token create --name t63_services --scope 'uapi:services:rw'" 2>/dev/null | head -1)
DHCP=$($SSH "uapi-token create --name t63_dhcp --scope 'dhcp:rw'" 2>/dev/null | head -1)
SYSTEM_RO=$($SSH "uapi-token create --name t63_system_ro --scope 'system:ro'" 2>/dev/null | head -1)
[ -n "$SERVICES" ] && [ -n "$DHCP" ] && [ -n "$SYSTEM_RO" ] || fail "could not mint the tokens"

echo "--- a dnsmasq that runs gets no stop and no start ---"
pid=$(field "$name" pid)
r=$(recover "$SERVICES" dnsmasq)
[ "$(status_of "$r")" = "200" ] || fail "expected 200: $r"
echo "$r" | grep -qF '{ "service": "dnsmasq", "recovered": [ ] }' || fail "expected an empty recovered: $r"
[ "$(field "$name" pid)" = "$pid" ] || fail "dnsmasq was restarted"

echo "--- dhcp:rw recovers dnsmasq, not snmpd, and system:ro recovers nothing ---"
r=$(recover "$DHCP" dnsmasq)
[ "$(status_of "$r")" = "200" ] || fail "dhcp:rw on dnsmasq: $r"
r=$(recover "$DHCP" snmpd)
[ "$(status_of "$r")" = "403" ] || fail "dhcp:rw on snmpd: $r"
echo "$r" | grep -q '"code": "insufficient_scope"' || fail "dhcp:rw on snmpd: $r"
r=$(recover "$SYSTEM_RO" dnsmasq)
[ "$(status_of "$r")" = "403" ] || fail "system:ro on dnsmasq: $r"

echo "--- a service outside the list answers 404, whatever the token ---"
for svc in uhttpd network dropbear nope; do
	r=$(recover "$ADMIN_TOKEN" "$svc")
	[ "$(status_of "$r")" = "404" ] || fail "$svc: $r"
	echo "$r" | grep -q '"code": "not_found"' || fail "$svc: $r"
done
r=$(curl -sS -H "$ADMIN" -w '\n%{http_code}' "$URL/uapi/services/dnsmasq/recover")
[ "$(status_of "$r")" = "405" ] || fail "GET: $r"

echo "--- an Idempotency-Key replays the 200 ---"
key="t63-$(date +%s)"
for i in 1 2; do
	curl -sS -D /tmp/uapi_t63_headers -o /dev/null -H "Authorization: Bearer $SERVICES" \
		-H "Idempotency-Key: $key" -X POST "$URL/uapi/services/dnsmasq/recover"
done
grep -qi '^Idempotent-Replayed: true' /tmp/uapi_t63_headers || fail "no replay: $(cat /tmp/uapi_t63_headers)"

echo "--- diagnostics lists a dnsmasq instance that procd gave up on, and not a one-shot that ended ---"
$SSH 'ubus call service add "{\"name\":\"uapi_t63_oneshot\",\"instances\":{\"job\":{\"command\":[\"/bin/true\"]}}}"'
give_up uapi_t63
d=$(curl -sS -H "$ADMIN" "$URL/uapi/diagnostics")
echo "$d" | grep -qF '{ "service": "dnsmasq", "instance": "uapi_t63" }' || fail "uapi_t63 not listed: $d"
echo "$d" | grep -q 'uapi_t63_oneshot' && fail "the one-shot is listed: $d"

echo "--- an instance that the start does not bring back answers 500 recover_failed ---"
r=$(recover "$SERVICES" dnsmasq)
[ "$(status_of "$r")" = "500" ] || fail "expected 500: $r"
echo "$r" | grep -q '"code": "recover_failed"' || fail "expected recover_failed: $r"
echo "$r" | grep -qF '"stopped": [ "uapi_t63" ]' || fail "expected stopped uapi_t63: $r"
echo "$r" | grep -q 'dnsmasq/uapi_t63' || fail "the message does not name dnsmasq/uapi_t63: $r"
wait_running "$name"

echo "--- an instance that the start brings back answers 200 and names it ---"
give_up "$name"
r=$(recover "$DHCP" dnsmasq)
[ "$(status_of "$r")" = "200" ] || fail "expected 200: $r"
echo "$r" | grep -qF "{ \"service\": \"dnsmasq\", \"recovered\": [ \"$name\" ] }" || fail "expected $name: $r"
wait_running "$name"

echo "OK"
