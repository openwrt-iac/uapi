#!/bin/sh
# Read-only latency bench. Usage:
#   UAPI_BASE=https://router UAPI_TOKEN=... [N=100] ./tests/bench/bench.sh

set -eu

: "${UAPI_BASE:?UAPI_BASE not set (e.g. https://192.168.10.123)}"
: "${UAPI_TOKEN:?UAPI_TOKEN not set}"
N="${N:-100}"

AUTH_HEADER="Authorization: Bearer ${UAPI_TOKEN}"

endpoints="
/api/v3/healthz
/api/v3/system
/api/v3/network/interfaces
/api/v3/firewall/zones
/api/v3/firewall/rules
/api/v3/dhcp/hosts
/api/v3/dhcp/leases
/api/v3/wireless/devices
"

# Portable p50/p95/p99 over a list of milliseconds (newline-separated, integer).
percentiles() {
	awk '
		{ a[NR] = $1; sum += $1 }
		END {
			n = NR
			if (n == 0) { print "p50=0 p95=0 p99=0"; exit }
			for (i = 1; i <= n; i++) for (j = i+1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
			p50 = a[int(0.50*n)+ (int(0.50*n)<1?1:0)]
			p95 = a[int(0.95*n)+ (int(0.95*n)<1?1:0)]
			p99 = a[int(0.99*n)+ (int(0.99*n)<1?1:0)]
			if (p50 == "") p50 = a[1]
			if (p95 == "") p95 = a[n]
			if (p99 == "") p99 = a[n]
			printf("p50=%dms p95=%dms p99=%dms", p50, p95, p99)
		}
	'
}

printf "uapi bench: %d requests per endpoint against %s\n" "$N" "$UAPI_BASE"
printf "ttfb = server response time (TLS + connect + work).\n"
printf "total = end-to-end with TCP teardown; small responses pay ~40ms Nagle/delayed-ACK on close.\n\n"

overall_fail=0

for ep in $endpoints; do
	# shellcheck disable=SC2086
	ttfb_tmp=$(mktemp)
	total_tmp=$(mktemp)
	fail=0
	i=0
	while [ "$i" -lt "$N" ]; do
		line=$(curl -ks --max-time 10 -H "$AUTH_HEADER" -o /dev/null \
			-w '%{http_code} %{time_starttransfer} %{time_total}' "${UAPI_BASE}${ep}")
		http=$(echo "$line" | awk '{print $1}')
		ttfb_s=$(echo "$line" | awk '{print $2}')
		total_s=$(echo "$line" | awk '{print $3}')
		case "$http" in
			2*) ;;
			*) fail=$((fail+1)) ;;
		esac
		awk -v s="$ttfb_s"  'BEGIN{printf("%d\n", s*1000)}' >> "$ttfb_tmp"
		awk -v s="$total_s" 'BEGIN{printf("%d\n", s*1000)}' >> "$total_tmp"
		i=$((i+1))
	done
	ttfb_pct=$(percentiles < "$ttfb_tmp")
	total_pct=$(percentiles < "$total_tmp")
	printf '  %-32s ttfb: %s   total: %s\n' "$ep" "$ttfb_pct" "$total_pct"
	if [ "$fail" -gt 0 ]; then
		printf '    %d/%d requests failed (non-2xx)\n' "$fail" "$N"
		overall_fail=$((overall_fail + fail))
	fi
	rm -f "$ttfb_tmp" "$total_tmp"
done

if [ "$overall_fail" -gt 0 ]; then
	printf '\nFAIL: %d non-2xx responses total\n' "$overall_fail"
	exit 1
fi

printf '\nOK: all responses 2xx\n'
