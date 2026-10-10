#!/bin/sh
# Issues and PRs share one counter, so an issue opened before the PR makes this guess wrong,
# and the changelog check then fails until the entry carries the real number.
set -eu

last=$(gh api "repos/{owner}/{repo}/issues?state=all&per_page=1&sort=created&direction=desc" \
	--jq '.[0].number')
echo $((last + 1))
