#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body() { printf '%s\n' "$1" | sed '$d'; }
status() { printf '%s\n' "$1" | tail -1; }
send() { call -X "$1" -H 'Content-Type: application/json' "$URL/$2" -d "$3"; }
read_back() { body "$(call "$URL/network/rules/$1")" | jq -c 'del(.runtime)'; }
uci_get() { $SSH "uci -q get network.$1" || true; }
wait_for() {
	local what="$1" check="$2"
	for _ in $(seq 20); do
		eval "$check" && return 0
		sleep 1
	done
	fail "$what"
}

# Every rule but one matches a source from 10.253.70.0 to 10.253.79.255, which no interface holds.
# Each looks up table 159, which holds no route, at priorities 30590 to 30599, so no routing
# decision moves, the rule without a selector included.
RULES="uapi59s uapi59m uapi59l uapi59t uapi59u uapi59p uapi59x uapi59y uapi59w uapi59h uapi59z"
DUMP=/tmp/uapi59_rules.uc
cleanup() {
	$SSH "for s in $RULES; do uci -q delete network.\$s; done; uci commit network; /etc/init.d/network reload; rm -f $DUMP" \
		>/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

# busybox ip prints tos and suppress_prefixlength but none of the other four options, so the kernel
# dump through ucode's rtnl module is what the checks read.
$SSH 'apk info -e ucode-mod-rtnl >/dev/null 2>&1 || apk add ucode-mod-rtnl >/dev/null 2>&1' \
	|| fail "ucode-mod-rtnl is missing and apk could not install it, so the kernel's rules cannot be read"
$SSH "cat > $DUMP" <<'EOF'
let rtnl = require('rtnl');
for (let r in rtnl.request(rtnl.const.RTM_GETRULE, rtnl.const.NLM_F_DUMP, { family: rtnl.const.AF_INET }) ?? [])
	printf("%J\n", r);
EOF
$SSH "ucode $DUMP" >/dev/null || fail "ucode-mod-rtnl is installed, but the dump of the kernel's rules failed"
kernel_rule() { $SSH "ucode $DUMP" | jq -c "select(.priority == $1)"; }
has() { kernel_rule "$1" | jq -e "$2" >/dev/null; }
ip_rule() { $SSH 'ip rule show' | grep "^$1:" || true; }

echo "--- suppress_prefixlength 0 and 32 reach the kernel ---"
r=$(send POST network/rules '{"id":"uapi59s","src":"10.253.70.0/24","priority":30590,"lookup":159,"suppress_prefixlength":0}')
[ "$(status "$r")" = 200 ] || fail "POST suppress_prefixlength 0 expected 200: $r"
[ "$(uci_get uapi59s.suppress_prefixlength)" = 0 ] || fail "uci holds no suppress_prefixlength 0"
wait_for "ip rule shows no suppress_prefixlength 0 on 30590" \
	'ip_rule 30590 | grep -Eq "from 10.253.70.0/24 .*lookup 159 .*suppress_prefixlength 0( |\$)"'
read_back uapi59s | jq -e '.suppress_prefixlength == 0' >/dev/null || fail "the rule read wrong: $(read_back uapi59s)"
r=$(send PATCH network/rules/uapi59s '{"suppress_prefixlength":32}')
[ "$(status "$r")" = 200 ] || fail "PATCH suppress_prefixlength 32 expected 200: $r"
wait_for "ip rule shows no suppress_prefixlength 32 on 30590" \
	'ip_rule 30590 | grep -Eq "suppress_prefixlength 32( |\$)"'

echo "--- a rule without a selector is created, installed and takes a PUT of its read ---"
r=$(send POST network/rules '{"id":"uapi59w","priority":30598,"lookup":159,"suppress_prefixlength":0}')
[ "$(status "$r")" = 200 ] || fail "POST of a rule without a selector expected 200: $r"
wait_for "ip rule shows no selector-less rule on 30598" \
	'ip_rule 30598 | grep -Eq "from all lookup 159 suppress_prefixlength 0( |\$)"'
r=$(send PUT network/rules/uapi59w "$(read_back uapi59w)")
[ "$(status "$r")" = 200 ] || fail "PUT of the read of a rule without a selector expected 200: $r"

echo "--- tos, ipproto, ports and uids reach the kernel as written ---"
r=$(send POST network/rules '{"id":"uapi59m","src":"10.253.71.0/24","priority":30591,"lookup":159,"tos":16,"ipproto":6,"sport":"1000-2000","dport":"443","uidrange":"1000-1005"}')
[ "$(status "$r")" = 200 ] || fail "POST of the match options expected 200: $r"
wait_for "the kernel has no rule 30591 with the five options: $(kernel_rule 30591)" \
	'has 30591 ".tos == 16 and .ip_proto == 6 and .sport_range == [1000,2000] and .dport_range == [443,443] and .uid_range == [1000,1005]"'
read_back uapi59m | jq -e '.tos == 16 and .ipproto == 6 and .sport == "1000-2000" and .dport == "443" and .uidrange == "1000-1005" and .suppress_prefixlength == null' \
	>/dev/null || fail "the rule read wrong: $(read_back uapi59m)"

echo "--- a PUT of a rule that LuCI wrote keeps all six options ---"
# l is LuCI's form of each option. t, u, p, x and y hold what LuCI or a hand edit can store and
# netifd drops or the kernel refuses: tos 10 sets an ECN bit, tos 32 a bit above 0x1c, port 65535 is
# past the kernel's range, ipproto 0 resolves to nothing, and musl's table holds no sctp. h is
# disabled and holds forms that a write refuses and netifd installs.
$SSH "uci set network.uapi59l=rule; uci set network.uapi59l.src=10.253.72.0/24; uci set network.uapi59l.lookup=159
	uci set network.uapi59l.priority=30592; uci set network.uapi59l.suppress_prefixlength=0; uci set network.uapi59l.tos=16
	uci set network.uapi59l.ipproto=6; uci set network.uapi59l.sport=1000-2000; uci set network.uapi59l.dport=443
	uci set network.uapi59l.uidrange=1000-1005
	for x in 't 73 30593 tos 10' 'u 74 30594 tos 32' 'p 75 30595 dport 65535' 'x 76 30596 ipproto 0' \
		'y 77 30597 ipproto sctp' 'h 79 30599 disabled 1'; do
		set -- \$x; s=uapi59\$1
		uci set network.\$s=rule; uci set network.\$s.src=10.253.\$2.0/24; uci set network.\$s.lookup=159
		uci set network.\$s.priority=\$3; uci set network.\$s.\$4=\$5
	done
	uci set network.uapi59h.suppress_prefixlength=64; uci set network.uapi59h.ipproto=06
	uci set network.uapi59h.uidrange=1000-1005x
	uci commit network; /etc/init.d/network reload"
wait_for "netifd did not install LuCI's rule 30592" \
	'has 30592 ".suppress_prefixlen == 0 and .tos == 16 and .ip_proto == 6 and .dport_range == [443,443]"'
r=$(send PUT network/rules/uapi59l "$(read_back uapi59l)")
[ "$(status "$r")" = 200 ] || fail "PUT of LuCI's rule expected 200: $r"
for o in suppress_prefixlength=0 tos=16 ipproto=6 sport=1000-2000 dport=443 uidrange=1000-1005; do
	[ "$(uci_get "uapi59l.${o%%=*}")" = "${o#*=}" ] || fail "the PUT did not keep $o: $($SSH 'uci -q show network.uapi59l')"
done
wait_for "LuCI's rule left the kernel after the PUT" \
	'has 30592 ".suppress_prefixlen == 0 and .tos == 16 and .ip_proto == 6 and .sport_range == [1000,2000] and .uid_range == [1000,1005]"'

echo "--- a stored value that netifd drops or the kernel refuses reads as stored and blocks no write ---"
for p in 30593 30594 30595 30596 30597 30599; do
	[ -z "$(kernel_rule $p)" ] || fail "the kernel holds rule $p: $(kernel_rule $p)"
done
[ "$(read_back uapi59t | jq -c '.tos')" = 10 ] || fail "tos 10 read wrong: $(read_back uapi59t)"
[ "$(read_back uapi59u | jq -c '.tos')" = 32 ] || fail "tos 32 read wrong: $(read_back uapi59u)"
[ "$(read_back uapi59p | jq -c '.dport')" = '"65535"' ] || fail "dport 65535 read wrong: $(read_back uapi59p)"
[ "$(read_back uapi59x | jq -c '.ipproto')" = 0 ] || fail "ipproto 0 read wrong: $(read_back uapi59x)"
[ "$(read_back uapi59y | jq -c '.ipproto')" = '"sctp"' ] || fail "ipproto sctp read wrong: $(read_back uapi59y)"
r=$(send PUT network/rules/uapi59x "$(read_back uapi59x)")
[ "$(status "$r")" = 200 ] && [ "$(uci_get uapi59x.ipproto)" = 0 ] || fail "PUT of the read of ipproto 0 expected 200 and kept: $r"
r=$(send PATCH network/rules/uapi59u '{"invert":false}')
[ "$(status "$r")" = 200 ] && [ "$(uci_get uapi59u.tos)" = 32 ] || fail "PATCH beside tos 32 expected 200 and kept: $r"
r=$(send PATCH network/rules/uapi59t '{"tos":12}')
[ "$(status "$r")" = 200 ] || fail "PATCH tos 12 expected 200: $r"
wait_for "the kernel did not take tos 12" 'has 30593 ".tos == 12"'
r=$(send PATCH network/rules/uapi59p '{"dport":"65534"}')
[ "$(status "$r")" = 200 ] || fail "PATCH dport 65534 expected 200: $r"
wait_for "the kernel did not take port 65534" 'has 30595 ".dport_range == [65534,65534]"'
r=$(send PATCH network/rules/uapi59y '{"ipproto":17}')
[ "$(status "$r")" = 200 ] || fail "PATCH ipproto 17 expected 200: $r"
wait_for "the kernel did not take ipproto 17" 'has 30597 ".ip_proto == 17"'

echo "--- enabling a rule refuses ipproto 0, which netifd drops, and takes the forms that netifd installs ---"
r=$(send PATCH network/rules/uapi59x '{"disabled":true}')
[ "$(status "$r")" = 200 ] || fail "PATCH that disables the rule with ipproto 0 expected 200: $r"
r=$(send PATCH network/rules/uapi59x '{"disabled":false}')
[ "$(status "$r")" = 422 ] && [ "$(body "$r" | jq -r '[.errors[].field] | join(",")')" = ipproto ] \
	|| fail "enabling the rule with ipproto 0 expected 422 on ipproto: $r"
[ "$(uci_get uapi59x.disabled)" = 1 ] || fail "the refused enable changed the rule"
read_back uapi59h | jq -e '.suppress_prefixlength == 64 and .ipproto == "06" and .uidrange == "1000-1005x"' \
	>/dev/null || fail "the hand-written forms read wrong: $(read_back uapi59h)"
r=$(send PATCH network/rules/uapi59h '{"disabled":false}')
[ "$(status "$r")" = 200 ] || fail "enabling the rule with ipproto 06 expected 200: $r"
wait_for "netifd did not install the hand-written forms as 64, 6 and 1000-1005: $(kernel_rule 30599)" \
	'has 30599 ".suppress_prefixlen == 64 and .ip_proto == 6 and .uid_range == [1000,1005]"'
r=$(send PUT network/rules/uapi59h "$(read_back uapi59h)")
[ "$(status "$r")" = 200 ] && [ "$(uci_get uapi59h.ipproto)" = 06 ] && [ "$(uci_get uapi59h.suppress_prefixlength)" = 64 ] \
	|| fail "PUT of the read of the hand-written forms expected 200 and kept: $r"

echo "--- a write of a value that a write refuses answers 422 and stores nothing ---"
for b in '"tos":10' '"tos":32' '"dport":"0-65535"' '"sport":"2000-1000"' '"ipproto":"tcp"' '"ipproto":0' \
	'"ipproto":256' '"uidrange":"4294967295"' '"suppress_prefixlength":-1' '"suppress_prefixlength":33'; do
	r=$(send POST network/rules "{\"id\":\"uapi59z\",\"src\":\"10.253.78.0/24\",\"lookup\":159,$b}")
	[ "$(status "$r")" = 422 ] || fail "POST with $b expected 422: $r"
	[ -z "$(uci_get uapi59z)" ] || fail "the refused POST with $b stored a section"
done

echo "network rule match options ok"
