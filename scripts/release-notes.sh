#!/bin/sh
# Print the CHANGELOG.md section body for the given tag.
# Lookup order: exact version, version with pre-release suffix stripped,
# Unreleased. Empty stdout (exit 0) if nothing matched, so callers can
# fall back to gh's --generate-notes.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <tag>" >&2; exit 2; }
TAG=$1
CHANGELOG=${CHANGELOG_FILE:-CHANGELOG.md}
[ -r "$CHANGELOG" ] || exit 0

VER=${TAG#v}
STRIPPED=${VER%-*}
[ "$STRIPPED" = "$VER" ] && STRIPPED=

extract() {
  awk -v key="$1" '
    $0 ~ "^## \\[" key "\\]" { in_section=1; next }
    in_section && /^## \[/   { exit }
    in_section               { lines[++n]=$0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      start = 1
      while (start <= n && lines[start] ~ /^[[:space:]]*$/) start++
      for (i=start; i<=n; i++) print lines[i]
    }
  ' "$CHANGELOG"
}

for key in "$VER" "$STRIPPED" "Unreleased"; do
  [ -n "$key" ] || continue
  body=$(extract "$key")
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
    exit 0
  fi
done
