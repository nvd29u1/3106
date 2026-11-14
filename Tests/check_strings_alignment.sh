#!/bin/bash
# NVD 1506 is Vietnamese-only: verify vi.lproj exists and defines keys.
# (Upstream checked zh-Hans/en/vi alignment; en + zh-Hans were removed.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VI="$ROOT/ThreeOneOSSix/vi.lproj/Localizable.strings"

if [[ ! -f "$VI" ]]; then
  echo "FAIL: vi.lproj/Localizable.strings missing" >&2
  exit 1
fi
COUNT=$(grep -c '^"' "$VI" || true)
echo "vi: $COUNT keys"
if [[ "$COUNT" -lt 100 ]]; then
  echo "FAIL: vi.lproj looks empty ($COUNT keys)" >&2
  exit 1
fi
if [[ -d "$ROOT/ThreeOneOSSix/en.lproj" || -d "$ROOT/ThreeOneOSSix/zh-Hans.lproj" ]]; then
  echo "FAIL: non-Vietnamese .lproj still present" >&2
  exit 1
fi
echo "PASS: Vietnamese-only localization (vi: $COUNT keys)"
