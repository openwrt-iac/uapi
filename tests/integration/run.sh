#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

passed=0
failed=0
failures=""

for test in tests/integration/*_test.sh; do
	[ -f "$test" ] || continue
	name=$(basename "$test" .sh)
	printf "\n[%s]\n" "$name"
	if sh "$test"; then
		passed=$((passed + 1))
	else
		failed=$((failed + 1))
		failures="$failures $name"
	fi
done

printf "\n%d passed, %d failed\n" "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
	printf "Failures:%s\n" "$failures"
	exit 1
fi
