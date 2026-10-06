#!/bin/bash
# Builds Pullcord and installs it to /Applications, quitting and replacing whatever
# copy is already there. This is the one to run day to day.
#
# Running the app straight out of ./build seems fine and isn't: build.sh starts by
# deleting that directory, so a running instance has its bundle pulled out from under
# it. The process keeps going — its executable is still mapped — but LaunchServices now
# sees the rebuilt bundle as a different app on disk, so launching it again starts a
# SECOND copy rather than reusing the first. Do that a few times and several copies are
# running at once.
#
# That is worse than untidy. Every instance installs its own dictation monitor and
# registers the same global hotkeys, so one keypress starts N dictations and N Auto-Tidy
# passes, each diffing the field while the others are pasting into it — which reads as
# the dictated text coming back mangled and repeated. Installing to a stable path and
# quitting the old copy first is what stops it.
#
# build.sh deliberately doesn't do any of this: CI calls it and needs the app left
# sitting in ./build.
set -e

cd "$(dirname "$0")"

APP_NAME="Pullcord"
BUNDLE_ID="com.ethan.pullcord"
BUILT="./build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

./build.sh

# -i because the executable's case has varied across builds: same bundle as far as
# this case-insensitive filesystem is concerned, different string as far as pkill is.
if pgrep -ix "$APP_NAME" >/dev/null; then
    echo "Quitting the running copy..."
    pkill -ix "$APP_NAME" || true
    # Wait for it to actually go. Its power assertion and status item are released by
    # the kernel when the process dies, so there is nothing to lose by being patient
    # here and something to lose by copying over a bundle still in use.
    for _ in $(seq 30); do
        pgrep -ix "$APP_NAME" >/dev/null || break
        sleep 0.1
    done
    if pgrep -ix "$APP_NAME" >/dev/null; then
        echo "  ...didn't quit on its own, forcing."
        pkill -9 -ix "$APP_NAME" 2>/dev/null || true
        sleep 0.3
    fi
fi

# Replace rather than move onto: this filesystem is case-insensitive, so an older
# /Applications/Pullcord.app IS this path, and `mv` onto an existing directory would
# nest the new bundle inside the old one instead of replacing it.
if [ -e "$DEST" ]; then
    installed_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "${DEST}/Contents/Info.plist" 2>/dev/null || true)
    # Never delete something that isn't ours, however much the name matches.
    if [ "$installed_id" != "$BUNDLE_ID" ]; then
        echo "Refusing to replace ${DEST}." >&2
        echo "  Its bundle id is '${installed_id:-unreadable}', not ${BUNDLE_ID}." >&2
        exit 1
    fi
    rm -rf "$DEST"
fi

mv "$BUILT" "$DEST"
# Leave nothing behind to launch by accident — a stray second bundle is how this
# started.
rm -rf ./build

echo "Installed ${DEST}"
open "$DEST"

# Confirm exactly one is running, since "how many copies are there" is the whole point.
sleep 1
count=$(pgrep -ix "$APP_NAME" | wc -l | tr -d ' ')
echo "Running instances: ${count}"
if [ "$count" != "1" ]; then
    echo "  Expected exactly 1 — check with: pgrep -ilx ${APP_NAME}" >&2
fi
