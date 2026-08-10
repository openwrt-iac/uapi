#!/bin/sh
set -eu

# Adoption: the operation an operator meets on any router that was configured before uapi
# arrived. uci names a hand-written section `cfg0a1b2c`, which marks it anonymous; uapi
# reports that as `managed: false` and refuses to write it, because a rename is how it takes
# ownership and doing that silently under a caller who asked for something else is worse than
# refusing. `POST .../adopt` renames the section to a stable id and returns the new one.
#
# Shown on dhcp/hosts because a stock router usually has a static lease or two already, but
# every curated collection behaves the same way.

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with dhcp:hosts:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Find an unmanaged section (managed: false means uci named it anonymously)"
req "$UAPI_BASE/dhcp/hosts" | head -c 600; echo

id=$(req "$UAPI_BASE/dhcp/hosts" \
	| sed 's/},{/}\n{/g' \
	| grep '"managed": *false' \
	| head -1 \
	| sed 's/.*"id": *"\([^"]*\)".*/\1/')

if [ -z "$id" ]; then
	echo
	echo "# No unmanaged section here. Create one the way a hand-edit would, then adopt it:"
	echo "#   uci add dhcp host; uci set dhcp.@host[-1].mac=02:00:00:00:00:01"
	echo "#   uci set dhcp.@host[-1].ip=192.168.1.50; uci commit dhcp"
	exit 0
fi

echo
echo "# Writing it before adoption is refused with 409 unmanaged_resource"
req -o /dev/null -w '%{http_code}\n' -H "$H_JSON" -X PATCH \
	"$UAPI_BASE/dhcp/hosts/$id" -d '{"name":"adopted-by-example"}'

echo
echo "# Adopt: the section is renamed and the response carries the new id"
adopted=$(req -X POST "$UAPI_BASE/dhcp/hosts/$id/adopt")
echo "$adopted" | head -c 400; echo

new_id=$(echo "$adopted" | sed 's/.*"id": *"\([^"]*\)".*/\1/')

echo
echo "# The same write now succeeds"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/dhcp/hosts/$new_id" \
	-d '{"name":"adopted-by-example"}' | head -c 400; echo

echo
echo "# Adoption is one-way: to hand the section back, delete it and recreate it by hand."
echo "# to delete: curl -ksS -H \"Authorization: Bearer \$UAPI_TOKEN\" -X DELETE $UAPI_BASE/dhcp/hosts/$new_id"
