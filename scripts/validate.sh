#!/bin/bash
#
# Validates that DatalyrSDK compiles for iOS Simulator.
# Catches Swift compile errors before tagging a release.
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

# Step 0: Version single-source-of-truth check (IOS-20).
#
# DatalyrVersion.current is the ONLY place the version is written in Swift, but
# the podspec is a separate artifact and CocoaPods publishes from it. Nothing
# used to compare them, and the result was measurable in production: a single
# live request carried envelope 2.1.1, payload 2.1.3 and User-Agent 2.0.2 at the
# same time, because context.version stayed frozen across four releases.
# A half-bumped release is now a hard failure, not a silent one.
echo "[1/3] Checking version consistency..."
SWIFT_VERSION=$(grep -Eo 'static let current = "[0-9]+\.[0-9]+\.[0-9]+"' Sources/DatalyrSDK/DatalyrVersion.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
PODSPEC_VERSION=$(grep -Eo "s\.version\s*=\s*'[0-9]+\.[0-9]+\.[0-9]+'" DatalyrSDK.podspec | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')

if [ -z "$SWIFT_VERSION" ] || [ -z "$PODSPEC_VERSION" ]; then
  echo "  FAILED: could not parse a version"
  echo "    DatalyrVersion.swift: '${SWIFT_VERSION:-<not found>}'"
  echo "    DatalyrSDK.podspec:   '${PODSPEC_VERSION:-<not found>}'"
  exit 1
fi

if [ "$SWIFT_VERSION" != "$PODSPEC_VERSION" ]; then
  echo "  FAILED: version mismatch — bump BOTH together"
  echo "    DatalyrVersion.current = $SWIFT_VERSION"
  echo "    DatalyrSDK.podspec     = $PODSPEC_VERSION"
  exit 1
fi

# No version literal may reappear outside DatalyrVersion.swift. This is what
# actually prevents a regression: adding a new hardcoded "2.1.x" anywhere in
# Sources/ fails here rather than drifting silently for four releases.
STRAY=$(grep -rn "$SWIFT_VERSION" Sources/ \
        | grep -v 'Sources/DatalyrSDK/DatalyrVersion.swift' \
        | grep -vE '^\s*[^:]+:[0-9]+:\s*(//|\*|/\*)' || true)
if [ -n "$STRAY" ]; then
  echo "  FAILED: hardcoded version literal outside DatalyrVersion.swift:"
  echo "$STRAY"
  echo "  Use DatalyrVersion.current / DatalyrVersion.userAgent instead."
  exit 1
fi

# Install instructions must reference a version a customer can actually install.
#
# The invariant is NOT "docs == podspec". That was wrong and caused a real
# conflict: the tree is bumped to the next version as soon as work lands, but
# that version has no git tag and is not on CocoaPods until it is released — so
# forcing the docs to match the tree tells customers to install something that
# does not exist. (It also fought a concurrent docs rewrite, which looked from
# the other side like an automated rewriter.)
#
# Correct rule: the docs must reference EITHER the podspec version (post-release)
# OR the newest git tag (pre-release window). Anything else — a version from
# eight releases ago, or a pod name that does not resolve — fails.
LATEST_TAG=$(git tag --list 'v[0-9]*' '[0-9]*' 2>/dev/null | sed 's/^v//' | sort -V | tail -1)
DOC_STALE=""
for doc in README.md QUICKSTART.md; do
  [ -f "$doc" ] || continue
  while IFS= read -r line; do
    case "$line" in
      *"$SWIFT_VERSION"*) ;;
      *"$LATEST_TAG"*) ;;
      *) DOC_STALE="$DOC_STALE\n  $doc: $line" ;;
    esac
  done < <(grep -E "pod +'DatalyrSDK'|from: *\"[0-9]+\.[0-9]+\.[0-9]+\"|Select version" "$doc" || true)
  if grep -q "DatalyrSwift" "$doc"; then
    DOC_STALE="$DOC_STALE\n  $doc: references pod 'DatalyrSwift' — the podspec is named DatalyrSDK"
  fi
done
if [ -n "$DOC_STALE" ]; then
  echo "  FAILED: install docs reference a version that is neither the podspec"
  echo "          ($SWIFT_VERSION) nor the newest tag (${LATEST_TAG:-<none>}):"
  printf "%b\n" "$DOC_STALE"
  echo "  Docs should track the newest INSTALLABLE version. Bump them as part of"
  echo "  the release (tag + pod trunk push), not as part of the code change."
  exit 1
fi

echo "  OK: podspec $SWIFT_VERSION == Swift constant; docs reference ${LATEST_TAG:-$SWIFT_VERSION}; no stray literals"

# Step 1: Resolve packages
echo "[2/3] Resolving Swift packages..."
xcodebuild -resolvePackageDependencies -scheme DatalyrSDK -skipPackagePluginValidation -quiet 2>&1 | tail -3

# Step 2: Build for iOS Simulator
echo "[3/3] Building for iOS Simulator (this may take a minute)..."
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
