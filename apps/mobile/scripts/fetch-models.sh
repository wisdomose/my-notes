#!/usr/bin/env bash
# Downloads the on-device speech models that are bundled into the APK.
# (Whisper is not bundled: the app downloads it on first launch.)
# Note: the "-mobile" variants of these models crash with sherpa-onnx 1.13.8
# (Reshape error in /downsample), so the regular int8 exports are used.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=assets/models
BASE=https://github.com/k2-fsa/sherpa-onnx/releases/download

KWS=sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
ASR=sherpa-onnx-streaming-zipformer-en-20M-2023-02-17

if [[ -f $OUT/.complete ]]; then
  echo "models already present in $OUT"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT/kws" "$OUT/asr"

echo "downloading wake-word model..."
curl -fsSL "$BASE/kws-models/$KWS.tar.bz2" | tar -xj -C "$TMP"
cp "$TMP/$KWS/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "$OUT/kws/encoder.onnx"
cp "$TMP/$KWS/decoder-epoch-12-avg-2-chunk-16-left-64.onnx" "$OUT/kws/decoder.onnx"
cp "$TMP/$KWS/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "$OUT/kws/joiner.onnx"
cp "$TMP/$KWS/tokens.txt" "$OUT/kws/tokens.txt"

echo "downloading streaming speech model..."
curl -fsSL "$BASE/asr-models/$ASR.tar.bz2" | tar -xj -C "$TMP"
cp "$TMP/$ASR/encoder-epoch-99-avg-1.int8.onnx" "$OUT/asr/encoder.onnx"
cp "$TMP/$ASR/decoder-epoch-99-avg-1.onnx" "$OUT/asr/decoder.onnx"
cp "$TMP/$ASR/joiner-epoch-99-avg-1.int8.onnx" "$OUT/asr/joiner.onnx"
cp "$TMP/$ASR/tokens.txt" "$OUT/asr/tokens.txt"

echo "downloading voice activity model..."
curl -fsSL -o "$OUT/silero_vad.onnx" "$BASE/asr-models/silero_vad.onnx"

touch "$OUT/.complete"
echo "done: $(du -sh "$OUT" | cut -f1) in $OUT"
