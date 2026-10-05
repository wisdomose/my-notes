#!/usr/bin/env bash
# Redeploys the Hey Notes API in Coolify when a new image is published.
#
# GitHub Actions pushes ghcr.io/wisdomose/hey-notes-api:latest, but the
# Coolify API only accepts calls from this server's Tailscale address, so
# Actions can't trigger the deploy. This runs on the server from cron
# (every 2 minutes), compares the image digest with the last one deployed,
# and asks Coolify to redeploy when it changed.
#
#   */2 * * * * APP_UUID=<coolify app uuid> /path/to/coolify-watch.sh
#
# The Coolify token is read from ~/.config/coolify/api-token at run time;
# nothing secret lives in this file.
set -euo pipefail

IMAGE=${IMAGE:-wisdomose/hey-notes-api}
TAG=${TAG:-latest}
APP_UUID=${APP_UUID:?set APP_UUID to the Coolify application uuid}
API=${COOLIFY_API:-http://100.97.237.89:8000/api/v1}
TOKEN_FILE=${COOLIFY_TOKEN_FILE:-$HOME/.config/coolify/api-token}
STATE_DIR=${STATE_DIR:-$HOME/.local/state/hey-notes}
LOG=$STATE_DIR/coolify-watch.log

mkdir -p "$STATE_DIR"
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# Public image: anonymous pull token, then the manifest digest.
pull_token=$(curl -fsS "https://ghcr.io/token?scope=repository:$IMAGE:pull" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
digest=$(curl -fsSI \
  -H "Authorization: Bearer $pull_token" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/$IMAGE/manifests/$TAG" |
  awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }' | tr -d '\r')

if [[ -z $digest ]]; then
  log "could not read the digest of $IMAGE:$TAG"
  exit 1
fi

last=$(cat "$STATE_DIR/last-digest" 2>/dev/null || true)
[[ $digest == "$last" ]] && exit 0

# Keep the token out of the process list: pass the header via stdin.
if curl -fsS -H @- -H "Accept: application/json" \
  "$API/deploy?uuid=$APP_UUID&force=false" > /dev/null <<< "Authorization: Bearer $(cat "$TOKEN_FILE")"; then
  echo "$digest" > "$STATE_DIR/last-digest"
  log "deploy requested for $IMAGE:$TAG @ $digest"
else
  log "deploy request failed for $digest (will retry)"
  exit 1
fi
