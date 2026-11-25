#!/bin/bash
# Install the optional local neural voice for Agent HUD.
#
#   scripts/get-neural-voice.sh            download and install (about 150 MB)
#   scripts/get-neural-voice.sh --remove   delete what was installed
#
# Installs into ~/Library/Application Support/AgentHUD/neural-voice/ as runtime/, model/ and a VERSION file.
# This script does the downloading; the app itself never touches the network.
set -euo pipefail

RUNTIME_VERSION="v2.0.3"
RUNTIME_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-osx-arm64-shared.tar.bz2"
RUNTIME_SHA256="14afb4ed15dc4f376c69be5a795039824e47f5ffcfc2488556f796ecaf420d07"
RUNTIME_DIR_IN_ARCHIVE="sherpa-onnx-v2.0.3-osx-arm64-shared"
MODEL_NAME="sherpa-onnx-supertonic-3-tts-int8-2026-05-11"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2"
MODEL_SHA256="82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427"
MODEL_PAGE="https://huggingface.co/Supertone/supertonic-3"

# The folder is spelled out with a guard, so a missing HOME can never turn a delete into "rm -rf /...".
if [ -z "${HOME:-}" ] || [ "${HOME#/}" = "$HOME" ]; then
    echo "HOME is not set to an absolute path; stopping." >&2
    exit 1
fi
DEST="$HOME/Library/Application Support/AgentHUD/neural-voice"
PARENT="$HOME/Library/Application Support/AgentHUD"

if [[ "${1:-}" == "--remove" ]]; then
    if [ -d "$HOME/Library/Application Support/AgentHUD/neural-voice" ]; then
        rm -rf "$HOME/Library/Application Support/AgentHUD/neural-voice"
        echo "Removed: $DEST"
    else
        echo "Nothing to remove: $DEST does not exist"
    fi
    exit 0
fi
if [[ $# -gt 0 ]]; then
    echo "usage: $0 [--remove]" >&2
    exit 2
fi

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "The neural voice runs only on Macs with Apple silicon (arm64); this machine is $(uname -s) $(uname -m)." >&2
    echo "The system voices keep working as before." >&2
    exit 1
fi

cat <<TXT
Neural voice for Agent HUD (runs fully on this Mac)

  Download:  about 22 MB (speech engine) + about 129 MB (voice model)
  On disk:   about 190 MB in $DEST

  Speech engine  sherpa-onnx $RUNTIME_VERSION   licence Apache-2.0
  Voice model    Supertonic 3                   code MIT, model weights OpenRAIL-M
                 (the weights carry use restrictions; read them at $MODEL_PAGE)

By installing you accept the terms of those licences, including the use restrictions of the model weights.
Sources: github.com/k2-fsa/sherpa-onnx releases (pinned versions, checked against SHA-256 values pinned in this script).

TXT

mkdir -p "$PARENT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agenthud-neural.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fetch() { # url file sha256
    echo "Downloading $(basename "$2")..."
    curl -fL --retry 2 --progress-bar -o "$2" "$1"
    local got
    got="$(shasum -a 256 "$2" | awk '{print $1}')"
    if [[ "$got" != "$3" ]]; then
        echo "Checksum mismatch for $(basename "$2")" >&2
        echo "  expected $3" >&2
        echo "  got      $got" >&2
        echo "Nothing was installed." >&2
        exit 1
    fi
    echo "Checksum ok: $(basename "$2")"
}

fetch "$RUNTIME_URL" "$WORK/runtime.tar.bz2" "$RUNTIME_SHA256"
fetch "$MODEL_URL" "$WORK/model.tar.bz2" "$MODEL_SHA256"

# Unpack next to the destination first, so a failure never leaves a half-installed folder.
STAGE="$WORK/stage"
mkdir -p "$STAGE/runtime/bin" "$STAGE/model" "$WORK/rt"
tar -xjf "$WORK/runtime.tar.bz2" -C "$WORK/rt"
cp "$WORK/rt/$RUNTIME_DIR_IN_ARCHIVE/bin/sherpa-onnx-offline-tts" "$STAGE/runtime/bin/"
cp -R "$WORK/rt/$RUNTIME_DIR_IN_ARCHIVE/lib" "$STAGE/runtime/lib"
tar -xjf "$WORK/model.tar.bz2" -C "$STAGE/model" --strip-components=1
printf 'engine sherpa-onnx %s\nmodel %s\n' "$RUNTIME_VERSION" "$MODEL_NAME" > "$STAGE/VERSION"

for f in runtime/bin/sherpa-onnx-offline-tts runtime/lib/libonnxruntime.dylib model/voice.bin model/tts.json \
         model/unicode_indexer.bin model/duration_predictor.int8.onnx model/text_encoder.int8.onnx \
         model/vector_estimator.int8.onnx model/vocoder.int8.onnx VERSION; do
    [[ -s "$STAGE/$f" ]] || { echo "The archive is missing $f; nothing was installed." >&2; exit 1; }
done

# Re-running replaces the old install.
rm -rf "$HOME/Library/Application Support/AgentHUD/neural-voice"
mv "$STAGE" "$DEST"
echo "Installed: $DEST"
echo "Switch it on in the Agent HUD settings: Voice > Voice engine > Neural."
