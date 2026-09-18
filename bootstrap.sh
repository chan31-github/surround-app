#!/bin/sh
# Generates Surround.xcodeproj on a Mac. Requires XcodeGen (brew install xcodegen).
set -eu
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is not installed. Run: brew install xcodegen" >&2
  exit 1
fi

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo "Created Config/Local.xcconfig; set DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER in it."
fi

xcodegen generate
echo "Done. Open Surround.xcodeproj."
