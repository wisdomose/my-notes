# My Notes — “Hey Notes”

Say **“Hey Notes”**, speak, and your note is saved. Everything runs on the
phone: wake word, speech-to-text and the database. No account, no cloud.

A Turborepo monorepo:

| Path | What |
|---|---|
| `apps/mobile` | Flutter Android app (see its README) |
| `apps/api` | Rust API: `POST /v1/transcribe` via Intron Sahara (see apps/api/README.md) |
| `packages/` | Shared code, later |

## Setup

Needs Node 22+, pnpm, Flutter 3.47+, JDK 17 and the Android SDK (with NDK).

```bash
pnpm install
pnpm fetch-models   # downloads the on-device speech models (~51 MB)
pnpm test           # unit tests + the voice pipeline on synthesized speech
pnpm build          # release APK (arm64)
```

The APK lands in
`apps/mobile/build/app/outputs/flutter-apk/app-release.apk`.
