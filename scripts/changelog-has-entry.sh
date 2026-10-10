#!/bin/sh
# Exits 0 when the [Unreleased] section of CHANGELOG.md has an entry ending in (#<pr>).
# The parentheses keep #19 from matching an entry for #193.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <pr-number>" >&2; exit 2; }
PR=$1
CHANGELOG=${CHANGELOG_FILE:-CHANGELOG.md}

if awk '/^## \[Unreleased\]/ { on = 1; next } on && /^## \[/ { exit } on' "$CHANGELOG" \
	| grep -Fq "(#$PR)"; then
	exit 0
fi
echo "$CHANGELOG has no entry ending in (#$PR) under ## [Unreleased]." >&2
echo "Add one, or label the PR changelog-not-needed if nothing outside the repo changes." >&2
echo "Rules: docs/release-process.md, section Changelog." >&2
exit 1
