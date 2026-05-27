#!/bin/sh
set -eu

SSH="tests/vm/ssh.sh"

PREFIX_ENTRY="/_probe=/usr/share/uapi/probe_concurrency.uc"

push_file() {
	$SSH "cat > $2" < "$1"
}

cleanup() {
	$SSH "uci -q del_list uhttpd.main.ucode_prefix='$PREFIX_ENTRY' || true; uci -q commit uhttpd; /etc/init.d/uhttpd restart" || true
}
trap cleanup EXIT INT TERM

echo "--- install uhttpd-mod-ucode in the VM ---"
$SSH 'apk update 2>&1 | tail -3'
$SSH 'apk add uhttpd-mod-ucode 2>&1 | tail -10'

echo "--- deploy probe ---"
$SSH 'mkdir -p /usr/share/uapi'
push_file tests/integration/probes/concurrency.uc /usr/share/uapi/probe_concurrency.uc
$SSH 'ls -la /usr/share/uapi/'

echo "--- wire uhttpd prefix ---"
$SSH "uci -q del_list uhttpd.main.ucode_prefix='$PREFIX_ENTRY' || true"
$SSH "uci add_list uhttpd.main.ucode_prefix='$PREFIX_ENTRY'"
$SSH "uci commit uhttpd"
$SSH "uci show uhttpd | grep ucode_prefix || true"

echo "--- restart uhttpd ---"
$SSH "/etc/init.d/uhttpd restart 2>&1 || true; echo restart-exit-$?"
sleep 3
echo "--- uhttpd process state ---"
$SSH 'pgrep -a uhttpd || echo "uhttpd NOT running"'
$SSH 'logread | tail -20 | grep -i uhttpd || true'
$SSH 'ls -la /usr/lib/uhttpd_*.so 2>/dev/null || echo "no uhttpd plugins found"'

echo "--- sanity check: single verbose request ---"
curl -sS -v --max-time 10 http://127.0.0.1:8080/_probe 2>&1 | tail -25 || true

echo "--- 5 concurrent requests ---"
rm -rf /tmp/probe_results
mkdir /tmp/probe_results

start=$(date +%s.%N)
for i in 1 2 3 4 5; do
	curl -sS --max-time 15 http://127.0.0.1:8080/_probe > "/tmp/probe_results/r$i" &
done
wait
end=$(date +%s.%N)

elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }')

echo "elapsed: ${elapsed}s"
echo "responses:"
cat /tmp/probe_results/r*
echo

counts=$(cat /tmp/probe_results/r* | grep -oE '"count":[0-9]+' | sed 's/[^0-9]//g' | sort -n | paste -sd,)
pids=$(cat /tmp/probe_results/r* | grep -oE '"pid":[0-9]+' | sed 's/[^0-9]//g' | sort -u | paste -sd,)
pid_count=$(echo "$pids" | tr ',' '\n' | grep -c .)

echo "counters seen: $counts"
echo "distinct PIDs (count=$pid_count): $pids"

fail=0

if echo "$counts" | grep -qE '[^1,]'; then
	echo "ASSERT FAIL: not every response showed count=1 (got $counts)"
	fail=1
fi

if [ "$pid_count" -lt 2 ]; then
	echo "ASSERT FAIL: expected multiple distinct PIDs (forks), got $pid_count"
	fail=1
fi

# uhttpd caps concurrent CGI children at max_requests (default 3), so 5 in-flight
# requests can take up to two batches of ~1s.
if ! awk -v e="$elapsed" 'BEGIN { exit !(e >= 0.5 && e <= 4.0) }'; then
	echo "ASSERT FAIL: wall time ${elapsed}s outside expected range 0.5-4.0"
	fail=1
fi

rm -rf /tmp/probe_results

if [ "$fail" -ne 0 ]; then
	echo
	echo "Concurrency model assertion failed. CLAUDE.md \"Concurrency\" claims are"
	echo "inconsistent with observed behavior. Either CLAUDE.md or this test must change."
	exit 1
fi

echo
echo "Concurrency model matches CLAUDE.md expectations (fork-per-request CGI)."
