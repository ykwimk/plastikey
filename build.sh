#!/bin/sh
# Builds Plastikey. The self-check runs first, so a broken pack fails the build.
#   ./build.sh            public sounds/, makes build/Plastikey.app
#   ./build.sh --private  your own sounds-private/, makes build/private/Plastikey.app
set -eu
cd "$(dirname "$0")"

PACK=sounds
APP=build/Plastikey.app
case "${1:-}" in
    "") ;;
    --private)
        PACK=sounds-private
        APP=build/private/Plastikey.app
        ;;
    *)
        echo "Usage: ./build.sh [--private]" >&2
        exit 1
        ;;
esac

if [ ! -f "$PACK/config.json" ]; then
    echo "$PACK/config.json is missing. See sounds/README.md" >&2
    exit 1
fi
SOUND=$(plutil -extract sound raw -o - "$PACK/config.json")
# plutil reports a missing field on stdout, so only its exit code can be trusted.
MOUSE=$(plutil -extract mouse_sound raw -o - "$PACK/config.json" 2>/dev/null) || MOUSE=
MOUSE_UP=$(plutil -extract mouse_up_sound raw -o - "$PACK/config.json" 2>/dev/null) || MOUSE_UP=
for FILE in "$SOUND" "$MOUSE" "$MOUSE_UP"; do
    if [ -n "$FILE" ] && [ ! -f "$PACK/$FILE" ]; then
        echo "$PACK/$FILE is missing. See sounds/README.md" >&2
        exit 1
    fi
done

CFLAGS="-O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=11.0"

mkdir -p build
clang $CFLAGS -framework Foundation -framework AudioToolbox -framework CoreGraphics \
    tests/sound_test.m -o build/sound_test
build/sound_test "$PACK"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang $CFLAGS -arch x86_64 -arch arm64 -Wl,-dead_strip -framework Cocoa -framework AudioToolbox \
    src/main.m src/sound.m -o "$APP/Contents/MacOS/Plastikey"
strip -x "$APP/Contents/MacOS/Plastikey"
cp Info.plist "$APP/Contents/"
cp "$PACK/config.json" "$PACK/$SOUND" ${MOUSE:+"$PACK/$MOUSE"} ${MOUSE_UP:+"$PACK/$MOUSE_UP"} assets/AppIcon.icns \
    "$APP/Contents/Resources/"

# A public build holds exactly the pinned public sound files, plus the icon.
if [ "$PACK" = sounds ]; then
    FOUND=$(ls "$APP/Contents/Resources" | sort | tr '\n' ' ')
    WANTED=$(awk '{ print $2 } END { print "AppIcon.icns" }' sounds/SHA256SUMS | sort | tr '\n' ' ')
    if [ "$FOUND" != "$WANTED" ]; then
        echo "Public build holds unexpected files: $FOUND" >&2
        exit 1
    fi
    ROOT=$PWD
    if ! (cd "$APP/Contents/Resources" && shasum -a 256 -s -c "$ROOT/sounds/SHA256SUMS"); then
        echo "sounds/ does not match sounds/SHA256SUMS. Own sounds belong in sounds-private/" >&2
        exit 1
    fi
fi

# A stable signature keeps the Input Monitoring permission across rebuilds. Ad-hoc does not.
SIGN_NAME="Plastikey Local Signing"
IDENTITY=$(security find-identity -p codesigning 2>/dev/null |
    awk -v name="\"$SIGN_NAME\"" 'index($0, name) { print $2; exit }' || true)
if [ -z "$IDENTITY" ]; then
    IDENTITY=-
    echo "warning: no \"$SIGN_NAME\" certificate, using an ad-hoc signature. macOS will drop the" >&2
    echo "warning: Input Monitoring permission on every rebuild. See scripts/create-signing-identity.sh" >&2
fi
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
if ! codesign --display --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "The hardened runtime is not on." >&2
    exit 1
fi

echo "Built $APP ($(du -sk "$APP" | cut -f1) KB). Open it with: open $APP"
