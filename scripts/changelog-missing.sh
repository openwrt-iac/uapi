#!/bin/sh
# Lists PRs merged into main since <previous-tag> that have neither an entry in CHANGELOG.md
# nor the changelog-not-needed label. Run before a release is tagged; it must print nothing.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <previous-tag>" >&2; exit 2; }
CHANGELOG=${CHANGELOG_FILE:-CHANGELOG.md}
SINCE=$(git log -1 --format=%cI "$1")

# The label is filtered here rather than in --search: the search index picks up a label
# minutes after it is set, so a PR labelled just before the release would still be listed.
missing=$(gh pr list --state merged --base main --limit 500 --search "merged:>$SINCE" \
	--json number,labels \
	--jq '.[] | select(all(.labels[]; .name != "changelog-not-needed")) | .number' \
	| while read -r n; do grep -Fq "(#$n)" "$CHANGELOG" || echo "#$n"; done)

[ -z "$missing" ] && exit 0
echo "Merged since $1 with no changelog entry and no changelog-not-needed label:" >&2
echo "$missing" >&2
exit 1
