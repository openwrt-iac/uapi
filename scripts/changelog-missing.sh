#!/bin/sh
# Lists PRs merged into <base-branch> since <previous-tag> that have neither an entry in
# CHANGELOG.md nor the changelog-not-needed label. <base-branch> defaults to the current branch.
# Run it before a release is tagged. It must print nothing.
set -eu

[ $# -eq 1 ] || [ $# -eq 2 ] || { echo "usage: $0 <previous-tag> [<base-branch>]" >&2; exit 2; }
BASE=${2:-$(git branch --show-current)}
# A release is prepared on a topic branch, which no PR merges into: a sweep of it would list
# nothing and pass. So the name must have the shape of a release line: main, a major line such
# as v3, or a maintenance line such as release/2.5.x.
case $BASE in
main|v[0-9]|v[0-9][0-9]|release/*.x) ;;
*)
	echo "PRs do not merge into '$BASE'. Name the release line: $0 $1 <main|v3|release/X.Y.x>" >&2
	exit 2 ;;
esac
CHANGELOG=${CHANGELOG_FILE:-CHANGELOG.md}
SINCE=$(git log -1 --format=%cI "$1")

# The label is filtered here rather than in --search: the search index picks up a label
# minutes after it is set, so a PR labelled just before the release would still be listed.
# gh runs on its own, not piped into the loop, so that set -e sees it fail: in a pipeline only
# the loop's status counts, and a logged-out gh read as "nothing missing".
prs=$(gh pr list --state merged --base "$BASE" --limit 500 --search "merged:>$SINCE" \
	--json number,labels \
	--jq '.[] | select(all(.labels[]; .name != "changelog-not-needed")) | .number')
missing=$(for n in $prs; do grep -Fq "(#$n)" "$CHANGELOG" || echo "#$n"; done)

[ -z "$missing" ] && exit 0
echo "Merged into $BASE since $1 with no changelog entry and no changelog-not-needed label:" >&2
echo "$missing" >&2
exit 1
