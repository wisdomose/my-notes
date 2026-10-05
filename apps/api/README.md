# Hey Notes API (Rust)

Cloud transcription for Hey Notes through [Intron Sahara](https://www.intron.io/),
a speech model built for African-accented English. The Intron key stays on the
server; the app only talks to this API.

## Endpoints

`POST /v1/transcribe` (open, rate-limited per client IP), multipart form:

| Field | |
|---|---|
| `audio` | the recording: wav, mp3, m4a, ogg, webm or flac, up to 120 s / 15 MB |
| `language` | optional Intron code, default `en` (also `pcm` Pidgin, `yo`, `ig`, …) |

```bash
curl -F audio=@note.wav http://localhost:8080/v1/transcribe
# {"text":"Buy bread, eggs and a pack of water on the way home.","fileId":null,"durationSeconds":8.0,"language":"en"}
```

Errors are `{"error": "..."}`: 400 bad input, 413 too large, 422 rejected by
Intron (e.g. over 120 s), 429 rate limited (with `Retry-After`), 502/504
upstream failure or timeout.

`GET /health` → `{"ok": true}`

Intron's sync endpoint is used; if it times out it returns a file id, which the
API polls for up to 90 s.

## Configuration

Environment variables (or a git-ignored `.env`, see `.env.example`):

| Variable | Default | |
|---|---|---|
| `INTRON_API_KEY` | required | never commit it, the repo is public |
| `PORT` | 8080 | |
| `RATE_LIMIT_PER_MINUTE` | 10 | per client IP |
| `TRUST_PROXY` | true in Docker | read the client IP from `X-Forwarded-For` |
| `INTRON_BASE_URL` | `https://infer.voice.intron.io` | |

The route is open: anyone with the URL can spend Intron credits, up to the
per-IP limit. Intron itself allows 30 requests a minute per key.

## Develop

```bash
cp .env.example .env   # add the key
cargo run              # or: pnpm turbo run dev --filter=@my-notes/api
cargo test             # fake Intron server, no credits used
```

## Deploy

Live at **https://hey-notes-api.chat-buddy.xyz** (Coolify project
`hey-notes`, app `hey-notes-api`, a "Docker Image" resource), behind
Cloudflare's proxy via the `*.chat-buddy.xyz` wildcard record, so the
server's IP stays hidden. Rate limiting uses `CF-Connecting-IP`, trusted
only when the request came from a Cloudflare edge IP. The VPS never builds
anything:

1. On push to `main`, `.github/workflows/api.yml` runs fmt, clippy and tests,
   then pushes `ghcr.io/wisdomose/hey-notes-api:latest` (and `:<sha>`). The
   image is public; it holds no secrets.
2. The Coolify API only answers from the server's Tailscale address, so
   GitHub can't trigger the deploy. Instead `deploy/coolify-watch.sh` runs
   from cron on the server every 2 minutes, compares the image digest with
   the last one deployed, and calls Coolify's deploy endpoint when it changed
   (log: `~/.local/state/hey-notes/coolify-watch.log`).
3. `INTRON_API_KEY`, `RATE_LIMIT_PER_MINUTE` and `TRUST_PROXY` are set as
   environment variables on the Coolify app. The container is capped at
   256 MB and health-checked on `/health`.
