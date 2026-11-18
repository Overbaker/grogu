#!/usr/bin/env bash
# Package clean, profile-free, ad-hoc signed IPAs into ios/release/:
#   - GroguApp.ipa
#   - GroguRunner.ipa
#   - GroguRunner-sideload.ipa (PlugIns/*.xctest -> Frameworks/*.framework for AltStore/Impactor)
set -euo pipefail

IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$IOS_ROOT/.." && pwd)"
OUT_DIR="${1:-$IOS_ROOT/release}"
mkdir -p "$OUT_DIR"

adhoc_sign_ipa() {
    local src_ipa="$1"
    local dst_ipa="$2"
    local work app
    work="$(mktemp -d)"

    unzip -q "$src_ipa" -d "$work"
    app="$(find "$work/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
    if [ -z "$app" ]; then
        rm -rf "$work"
        echo "No .app in $src_ipa" >&2
        exit 1
    fi

    find "$app" -name 'embedded.mobileprovision' -delete
    find "$app" -name '*.dSYM' -exec rm -rf {} + 2>/dev/null || true
    find "$app" -name '_CodeSignature' -type d -exec rm -rf {} + 2>/dev/null || true

    local sign=(codesign --force --timestamp=none --sign -)
    while IFS= read -r f; do "${sign[@]}" "$f" 2>/dev/null; done \
        < <(find "$app" -name '*.dylib' -not -path '*.framework/*' | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
    while IFS= read -r f; do "${sign[@]}" "$f" 2>/dev/null; done \
        < <(find "$app" -name '*.framework' -type d | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
    for plugin in "$app"/PlugIns/*; do
        [[ -d "$plugin" ]] && "${sign[@]}" "$plugin" 2>/dev/null
    done
    "${sign[@]}" "$app" 2>/dev/null
    codesign --verify --deep --strict "$app"

    rm -f "$dst_ipa"
    (cd "$work" && zip -qry "$dst_ipa" Payload)
    rm -rf "$work"
    echo "Packaged $dst_ipa ($(du -h "$dst_ipa" | cut -f1 | tr -d ' '))"
}

adhoc_sign_ipa "$IOS_ROOT/GroguApp.ipa" "$OUT_DIR/GroguApp.ipa"
adhoc_sign_ipa "$IOS_ROOT/GroguRunner.ipa" "$OUT_DIR/GroguRunner.ipa"

SIDELOAD_TMP="$(mktemp -d)"
trap 'rm -rf "$SIDELOAD_TMP"' EXIT
python3 "$REPO_ROOT/src/grogu/prepare_sideload_ipa.py" \
    --input "$OUT_DIR/GroguRunner.ipa" \
    --output "$SIDELOAD_TMP/GroguRunner-raw.ipa"
adhoc_sign_ipa "$SIDELOAD_TMP/GroguRunner-raw.ipa" "$OUT_DIR/GroguRunner-sideload.ipa"
