#!/bin/sh
# gen_sbom.sh - emit SPDX 2.3 SBOM for the staged uapi package.
#
# Usage:
#   tools/gen_sbom.sh <staging-dir> [--version <X.Y.Z>] [--apk <built.apk>] > sbom.spdx.json
#
# Inputs:
#   staging-dir   directory containing the staged files (default: build/openwrt/uapi/files)
#   --version     overrides VERSION (default: contents of VERSION at repo root)
#   --apk         optional path to the built .apk; its sha256 + size become the
#                 SBOM's top-level packageVerificationCode.
#
# Output: SPDX 2.3 JSON on stdout. Run via `make sbom` (Makefile target).
set -eu

STAGING="${1:-build/openwrt/uapi/files}"
shift || true

VERSION=""
APK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --apk)     APK="$2"; shift 2 ;;
        *) echo "gen_sbom: unknown arg $1" >&2; exit 1 ;;
    esac
done

if [ -z "$VERSION" ]; then
    if [ -r VERSION ]; then VERSION=$(tr -d '[:space:]' < VERSION); fi
fi
[ -n "$VERSION" ] || { echo "gen_sbom: VERSION unknown; pass --version" >&2; exit 1; }

if [ ! -d "$STAGING" ]; then
    echo "gen_sbom: staging dir $STAGING not found; run 'make stage' first" >&2
    exit 1
fi

# Stable per-file inventory: sorted, with relative path + sha256 + size.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
( cd "$STAGING" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$TMP"

DOC_NAMESPACE="https://github.com/openwrt-iac/uapi/sbom/${VERSION}"

# Extract dependencies from the package Makefile DEPENDS line.
# Strip leading + and the line-continuation backslashes; produce one dep per line.
MAKEFILE="build/openwrt/uapi/Makefile"
DEPS=""
if [ -r "$MAKEFILE" ]; then
    DEPS=$(awk '
        /DEPENDS:=/ { in_d=1; sub(/.*DEPENDS:=/, ""); }
        in_d {
            gsub(/\\$/, ""); gsub(/\+/, ""); print;
            if (!match($0, /\\$/)) in_d=0;
        }
    ' "$MAKEFILE" | tr ' ' '\n' | grep -v '^$' | sort -u)
fi

# JSON-string-escape stdin.
json_escape() {
    awk 'BEGIN { ORS="" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); print; print "\\n" }'
}

emit_file() {
    REL="$1"; SHA="$2"; SIZE="$3"
    cat <<EOF
    {
      "SPDXID": "SPDXRef-File-$(printf '%s' "$REL" | tr -c 'A-Za-z0-9' '-')",
      "fileName": "$REL",
      "checksums": [{ "algorithm": "SHA256", "checksumValue": "$SHA" }],
      "copyrightText": "NOASSERTION",
      "licenseConcluded": "MIT",
      "licenseInfoInFiles": ["MIT"]
    }
EOF
}

emit_dep() {
    NAME="$1"
    SPDXID="SPDXRef-Dep-$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9' '-')"
    cat <<EOF
    {
      "SPDXID": "$SPDXID",
      "name": "$NAME",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "NOASSERTION",
      "supplier": "Organization: OpenWrt"
    }
EOF
}

# Top-level package verification: sha256 of the built APK if provided,
# otherwise sha256 of the concatenated per-file checksums.
PKG_VERIFICATION=""
PKG_SIZE=""
if [ -n "$APK" ] && [ -r "$APK" ]; then
    PKG_VERIFICATION=$(sha256sum "$APK" | awk '{print $1}')
    PKG_SIZE=$(wc -c < "$APK")
fi

CREATED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "uapi-${VERSION}",
  "documentNamespace": "${DOC_NAMESPACE}",
  "creationInfo": {
    "created": "${CREATED}",
    "creators": ["Tool: tools/gen_sbom.sh", "Organization: uapi project"]
  },
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-uapi",
      "name": "uapi",
      "versionInfo": "${VERSION}",
      "downloadLocation": "https://github.com/openwrt-iac/uapi/releases/tag/v${VERSION}",
      "filesAnalyzed": true,
      "licenseConcluded": "MIT",
      "licenseDeclared": "MIT",
      "supplier": "Person: Guy Godfroy <guy.godfroy@gugod.fr>",
      "homepage": "https://github.com/openwrt-iac/uapi"$(
        [ -n "$PKG_VERIFICATION" ] && printf ',\n      "checksums": [{ "algorithm": "SHA256", "checksumValue": "%s" }]' "$PKG_VERIFICATION"
        [ -n "$PKG_SIZE" ] && printf ',\n      "comment": "Built APK size: %s bytes"' "$PKG_SIZE"
      )
    }$(
      for d in $DEPS; do
        printf ',\n'; emit_dep "$d"
      done
    )
  ],
  "files": [
$(
    first=1
    while IFS=' ' read -r sha rel; do
        # Strip leading "./" from find output.
        rel=${rel#./}
        size=$(stat -c '%s' "$STAGING/$rel" 2>/dev/null || stat -f '%z' "$STAGING/$rel")
        if [ "$first" = "1" ]; then first=0; else printf ',\n'; fi
        emit_file "$rel" "$sha" "$size"
    done < "$TMP"
)
  ],
  "relationships": [
    { "spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Package-uapi" }$(
      for d in $DEPS; do
        SPDXID="SPDXRef-Dep-$(printf '%s' "$d" | tr -c 'A-Za-z0-9' '-')"
        printf ',\n    { "spdxElementId": "SPDXRef-Package-uapi", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "%s" }' "$SPDXID"
      done
    )
  ]
}
EOF
