#!/bin/sh
# Builds with the public sounds and writes the release zip and its SHA-256 to build/.
set -eu
cd "$(dirname "$0")/.."

./build.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - Info.plist)
ZIP="Plastikey-$VERSION.zip"

# ditto, so the zip keeps the app's signature intact.
rm -f "build/$ZIP" "build/$ZIP.sha256"
ditto -c -k --keepParent build/Plastikey.app "build/$ZIP"
(cd build && shasum -a 256 "$ZIP" >"$ZIP.sha256")

cat "build/$ZIP.sha256"
codesign --display --verbose=2 build/Plastikey.app 2>&1 | grep -E '^(Authority|Signature)=' || true
