#!/bin/bash
# Builds build/EdgeVolume.app. `./build.sh install` also copies it to
# /Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/EdgeVolume.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    -import-objc-header MultitouchSupport.h \
    -F /System/Library/PrivateFrameworks -framework MultitouchSupport \
    EdgeVolume.swift -o "$APP/Contents/MacOS/EdgeVolume"

# Signing with a real identity keeps the Accessibility grant across rebuilds;
# an ad-hoc signature (-) makes macOS ask again after every build.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}
codesign --force --sign "${IDENTITY:--}" "$APP"

if [[ "${1:-}" == install ]]; then
    pkill -x EdgeVolume || true
    rm -rf /Applications/EdgeVolume.app
    cp -R "$APP" /Applications/
    open /Applications/EdgeVolume.app
fi
