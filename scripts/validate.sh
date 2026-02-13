#!/bin/bash
#
# Validates that DatalyrSDK compiles for iOS Simulator.
# Catches Swift compile errors (TikTok/Meta API changes, etc.) before tagging a release.
#
# Usage:
#   ./scripts/validate.sh
#
# Run this BEFORE tagging a release to catch compile errors.

set -euo pipefail

SDK_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo ""
echo "=== DatalyrSDK iOS Build Validation ==="
echo "SDK: $SDK_DIR"
echo ""

cd "$SDK_DIR"

# Step 1: Resolve packages
echo "[1/2] Resolving Swift packages..."
xcodebuild -resolvePackageDependencies -scheme DatalyrSDK -skipPackagePluginValidation -quiet 2>&1 | tail -3

# Step 2: Build for iOS Simulator
echo "[2/2] Building for iOS Simulator (this may take a minute)..."
xcodebuild build \
  -scheme DatalyrSDK \
  -destination "generic/platform=iOS Simulator" \
  -skipPackagePluginValidation \
  -quiet \
  2>&1 | grep -E "error:|BUILD FAILED" || true

# Check exit code of xcodebuild (not grep)
BUILD_EXIT=${PIPESTATUS[0]}

if [ "$BUILD_EXIT" -eq 0 ]; then
  echo ""
  echo "=== iOS build validation PASSED ==="
  echo ""
  exit 0
else
  echo ""
  echo "=== iOS build validation FAILED ==="
  echo "Fix the compile errors above before releasing."
  echo ""
  exit 1
fi
