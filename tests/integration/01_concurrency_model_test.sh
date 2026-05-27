#!/bin/sh
set -eu

SSH="tests/vm/ssh.sh"

PREFIX_ENTRY="/_probe=/usr/share/uapi/probe_serialize.uc"

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
push_file tests/integration/probes/serialize.uc /usr/share/uapi/probe_serialize.uc
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

if [ "$counts" != "1,2,3,4,5" ]; then
	echo "ASSERT FAIL: counters not 1,2,3,4,5"
	fail=1
fi

if [ "$pid_count" -ne 1 ]; then
	echo "ASSERT FAIL: expected single PID (persistent handler), got $pid_count distinct"
	fail=1
fi

if ! awk -v e="$elapsed" 'BEGIN { exit !(e >= 4.5 && e <= 6.5) }'; then
	echo "ASSERT FAIL: wall time ${elapsed}s not between 4.5 and 6.5"
	fail=1
fi

rm -rf /tmp/probe_results

if [ "$fail" -ne 0 ]; then
	echo
	echo "Spike A failed. The CLAUDE.md Concurrency claim (persistent handler, in-loop"
	echo "serialization, no flock) is invalidated by this run."
	exit 1
fi

echo
echo "Spike A passed: persistent handler, serialized in-process, no flock needed."
