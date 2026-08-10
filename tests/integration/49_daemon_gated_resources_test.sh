#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# lldpd and vnstat sit outside the bare image, so until their packages were installed at
# bootstrap every call to these two resources answered 503 and neither had any integration
# coverage. Both carry a 2.5.0 change whose failure mode is at the uci-to-daemon boundary,
# which is exactly what a unit test cannot see: it never runs the init script.
$SSH 'apk info -e lldpd >/dev/null 2>&1 && apk info -e vnstat2 >/dev/null 2>&1' \
	|| fail "lldpd and vnstat2 should have been installed by install_uapi"

echo "--- lldpd/config: lldp_description carries a string to the daemon ---"

# The stock config ships `lldp_description '1'`, which is what the field being typed
# boolean produced: lldpd reads it with config_get and emits it verbatim, so the only
# reachable values were "0" and "1" and the field could never express a description.
DESC="uapi integration probe"
code=$(curl -sS -o /tmp/lldpd_patch.json -w '%{http_code}' -X PATCH -H "$ADMIN" \
	-H 'Content-Type: application/json' \
	-d "{\"lldp_description\":\"$DESC\"}" "$URL/lldpd/config")
[ "$code" = "200" ] || fail "lldp_description PATCH returned $code: $(cat /tmp/lldpd_patch.json)"

got=$(jq -r '.lldp_description' /tmp/lldpd_patch.json)
[ "$got" = "$DESC" ] || fail "response echoed lldp_description as '$got', want '$DESC'"

stored=$($SSH "uci get lldpd.config.lldp_description" 2>/dev/null || true)
[ "$stored" = "$DESC" ] || fail "uci holds lldp_description '$stored', want '$DESC'"

# The daemon-side observable. lldpd.init writes /tmp/lldpd.conf on every reload, whether or
# not the daemon then comes up, so this asserts the value was compiled rather than merely
# stored. A boolean-typed field could only ever have produced `"1"` here.
$SSH "grep -q 'configure system description \"$DESC\"' /tmp/lldpd.conf" \
	|| fail "lldpd.conf does not carry the description: $($SSH 'grep "system description" /tmp/lldpd.conf' 2>&1 || echo '<no such line>')"

echo "--- vnstat/config: interfaces reaches the list vnstat reads ---"

# Device names as the kernel shows them, not uci interface names, so take one the box
# actually has rather than assuming br-lan exists on this image.
DEV=$($SSH "vnstat --iflist 2>/dev/null | sed 's/^Available interfaces: //' | tr ' ' '\n' | grep -v '^lo$' | grep -v '^$' | head -1")
[ -n "$DEV" ] || fail "no device to track: vnstat --iflist returned nothing usable"

code=$(curl -sS -o /tmp/vnstat_patch.json -w '%{http_code}' -X PATCH -H "$ADMIN" \
	-H 'Content-Type: application/json' \
	-d "{\"interfaces\":[\"$DEV\"]}" "$URL/vnstat/config")
[ "$code" = "200" ] || fail "interfaces PATCH returned $code: $(cat /tmp/vnstat_patch.json)"

got=$(jq -r '.interfaces | join(",")' /tmp/vnstat_patch.json)
[ "$got" = "$DEV" ] || fail "response echoed interfaces as '$got', want '$DEV'"

# The list has to land inside the `config vnstat` section, which is the only place the
# init looks (config_foreach init_ifaces vnstat, then config_list_foreach cfg interface).
# The removed endpoint wrote `config interface` sections, which nothing reads, so asserting
# the section type is the point of this check rather than incidental to it.
$SSH "uci show vnstat | grep -q \"^vnstat\\.@vnstat\\[0\\]\\.interface='$DEV'\"" \
	|| fail "not in the vnstat section's list: $($SSH 'uci show vnstat | grep interface' 2>&1 || echo '<no interface option>')"

# The daemon-side observable: the init runs `vnstat --add -i <dev>` for each entry, so the
# device appears in vnstat's own database. That is the difference between uci storing a
# value and vnstat tracking an interface.
$SSH "vnstat --dbiflist 2>/dev/null | grep -q '$DEV'" \
	|| fail "vnstat is not tracking $DEV: $($SSH 'vnstat --dbiflist' 2>&1 || echo '<dbiflist failed>')"

echo "OK: lldpd and vnstat resources reach their daemons"
