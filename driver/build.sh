#!/bin/bash
# Builds driver/build/TabletAudio.driver. SIGN_IDENTITY overrides the signing identity
# (default: first "Apple Development" cert, else ad-hoc).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCODESIGN_ID="$IDENTITY"
cmake --build build -j 8
codesign --verify --strict --verbose=2 build/TabletAudio.driver
echo "built driver/build/TabletAudio.driver (signed with: $IDENTITY)"
