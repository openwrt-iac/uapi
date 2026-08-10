#!/bin/sh
# Read-only long-duration load test. Usage:
#   UAPI_BASE=https://router UAPI_TOKEN=... [ROUTER_SSH=root@router] \
#     [DURATION=600] [PARALLEL=4] ./tests/soak/soak.sh
# ROUTER_SSH enables a side-channel RSS/fd/child sampler over SSH.

set -eu

: "${UAPI_BASE:?UAPI_BASE not set}"
: "${UAPI_TOKEN:?UAPI_TOKEN not set}"
DURATION="${DURATION:-600}"
PARALLEL="${PARALLEL:-4}"
ROUTER_SSH="${ROUTER_SSH:-}"

endpoints="
/api/v3/healthz
/api/v3/system
/api/v3/network/interfaces
/api/v3/firewall/zones
/api/v3/firewall/rules
/api/v3/dhcp/hosts
/api/v3/dhcp/leases
"

trap 'kill $(jobs -p) 2>/dev/null; exit' INT TERM

# Worker: loops until deadline, counts requests + failures into a tally file.
worker() {
	deadline=$1
	tally=$2
	ok=0
	fail=0
	while [ "$(date +%s)" -lt "$deadline" ]; do
		for ep in $endpoints; do
			code=$(curl -ks --max-time 10 -o /dev/null -w '%{http_code}' \
				-H "Authorization: Bearer ${UAPI_TOKEN}" "${UAPI_BASE}${ep}" || echo 000)
			case "$code" in
				2*) ok=$((ok+1)) ;;
				*)  fail=$((fail+1)) ;;
			esac
		done
	done
	echo "${ok} ${fail}" > "$tally"
}

# Sampler: every 60s, capture RSS + open-fds + child-count on the router.
sampler() {
	deadline=$1
	report=$2
	{
		printf '# t  rss_kb  fd_count  child_count\n'
		while [ "$(date +%s)" -lt "$deadline" ]; do
			t=$(date +%s)
			# Stock OpenWrt does not write /var/run/uhttpd.pid and busybox
			# pgrep lacks -c. Multiple uhttpd instances are common (main +
			# LuCI bridge); pick the one whose cmdline references the uapi
			# handler script.
			out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER_SSH" '
				pid=""
				for p in $(pidof uhttpd 2>/dev/null); do
					grep -q /usr/share/uapi/main.uc /proc/$p/cmdline 2>/dev/null \
						&& { pid=$p; break; }
				done
				[ -z "$pid" ] && pid=$(pidof uhttpd 2>/dev/null | awk "{print \$1}")
				if [ -z "$pid" ]; then echo "0 0 0"; exit; fi
				rss=$(awk "/^VmRSS:/{print \$2}" /proc/$pid/status 2>/dev/null || echo 0)
				fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
				kids=$(pgrep -P $pid 2>/dev/null | wc -l)
				echo "$rss $fds $kids"
			' 2>/dev/null || echo "0 0 0")
			printf '%d  %s\n' "$t" "$out"
			sleep 60
		done
	} > "$report"
}

deadline=$(($(date +%s) + DURATION))
tmpdir=$(mktemp -d)

printf 'soak start: duration=%ds parallel=%d base=%s\n' \
	"$DURATION" "$PARALLEL" "$UAPI_BASE"

if [ -n "$ROUTER_SSH" ]; then
	sampler "$deadline" "$tmpdir/leak.dat" &
	sampler_pid=$!
else
	sampler_pid=""
fi

i=0
while [ "$i" -lt "$PARALLEL" ]; do
	worker "$deadline" "$tmpdir/w$i.tally" &
	i=$((i+1))
done

wait
[ -n "$sampler_pid" ] && wait "$sampler_pid" 2>/dev/null || true

total_ok=0
total_fail=0
for f in "$tmpdir"/w*.tally; do
	[ -e "$f" ] || continue
	read ok fail < "$f"
	total_ok=$((total_ok + ok))
	total_fail=$((total_fail + fail))
done

printf '\nsoak done: ok=%d fail=%d rps_avg=%d\n' \
	"$total_ok" "$total_fail" \
	"$((total_ok / DURATION))"

if [ -f "$tmpdir/leak.dat" ]; then
	printf '\nleak watch (uhttpd main process):\n'
	cat "$tmpdir/leak.dat"
	# crude verdict: compare first valid sample to last
	# Force numeric compare so the "# t rss_kb ..." header (where $2 == "t")
	# doesn't satisfy the awk truthiness check and pollute $first with "t".
	first=$(awk '$2+0 > 0 {print $2+0; exit}' "$tmpdir/leak.dat" || echo 0)
	last=$(awk '$2+0 > 0 {l=$2+0} END{print l+0}' "$tmpdir/leak.dat")
	if [ "$first" -gt 0 ] && [ "$last" -gt 0 ]; then
		grew=$(awk -v a="$first" -v b="$last" 'BEGIN{printf("%d", (b-a)*100/a)}')
		printf '\nRSS first=%dkB last=%dkB (%d%% change)\n' "$first" "$last" "$grew"
	fi
fi

rm -rf "$tmpdir"
[ "$total_fail" -eq 0 ] || exit 1
