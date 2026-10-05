# Hey Notes (mobile)

Flutter Android app. Say “Hey Notes”, speak, and the note saves itself when
you stop talking.

## How it works

```
mic (16 kHz) ─▶ wake word ──"Hey Notes"──▶ capture ──silence──▶ transcribe ─▶ SQLite
               (KWS, 5 MB)               live text +           Whisper base.en
                                         VAD end-of-speech     (or streaming text)
```

All speech runs on-device with [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx):

| Job | Model | Where |
|---|---|---|
| Wake word | zipformer KWS (gigaspeech 3.3M), int8 | bundled |
| Live text while you talk | streaming zipformer en 20M, int8 | bundled |
| End of speech | Silero VAD | bundled |
| Final text (default) | Intron Sahara via `apps/api` | cloud |
| Final text, on-device | Whisper base.en int8 (161 MB) | download; phones ≥ 3 GB RAM |
| Final text, on-device | NVIDIA Parakeet TDT 0.6B v2 int8 (661 MB) | download; phones ≥ 6 GB |
| Final text, on-device | Whisper large-v3-turbo int8 (1.0 GB) | download; phones ≥ 8 GB |
| Final text, on-device | Whisper large-v3 int8 (1.8 GB) | download; phones ≥ 12 GB |

Only the engine the user picked is used: if it fails (offline, low memory,
error, timeout) the note is saved with its audio, marked "not transcribed"
with the reason, and can be retried. On-device models are loaded only while
transcribing a note, after checking free memory. Settings refuses models the
phone can't run.

Whisper is far better with Nigerian English than the small streaming model,
so when it's downloaded it re-transcribes each speech segment and that text
is what gets saved. Until then the streaming text is saved.

The pipeline lives in `lib/voice/voice_engine.dart` (pure Dart, tested on the
host in `test/voice_engine_test.dart`). On the phone it runs inside an Android
foreground service (`lib/voice/voice_task.dart`, `microphone` type) so it keeps
listening with the screen off. The UI talks to it through
`lib/voice/voice_controller.dart`.

## Layout

```
lib/
  main.dart                 app + services
  theme.dart                palette and type from the design canvas
  data/                     Note, SQLite store, settings
  voice/                    engine, foreground service, model files
  ui/                       home, listening, saved sheet, note, settings
scripts/fetch-models.sh     downloads bundled models into assets/models/
test/                       unit tests + voice pipeline tests (fixtures/*.wav)
```

## Commands

From the repo root use `pnpm build|test|lint`, or here:

```bash
bash scripts/fetch-models.sh
flutter test
flutter build apk --release --target-platform android-arm64
```

The Whisper test runs only if `assets/models/whisper/` holds the model (same
files the app downloads; not bundled into the APK).

## Notes

* Android 14+ only allows a microphone service to start while the app is
  open, so background listening starts when you open the app (and after
  a reboot, once you open it again).
* If “Hey Notes” stops working after a while, allow the app to ignore battery
  optimization (Settings → Allow running in background).
* Release builds are signed with the debug key for now.
