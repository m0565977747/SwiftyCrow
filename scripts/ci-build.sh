#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the Ventura backport as a Universal 2 (arm64 + x86_64) Release app,
# runs the unit tests, verifies the binary really targets macOS 13.0, zips the
# app, and (when GH_TOKEN is set) publishes everything as a pre-release so the
# assets can be downloaded without Actions-artifact authentication.
#
# Usage: scripts/ci-build.sh [run-number]
set -euo pipefail

RUN_NUMBER="${1:-${GITHUB_RUN_NUMBER:-local}}"
export TUIST_DEVELOPMENT_TEAM=""
export TUIST_SPARKLE_PUBLIC_ED_KEY=""

status="failure"
finish() {
  if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    echo "== Publish pre-release (status: $status) =="
    files=""
    for f in SwiftyCrow-ventura.zip build.log test.log; do
      [ -f "$f" ] && files="$files $f"
    done
    tag="ci-build-${RUN_NUMBER}"
    gh release create "$tag" $files \
      --repo "$GITHUB_REPOSITORY" \
      --prerelease \
      --target "$(git rev-parse HEAD)" \
      --title "CI build ${RUN_NUMBER} (${status})" \
      --notes "Automated Ventura backport build of $(git rev-parse --short HEAD) — status: ${status}. Not a supported release." || true
  fi
}
trap finish EXIT

echo "== Toolchain =="
sw_vers
xcodebuild -version
swift --version
tuist version

echo "== Generate =="
tuist install
tuist generate --no-open

echo "== Build (Release, Universal 2, macOS 13.0) =="
set +e
xcodebuild build \
  -workspace SwiftyCrow.xcworkspace \
  -scheme SwiftyCrow \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  CODE_SIGNING_ALLOWED=YES \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  2>&1 | tee build.log
build_rc=${PIPESTATUS[0]}
set -e
if [ "$build_rc" -ne 0 ] || grep -qE "(^|: )error:" build.log; then
  echo "::group::Compiler errors"
  grep -E "(^|: )error:" build.log || true
  echo "::endgroup::"
  exit 1
fi

echo "== Package =="
APP="DerivedData/Build/Products/Release/SwiftyCrow.app"
ditto -c -k --keepParent "$APP" SwiftyCrow-ventura.zip

echo "== Test (Debug) =="
set +e
xcodebuild test \
  -workspace SwiftyCrow.xcworkspace \
  -scheme SwiftyCrow \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  2>&1 | tee test.log
test_rc=${PIPESTATUS[0]}
set -e

echo "== Verify binary =="
BIN="$APP/Contents/MacOS/SwiftyCrow"
test -x "$BIN"
lipo -info "$BIN"
vtool -show-build "$BIN" | grep -E "minos|platform"
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist"
for f in $(find "$APP/Contents/Frameworks" -type f -perm +111 -maxdepth 4 2>/dev/null); do
  echo "$f"; lipo -info "$f" || true
  vtool -show-build "$f" 2>/dev/null | grep -E "minos" || true
done
codesign -dv --verbose=2 "$APP" 2>&1 | head
codesign --verify --deep --strict "$APP"
ARCHS="$(lipo -archs "$BIN")"
case " $ARCHS " in *" x86_64 "*) ;; *) echo "::error::missing x86_64 ($ARCHS)"; exit 1 ;; esac
case " $ARCHS " in *" arm64 "*) ;; *) echo "::error::missing arm64 ($ARCHS)"; exit 1 ;; esac
MINOS="$(vtool -show-build "$BIN" | awk '/minos/ { print $2 }' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
echo "minos: $MINOS"
[ "$MINOS" = "13.0" ] || { echo "::error::expected minos 13.0, got $MINOS"; exit 1; }
LSMIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
[ "$LSMIN" = "13.0" ] || { echo "::error::LSMinimumSystemVersion is $LSMIN"; exit 1; }

if [ "$test_rc" -ne 0 ]; then
  echo "::error::unit tests failed (see test.log)"
  status="build-ok-tests-failed"
  exit 1
fi
status="success"
echo "== OK =="
