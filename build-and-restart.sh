#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="Simple Video"
APP_PATH="$(pwd)/Simple Video.app"

osascript >/dev/null 2>&1 <<APPLESCRIPT || true
tell application "$APP_NAME"
    if it is running then
        quit
    end if
end tell
APPLESCRIPT

while pgrep -x "$APP_NAME" >/dev/null; do
    sleep 0.5
done

sh build.sh

open "$APP_PATH"
