#!/bin/bash
# Fetch AirliftFFI.xcframework (build prerequisite for the Wallet card skins).
#
# The 127 MB xcframework is NOT stored in this repo: the Git Data API refuses
# blobs that large (HTTP 422), and the two .a slices are ~66 MB each. It is
# fetched from the NVD-AirCard fork, pinned to a commit SHA so the build stays
# reproducible, and both .a files are SHA256-verified (checksums measured
# against AirCard 1.3.3's xcframework).
#
# TEMPORARY HOME: this script is called from Tests/run_policy_tests.sh (the
# only repo script the CI workflow runs before the build step), because the
# GitHub token used for API pushes has only the `repo` scope — it lacks the
# `workflow` scope, so the workflow file itself cannot be updated through the
# API (GitHub answers 404). Once the token is renewed with `repo` + `workflow`
# scopes, move the call into .github/workflows/build-unsigned-ipa.yml (as the
# "Fetch AirliftFFI.xcframework" step) and drop the call from
# Tests/run_policy_tests.sh. This script itself does not change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/AirliftFFI.xcframework"
BASE="https://raw.githubusercontent.com/nvd29u1/NVD-AirCard/0087e84b03f312df021f5b390d5888c523b03c71/AirliftFFI.xcframework"

ARM_SHA="a239572c8018c3965fc4b23e008f0874dd35e34dd5b9f70149f4a154abf72a0f"
SIM_SHA="601dd08b1ed9482a1a7c6bd69f422664cb61578a23a5308c1f8a08d9fbc12816"

mkdir -p "$DEST/ios-arm64/Headers" "$DEST/ios-arm64-simulator/Headers"

fetch() { # $1 = relative path, $2 = expected sha256 (empty = no check)
  local rel="$1" sha="$2"
  local f="$DEST/$rel"
  if [[ -n "$sha" && -f "$f" ]] && echo "$sha  $f" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "fetch-airlift-ffi: $rel already present (checksum OK), skipping"
    return 0
  fi
  if [[ -z "$sha" && -f "$f" ]]; then
    echo "fetch-airlift-ffi: $rel already present, skipping"
    return 0
  fi
  echo "fetch-airlift-ffi: downloading $rel ..."
  curl -fsSL "$BASE/$rel" -o "$f"
}

fetch "Info.plist" ""
fetch "ios-arm64/Headers/airlift.h" ""
fetch "ios-arm64/Headers/module.modulemap" ""
fetch "ios-arm64-simulator/Headers/airlift.h" ""
fetch "ios-arm64-simulator/Headers/module.modulemap" ""
fetch "ios-arm64/libairlift_ffi.a" "$ARM_SHA"
fetch "ios-arm64-simulator/libairlift_ffi.a" "$SIM_SHA"

# Final verification (fails the build loudly on a bad download).
echo "$ARM_SHA  $DEST/ios-arm64/libairlift_ffi.a" | shasum -a 256 -c -
echo "$SIM_SHA  $DEST/ios-arm64-simulator/libairlift_ffi.a" | shasum -a 256 -c -
echo "fetch-airlift-ffi: AirliftFFI.xcframework ready at $DEST"
