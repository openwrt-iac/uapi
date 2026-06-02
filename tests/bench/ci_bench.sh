#!/bin/sh
# CI perf bench: measures per-endpoint latency, emits structured JSON to
# bench/run-<sha>.json. If bench/baseline.json exists, compares p99 per
# endpoint and fails on >REGRESSION_PCT% regression (default 25).
set -eu

cd "$(dirname "$0")/../.."

N="${N:-50}"
REGRESSION_PCT="${REGRESSION_PCT:-25}"
UAPI_BASE="${UAPI_BASE:-http://127.0.0.1:8080}"
SSH="${SSH:-tests/vm/ssh.sh}"

TOKEN=$($SSH 'uapi-token create --name ci_bench --scope "*:ro" 2>/dev/null' | head -1)
[ -n "$TOKEN" ] || { echo "FAIL: could not mint bench token"; exit 1; }

tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir; $SSH 'uapi-token revoke ci_bench >/dev/null 2>&1' || true" EXIT

endpoints="/api/v1/healthz /api/v1/system /api/v1/firewall/zones /api/v1/firewall/rules /api/v1/network/interfaces /api/v1/dhcp/hosts /api/v1/wireless/devices"

mkdir -p bench
SHA="${GITHUB_SHA:-local}"
OUT="bench/run-${SHA}.json"

printf '{\n  "sha": "%s",\n  "n": %d,\n  "endpoints": {\n' "$SHA" "$N" > "$OUT"
first=1
for ep in $endpoints; do
	tmp=$(mktemp)
	i=0
	while [ "$i" -lt "$N" ]; do
		secs=$(curl -ks --max-time 10 -o /dev/null -w '%{time_total}' \
			-H "Authorization: Bearer $TOKEN" "$UAPI_BASE$ep")
		awk -v s="$secs" 'BEGIN{printf("%d\n", s*1000)}' >> "$tmp"
		i=$((i+1))
	done
	stats=$(awk '
		{ a[NR]=$1 }
		END {
			n=NR
			for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (a[j]<a[i]) { t=a[i]; a[i]=a[j]; a[j]=t }
			p50=a[int(0.50*n)+1]; p95=a[int(0.95*n)+1]; p99=a[int(0.99*n)+1]
			if (p99=="") p99=a[n]
			printf("%d %d %d %d %d", a[1], p50, p95, p99, a[n])
		}
	' "$tmp")
	read mn p50 p95 p99 mx <<EOF
$stats
EOF
	[ "$first" -eq 1 ] || printf ',\n' >> "$OUT"
	first=0
	printf '    "%s": { "min_ms": %d, "p50_ms": %d, "p95_ms": %d, "p99_ms": %d, "max_ms": %d }' \
		"$ep" "$mn" "$p50" "$p95" "$p99" "$mx" >> "$OUT"
	rm -f "$tmp"
done
printf '\n  }\n}\n' >> "$OUT"

echo "wrote $OUT"
cat "$OUT"

if [ ! -f bench/baseline.json ]; then
	echo "no bench/baseline.json yet; skipping regression check (run will be the seed)"
	exit 0
fi

echo
echo "regression check vs bench/baseline.json (threshold: ${REGRESSION_PCT}%)"
fail=0
for ep in $endpoints; do
	cur=$(awk -v e="$ep" '
		$0 ~ "\""e"\"" { match($0, /"p99_ms":[[:space:]]*[0-9]+/); print substr($0, RSTART+9, RLENGTH-9); exit }
	' "$OUT" | tr -d ' ')
	base=$(awk -v e="$ep" '
		$0 ~ "\""e"\"" { match($0, /"p99_ms":[[:space:]]*[0-9]+/); print substr($0, RSTART+9, RLENGTH-9); exit }
	' bench/baseline.json | tr -d ' ')
	[ -n "$base" ] || { printf '  %-32s no baseline (skipped)\n' "$ep"; continue; }
	# Allow up to REGRESSION_PCT% growth.
	max_allowed=$((base + base * REGRESSION_PCT / 100))
	# Add a 5ms floor so noise around sub-millisecond endpoints doesn't false-fail.
	[ "$max_allowed" -lt $((base + 5)) ] && max_allowed=$((base + 5))
	if [ "$cur" -gt "$max_allowed" ]; then
		printf '  [FAIL] %-30s p99 %dms > baseline %dms +%d%% (allowed %dms)\n' \
			"$ep" "$cur" "$base" "$REGRESSION_PCT" "$max_allowed"
		fail=$((fail+1))
	else
		printf '  [ok]   %-30s p99 %dms (baseline %dms, allowed %dms)\n' \
			"$ep" "$cur" "$base" "$max_allowed"
	fi
done

[ "$fail" -eq 0 ] || { echo "FAIL: $fail endpoint(s) regressed"; exit 1; }
