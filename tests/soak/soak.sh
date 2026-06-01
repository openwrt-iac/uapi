#!/bin/sh
# uapi soak test, long-duration, read-only.
#
# Hammers a mix of read endpoints in parallel for DURATION seconds. Watches
# the uhttpd process from a side channel (SSH) to surface obvious leaks:
# resident set growth, fd count growth, child accumulation. Read-only so it
# is safe against the live router.
#
# Usage:
#   UAPI_BASE=https://192.168.10.123 UAPI_TOKEN=... ROUTER_SSH=root@192.168.10.123 \
#     DURATION=1800 PARALLEL=4 ./tests/soak/soak.sh
#
# Defaults: DURATION=600 (10 min), PARALLEL=4.
# If ROUTER_SSH is empty, the leak-watch side channel is skipped; the load
# loop still runs and reports request counts and error totals.

set -eu

: "${UAPI_BASE:?UAPI_BASE not set}"
: "${UAPI_TOKEN:?UAPI_TOKEN not set}"
DURATION="${DURATION:-600}"
PARALLEL="${PARALLEL:-4}"
ROUTER_SSH="${ROUTER_SSH:-}"

endpoints="
/api/v1/healthz
/api/v1/system
/api/v1/network/interfaces
/api/v1/firewall/zones
/api/v1/firewall/rules
/api/v1/dhcp/hosts
/api/v1/dhcp/leases
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
			# uhttpd's main pid: read from /var/run.
			out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER_SSH" '
				pid=$(cat /var/run/uhttpd.pid 2>/dev/null || pgrep -x uhttpd | head -1)
				if [ -z "$pid" ]; then echo "0 0 0"; exit; fi
				rss=$(awk "/^VmRSS:/{print \$2}" /proc/$pid/status 2>/dev/null || echo 0)
				fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
				kids=$(pgrep -c -P $pid 2>/dev/null || echo 0)
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
	first=$(awk '$2 > 0 {print $2; exit}' "$tmpdir/leak.dat" || echo 0)
	last=$(awk '$2 > 0 {l=$2} END{print l+0}' "$tmpdir/leak.dat")
	if [ "$first" -gt 0 ] && [ "$last" -gt 0 ]; then
		grew=$(awk -v a="$first" -v b="$last" 'BEGIN{printf("%d", (b-a)*100/a)}')
		printf '\nRSS first=%dkB last=%dkB (%d%% change)\n' "$first" "$last" "$grew"
	fi
fi

rm -rf "$tmpdir"
[ "$total_fail" -eq 0 ] || exit 1
