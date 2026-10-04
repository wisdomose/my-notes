#!/usr/bin/env bash
# Runs integration_test/ on a connected Android device or emulator, with the
# microphone and notification permissions granted as soon as the app is
# installed (so no permission dialog blocks the test). Saves logcat.txt.
set -uo pipefail
cd "$(dirname "$0")/.."

PKG=com.wisdomose.hey_notes
DEVICE=${DEVICE:-$(adb devices | awk 'NR==2 {print $1}')}

adb -s "$DEVICE" uninstall "$PKG" >/dev/null 2>&1 || true
adb -s "$DEVICE" logcat -c
adb -s "$DEVICE" logcat -v time > logcat.txt &
LOGCAT=$!

(
  for _ in $(seq 1 3000); do
    if adb -s "$DEVICE" shell pm grant "$PKG" android.permission.RECORD_AUDIO 2>/dev/null; then
      adb -s "$DEVICE" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null
      echo "permissions granted"
      break
    fi
    sleep 0.2
  done
) &

flutter test integration_test -d "$DEVICE" --reporter expanded
STATUS=$?

kill $LOGCAT 2>/dev/null
echo "--- logcat (filtered) ---"
grep -E "flutter|AndroidRuntime|FATAL|ForegroundService|sherpa|onnx|AudioRecord|hey_notes" logcat.txt | tail -400
exit $STATUS
