#!/bin/sh
# Builds the measurement app (build/bench, never shipped) and runs one measurement.
# The keys here come from a timer, not the keyboard, and volume stays at 0 unless asked.
# Nothing shows on screen. PACK=sounds-private measures that pack instead of sounds/.
#   tests/measure.sh flow                 every permission state, with a fake permission
#   tests/measure.sh flow-export <dir>    same, and writes the icons and alerts as images
#   tests/measure.sh typing               10 keys a second for 60 s, CPU and latency
#   tests/measure.sh first-key            one key every 5 s, the output stopped in between
#   tests/measure.sh mouse                5 clicks a second, then one click every 5 s
#   tests/measure.sh soak                 10,000 keys, memory along the way
#   tests/measure.sh idle                 60 s with nothing happening
#   tests/measure.sh audible              10 quiet keys through the real output, you will hear them
set -eu
cd "$(dirname "$0")/.."

PACK=${PACK:-sounds}
APP=build/bench/Plastikey-bench.app
BIN="$APP/Contents/MacOS/Plastikey-bench"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable -Wno-unused-function -mmacosx-version-min=11.0 -DKS_BENCH -Isrc \
    -framework Cocoa -framework AudioToolbox -framework CoreAudio tests/bench.m src/sound.m -o "$BIN"
cp Info.plist "$APP/Contents/"
plutil -replace CFBundleIdentifier -string io.github.ykwimk.plastikey.bench "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Plastikey-bench "$APP/Contents/Info.plist"
SOUND=$(plutil -extract sound raw -o - "$PACK/config.json")
# plutil reports a missing field on stdout, so only its exit code can be trusted.
MOUSE=$(plutil -extract mouse_sound raw -o - "$PACK/config.json" 2>/dev/null) || MOUSE=
MOUSE_UP=$(plutil -extract mouse_up_sound raw -o - "$PACK/config.json" 2>/dev/null) || MOUSE_UP=
cp "$PACK/config.json" "$PACK/$SOUND" ${MOUSE:+"$PACK/$MOUSE"} ${MOUSE_UP:+"$PACK/$MOUSE_UP"} assets/AppIcon.icns \
    "$APP/Contents/Resources/"
# The same runtime flags as the app, so a start-up problem under them shows here first.
codesign --force --options runtime --timestamp=none --sign - "$APP" 2>/dev/null

# The plan's method: one reading a second for a minute, averaged.
with_top() {
    "$BIN" "$@" &
    PID=$!
    sleep 6
    top -l 56 -s 1 -pid $PID -stats pid,cpu | awk -v p=$PID '$1 == p { n++; gsub(/[+-]$/, "", $2); if (n > 1) s += $2 }
        END { printf "top, %d readings: average %.3f%%\n", n - 1, s / (n - 1) }'
    wait $PID
}

case "${1:-}" in
    flow)
        "$BIN" -flow plain -AppleLanguages '(ko)'
        "$BIN" -flow plain -AppleLanguages '(en)'
        ;;
    flow-export)
        mkdir -p "$2"
        DIR=$(cd "$2" && pwd)
        "$BIN" -flow light -export "$DIR" -AppleLanguages '(ko)'
        "$BIN" -flow dark -export "$DIR" -AppleLanguages '(ko)'
        ;;
    typing) with_top -rate 10 -count 650 ;;
    first-key) "$BIN" -rate 0.2 -count 12 ;;
    mouse)
        "$BIN" -rate 5 -count 40 -mouse 1
        "$BIN" -rate 0.2 -count 12 -mouse 1
        ;;
    soak) "$BIN" -rate 200 -count 10000 ;;
    idle) with_top -idle 60 ;;
    audible) "$BIN" -rate 5 -count 10 -testvolume 15 ;;
    *)
        sed -n 2,12p tests/measure.sh
        exit 1
        ;;
esac
