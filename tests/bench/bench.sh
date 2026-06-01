#!/bin/sh
# uapi performance benchmark, read-only.
#
# Hits a handful of representative GET endpoints in tight loops and reports
# min / median / p95 / p99 / max latency per endpoint. Intentionally read-only:
# safe to run against the live router (no writes, no state changes).
#
# Usage:
#   UAPI_BASE=https://192.168.10.123 UAPI_TOKEN=... ./tests/bench/bench.sh
#   UAPI_BASE=... UAPI_TOKEN=... N=200 ./tests/bench/bench.sh  # override count
#
# Output: one block per endpoint with the latency distribution. Exits 1 on
# any non-2xx response.

set -eu

: "${UAPI_BASE:?UAPI_BASE not set (e.g. https://192.168.10.123)}"
: "${UAPI_TOKEN:?UAPI_TOKEN not set}"
N="${N:-100}"

CURL="curl -ks --max-time 10 -H Authorization:Bearer\ ${UAPI_TOKEN} -o /dev/null -w %{http_code}\ %{time_total}\n"

endpoints="
/api/v1/healthz
/api/v1/system
/api/v1/network/interfaces
/api/v1/firewall/zones
/api/v1/firewall/rules
/api/v1/dhcp/hosts
/api/v1/dhcp/leases
/api/v1/wireless/devices
"

# Portable p50/p95/p99 over a list of milliseconds (newline-separated, integer).
percentiles() {
	awk '
		{ a[NR] = $1; sum += $1 }
		END {
			n = NR
			if (n == 0) { print "0 0 0 0 0 0"; exit }
			# sort
			for (i = 1; i <= n; i++) for (j = i+1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
			min = a[1]; max = a[n]; mean = sum / n
			p50 = a[int(0.50*n)+ (int(0.50*n)<1?1:0)]
			p95 = a[int(0.95*n)+ (int(0.95*n)<1?1:0)]
			p99 = a[int(0.99*n)+ (int(0.99*n)<1?1:0)]
			if (p50 == "") p50 = a[1]
			if (p95 == "") p95 = a[n]
			if (p99 == "") p99 = a[n]
			printf("min=%dms p50=%dms p95=%dms p99=%dms max=%dms mean=%dms\n", min, p50, p95, p99, max, mean)
		}
	'
}

printf "uapi bench: %d requests per endpoint against %s\n\n" "$N" "$UAPI_BASE"

overall_fail=0

for ep in $endpoints; do
	# shellcheck disable=SC2086
	tmp=$(mktemp)
	fail=0
	i=0
	while [ "$i" -lt "$N" ]; do
		# shellcheck disable=SC2086
		line=$($CURL "${UAPI_BASE}${ep}")
		http=${line%% *}
		secs=${line##* }
		case "$http" in
			2*) ;;
			*) fail=$((fail+1)) ;;
		esac
		# multiply seconds float by 1000 -> ms integer (no bc dependency)
		ms=$(awk -v s="$secs" 'BEGIN{printf("%d\n", s*1000)}')
		printf '%d\n' "$ms" >> "$tmp"
		i=$((i+1))
	done
	printf '  %-32s ' "$ep"
	percentiles < "$tmp"
	if [ "$fail" -gt 0 ]; then
		printf '    %d/%d requests failed (non-2xx)\n' "$fail" "$N"
		overall_fail=$((overall_fail + fail))
	fi
	rm -f "$tmp"
done

if [ "$overall_fail" -gt 0 ]; then
	printf '\nFAIL: %d non-2xx responses total\n' "$overall_fail"
	exit 1
fi

printf '\nOK: all responses 2xx\n'
