#!/bin/sh
# Lists PRs merged into <branch> since <previous-tag> that have neither an entry in CHANGELOG.md
# nor the changelog-not-needed label. Run before a release is tagged, with the branch that the
# release tags: main, or v3 for 3.x. It must print nothing.
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <previous-tag> <branch>" >&2; exit 2; }
CHANGELOG=${CHANGELOG_FILE:-CHANGELOG.md}
SINCE=$(git log -1 --format=%cI "$1")

# The label is filtered here rather than in --search: the search index picks up a label
# minutes after it is set, so a PR labelled just before the release would still be listed.
# gh runs on its own, not piped into the loop, so that set -e sees it fail: in a pipeline only
# the loop's status counts, and a logged-out gh read as "nothing missing".
prs=$(gh pr list --state merged --base "$2" --limit 500 --search "merged:>$SINCE" \
	--json number,labels \
	--jq '.[] | select(all(.labels[]; .name != "changelog-not-needed")) | .number')
missing=$(for n in $prs; do grep -Fq "(#$n)" "$CHANGELOG" || echo "#$n"; done)

[ -z "$missing" ] && exit 0
echo "Merged into $2 since $1 with no changelog entry and no changelog-not-needed label:" >&2
echo "$missing" >&2
exit 1
