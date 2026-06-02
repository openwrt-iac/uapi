#!/bin/sh
# CI soak: read-only load against the QEMU integration VM with RSS/fd tracking.
# Fails on >0 non-2xx, RSS growth >10MB, or fd-count growth >5 over DURATION.
set -eu

cd "$(dirname "$0")/../.."

DURATION="${DURATION:-60}"
PARALLEL="${PARALLEL:-2}"
UAPI_BASE="${UAPI_BASE:-http://127.0.0.1:8080}"
SSH="${SSH:-tests/vm/ssh.sh}"

$SSH 'uapi-token revoke ci_soak >/dev/null 2>&1' || true
TOKEN=$($SSH 'uapi-token create --name ci_soak --scope "*:ro" 2>/dev/null' | head -1)
[ -n "$TOKEN" ] || { echo "FAIL: could not mint soak token"; exit 1; }

tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir; $SSH 'uapi-token revoke ci_soak >/dev/null 2>&1' || true" EXIT

deadline=$(($(date +%s) + DURATION))
endpoints="/api/v1/healthz /api/v1/system /api/v1/firewall/zones /api/v1/network/interfaces /api/v1/dhcp/hosts"

sample_proc() {
	$SSH '
		pid=$(cat /var/run/uhttpd.pid 2>/dev/null || pgrep -x uhttpd | head -1)
		[ -z "$pid" ] && { echo "0 0 0"; exit; }
		rss=$(awk "/^VmRSS:/{print \$2}" /proc/$pid/status 2>/dev/null || echo 0)
		fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
		kids=$(pgrep -c -P $pid 2>/dev/null || echo 0)
		echo "$rss $fds $kids"
	' 2>/dev/null
}

(
	while [ "$(date +%s)" -lt "$deadline" ]; do
		out=$(sample_proc)
		echo "$(date +%s) $out" >> "$tmpdir/leak.dat"
		sleep 10
	done
) &

i=0
while [ "$i" -lt "$PARALLEL" ]; do
	(
		ok=0; fail=0
		while [ "$(date +%s)" -lt "$deadline" ]; do
			for ep in $endpoints; do
				code=$(curl -ks --max-time 10 -o /dev/null -w '%{http_code}' \
					-H "Authorization: Bearer $TOKEN" "$UAPI_BASE$ep" || echo 000)
				case "$code" in 2*) ok=$((ok+1)) ;; *) fail=$((fail+1)) ;; esac
			done
		done
		echo "$ok $fail" > "$tmpdir/w$i"
	) &
	i=$((i+1))
done
wait

total_ok=0; total_fail=0
for f in "$tmpdir"/w*; do
	read ok fail < "$f"
	total_ok=$((total_ok + ok))
	total_fail=$((total_fail + fail))
done

first_rss=$(awk '$2+0 > 0 {print $2; exit}' "$tmpdir/leak.dat")
last_rss=$(awk '$2+0 > 0 {l=$2} END{print l+0}' "$tmpdir/leak.dat")
first_fd=$(awk '$3+0 > 0 {print $3; exit}' "$tmpdir/leak.dat")
last_fd=$(awk '$3+0 > 0 {l=$3} END{print l+0}' "$tmpdir/leak.dat")

rss_growth=$((${last_rss:-0} - ${first_rss:-0}))
fd_growth=$((${last_fd:-0} - ${first_fd:-0}))

printf 'soak: ok=%d fail=%d duration=%ds rps_avg=%d\n' \
	"$total_ok" "$total_fail" "$DURATION" "$((total_ok / DURATION))"
printf 'rss: first=%skB last=%skB growth=%dkB\n' "$first_rss" "$last_rss" "$rss_growth"
printf 'fd:  first=%s last=%s growth=%d\n'      "$first_fd"  "$last_fd"  "$fd_growth"

exit_code=0
[ "$total_fail" -eq 0 ]   || { echo "FAIL: $total_fail non-2xx responses"; exit_code=1; }
[ "$rss_growth" -le 10240 ] || { echo "FAIL: RSS grew ${rss_growth}kB > 10MB threshold"; exit_code=1; }
[ "$fd_growth" -le 5 ]    || { echo "FAIL: fd count grew $fd_growth > 5 threshold"; exit_code=1; }
exit $exit_code
