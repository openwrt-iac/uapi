#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
post() { call -X POST -H 'Content-Type: application/json' "$URL/system/cron_jobs" -d "$1"; }

$SSH "rm -f /tmp/uapi-test-crontab.bak; if [ -e /etc/crontabs/root ]; then cp -a /etc/crontabs/root /tmp/uapi-test-crontab.bak; fi"
cleanup() {
	$SSH "if mount | grep -q ' /etc/crontabs '; then /etc/init.d/cron stop; umount /etc/crontabs; fi;
		rm -f /tmp/uapi-test-crontab.full;
		uci revert system.@system[0].cronloglevel; rm -f /etc/crontabs/root;
		if [ -e /tmp/uapi-test-crontab.bak ]; then mv /tmp/uapi-test-crontab.bak /etc/crontabs/root; fi;
		/etc/init.d/cron reload" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Stock OpenWrt ships no crontab, and the init script then does not start crond, so the
# first write is the one that has to bring it up.
$SSH "rm -f /etc/crontabs/root; /etc/init.d/cron reload"

echo "--- system/cron_jobs: empty on a stock box ---"
init=$(call "$URL/system/cron_jobs")
echo "$init" | tail -1 | grep -q '^200$' || fail "list expected 200"
echo "$init" | head -1 | grep -q '^\[ *\]$' || fail "expected an empty list, got: $(echo "$init" | head -1)"

echo "--- system/cron_jobs: first POST starts crond ---"
added=$(post '{"schedule": "*/5 * * * *", "command": "/bin/true"}')
echo "$added" | tail -1 | grep -q '^200$' || fail "add expected 200: $added"
echo "$added" | head -1 | grep -q '"crond_running": true' || fail "crond not running after first add: $added"
jid=$(echo "$added" | head -1 | sed -n 's/.*"id": *"\([a-f0-9]*\)".*/\1/p')
[ -n "$jid" ] || fail "no id in add response"
$SSH "ls -l /etc/crontabs/root" | grep -q '^-rw-------' || fail "crontab not written with mode 0600"

echo "--- system/cron_jobs: same entry again -> 409 ---"
post '{"schedule": "*/5 * * * *", "command": "/bin/true"}' | tail -1 | grep -q '^409$' \
	|| fail "expected 409 on duplicate add"

echo "--- system/cron_jobs: lines crond would misread -> 422 ---"
post '{"schedule": "0 0 * * 7", "command": "/bin/true"}' | tail -1 | grep -q '^422$' \
	|| fail "expected 422 for weekday 7"
post '{"schedule": "0 0 * * *", "command": "echo a#b"}' | tail -1 | grep -q '^422$' \
	|| fail "expected 422 for # in command"
post '{"schedule": "0 0 */2 * *", "command": "/bin/true"}' | tail -1 | grep -q '^422$' \
	|| fail "expected 422 for a stepped * in the day field"
post '{"schedule": "0 0 * * *", "command": "/bin/true", "user": "nobody"}' | head -1 \
	| grep -q '"code": "unknown_field"' || fail "expected unknown_field for an undeclared field"

echo "--- system/cron_jobs: read-only token can list but not add ---"
curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $RO_TOKEN" "$URL/system/cron_jobs" \
	| grep -q '^200$' || fail "read-only list expected 200"
curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $RO_TOKEN" -X POST \
	-H 'Content-Type: application/json' "$URL/system/cron_jobs" -d '{"schedule": "1 * * * *", "command": "/bin/true"}' \
	| grep -q '^403$' || fail "read-only add expected 403"

echo "--- system/cron_jobs: lines from other writers are listed as crond reads them ---"
$SSH "echo '0 0 * * * /etc/init.d/acme renew' >> /etc/crontabs/root;
	printf '%s\n' '# operator note' 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' '	5  4 * * sun   /usr/bin/weekly  # tail' \
		'0 0 * * 7 /usr/bin/sunday' '# hides the next line \\' '* * * * * /usr/bin/hidden' >> /etc/crontabs/root"
list=$(call "$URL/system/cron_jobs" | head -1)
echo "$list" | grep -q '"command": "/etc/init.d/acme renew"' || fail "package line not listed: $list"
echo "$list" | grep -q '"schedule": "5 4 \* \* sun", "command": "/usr/bin/weekly"' \
	|| fail "line not read the way crond reads it: $list"
echo "$list" | grep -q '"command": "/usr/bin/sunday", "runtime": { "crond_running": true, "runs_as_written": false }' \
	|| fail "weekday 7, which crond runs every day, not flagged: $list"
echo "$list" | grep -q '/usr/bin/hidden' && fail "listed a line a trailing backslash hides from crond: $list"

echo "--- system/cron_jobs: an entry appended after a trailing backslash stays its own ---"
$SSH "printf '%s\n' '0 5 * * * /usr/bin/continued \\' >> /etc/crontabs/root"
post '{"schedule": "0 6 * * *", "command": "/usr/bin/after"}' | tail -1 | grep -q '^200$' \
	|| fail "add after a trailing backslash expected 200"
list=$(call "$URL/system/cron_jobs" | head -1)
echo "$list" | grep -q '"command": "/usr/bin/continued"' || fail "the continued line changed: $list"
echo "$list" | grep -q '"command": "/usr/bin/after"' || fail "the appended entry merged into the line before: $list"

echo "--- system/cron_jobs: a delete keeps every other line byte for byte ---"
expected=$($SSH "grep -v '^\*/5 \* \* \* \* /bin/true$' /etc/crontabs/root | md5sum" | cut -d' ' -f1)
del=$(call -X DELETE "$URL/system/cron_jobs/$jid")
echo "$del" | tail -1 | grep -q '^200$' || fail "delete expected 200: $del"
echo "$del" | head -1 | grep -q '"crond_running": true' || fail "delete did not report crond: $del"
actual=$($SSH "md5sum /etc/crontabs/root" | cut -d' ' -f1)
[ "$expected" = "$actual" ] || fail "delete changed lines other than its own"

echo "--- system/cron_jobs: DELETE same id again -> 404 ---"
call -X DELETE "$URL/system/cron_jobs/$jid" | tail -1 | grep -q '^404$' || fail "delete-after-delete expected 404"

echo "--- system/cron_jobs: a write that leaves crond stopped says so ---"
# The init script exits 0 here and procd stops crond, so the reload alone reports success.
$SSH "uci set system.@system[0].cronloglevel=abc"
stopped=$(post '{"schedule": "0 4 * * *", "command": "/bin/true"}')
echo "$stopped" | tail -1 | grep -q '^200$' || fail "add expected 200: $stopped"
echo "$stopped" | head -1 | grep -q '"crond_running": false' || fail "expected crond_running false: $stopped"

echo "--- system/cron_jobs: a write the filesystem cannot hold fails and keeps the old file ---"
# A full overlay used to replace the crontab with an empty file and answer 200: ucode's
# close() drops fclose's error. The filler's name has a dot, so crond ignores it. crond keeps
# its working directory in /etc/crontabs, so it has to stop before the tmpfs can go.
$SSH "uci revert system.@system[0].cronloglevel; /etc/init.d/cron reload;
	cp /etc/crontabs/root /tmp/uapi-test-crontab.full;
	mount -t tmpfs -o size=8k tmpfs /etc/crontabs;
	cp /tmp/uapi-test-crontab.full /etc/crontabs/root;
	dd if=/dev/zero of=/etc/crontabs/fill.x bs=1k count=64 2>/dev/null; true"
before=$($SSH "md5sum < /etc/crontabs/root")
full=$(post '{"schedule": "0 5 * * *", "command": "/usr/bin/a-command-long-enough-to-need-a-new-block --with --several --arguments"}')
after=$($SSH "md5sum < /etc/crontabs/root; ls /etc/crontabs | grep -c uapi.tmp;
	/etc/init.d/cron stop; umount /etc/crontabs; /etc/init.d/cron start")
echo "$full" | tail -1 | grep -q '^500$' || fail "expected 500 on a full filesystem: $full"
[ "$(echo "$after" | head -1)" = "$before" ] || fail "the crontab changed although the write failed"
[ "$(echo "$after" | sed -n 2p)" = "0" ] || fail "the temp file was left behind"

echo "system/cron_jobs ok."
