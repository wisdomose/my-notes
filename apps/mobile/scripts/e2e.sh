#!/usr/bin/env bash
# Runs integration_test/ on a connected Android device or emulator, with the
# microphone and notification permissions granted up front (so no permission
# dialog blocks the test). Saves logcat.txt.
set -uo pipefail
cd "$(dirname "$0")/.."

PKG=com.wisdomose.hey_notes
DEVICE=${DEVICE:-$(adb devices | awk 'NR==2 {print $1}')}

adb -s "$DEVICE" uninstall "$PKG" >/dev/null 2>&1 || true

# Install a debug build with every runtime permission granted (-g) before
# the test runs. `flutter test` then reinstalls in place (adb install -r),
# which keeps granted permissions, so no permission dialog ever appears.
flutter build apk --debug
adb -s "$DEVICE" install -g build/app/outputs/flutter-apk/app-debug.apk
adb -s "$DEVICE" shell dumpsys package "$PKG" | grep -E "RECORD_AUDIO|POST_NOTIFICATIONS"

adb -s "$DEVICE" logcat -c
adb -s "$DEVICE" logcat -v time > logcat.txt &
LOGCAT=$!

flutter test integration_test -d "$DEVICE" --reporter expanded
STATUS=$?

kill $LOGCAT 2>/dev/null
echo "--- logcat (filtered) ---"
grep -E "flutter|AndroidRuntime|FATAL|ForegroundService|sherpa|onnx|AudioRecord|hey_notes" logcat.txt | tail -400
exit $STATUS
