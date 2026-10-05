#!/bin/bash
# Debug build with the virtualization entitlement, for running planed straight from .build.
#   scripts/dev.sh image status
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -q
codesign --force --sign - --entitlements scripts/entitlements.plist .build/debug/planed
codesign --force --sign - --entitlements scripts/entitlements.plist .build/debug/DesktopPlane
exec .build/debug/planed "$@"
