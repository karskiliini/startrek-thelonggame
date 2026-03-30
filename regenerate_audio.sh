#!/bin/bash
# Regenerates audio for a single chapter .md file, then commits and pushes.
# Usage: ./regenerate_audio.sh 01_the_table.md

set -e
cd /Users/marski/git/startrek-thelonggame

MD_FILE="$1"
if [ -z "$MD_FILE" ]; then
    echo "Usage: $0 <chapter.md>"
    exit 1
fi

# Extract base name
BASE=$(basename "$MD_FILE" .md)

# Skip non-chapter files (e.g. the bible)
case "$BASE" in
    00_*|01_*|02_*|03_*|04_*|05_*|05b_*|06_*|07_*|08_*|09_*|10_*|11_*|12_*) ;;
    *) echo "Not a chapter file, skipping: $MD_FILE"; exit 0 ;;
esac

source VibeVoice/.venv/bin/activate
mkdir -p text_input audio

# Convert markdown to plain text
sed -E \
    -e 's/^#+[[:space:]]*//' \
    -e "s/^\*\*([A-Z ]+)\*\* \*\(CONT'D\)\*/\1 (continued):/g" \
    -e 's/^\*\*([A-Z ]+)\*\* \*\(([^)]+)\)\*/\1 (\2):/g' \
    -e 's/^\*\*([A-Z ]+)\*\*/\1:/g' \
    -e 's/\*\(([^)]+)\)\*/(\1)/g' \
    -e 's/\*\*//g' \
    -e 's/\*//g' \
    -e '/^---$/d' \
    -e '/^`/d' \
    -e '/^>/ s/^>[[:space:]]*//' \
    -e '/^[[:space:]]*$/d' \
    "$MD_FILE" > "text_input/${BASE}.txt"

echo "[audio] Generating TTS for: $BASE"

# Run VibeVoice
python VibeVoice/demo/realtime_model_inference_from_file.py \
    --model_path microsoft/VibeVoice-Realtime-0.5B \
    --txt_path "text_input/${BASE}.txt" \
    --speaker_name Carter \
    --output_dir audio/ \
    --device mps 2>&1 | tail -10

WAV="audio/${BASE}_generated.wav"
MP3="audio/${BASE}.mp3"

if [ -f "$WAV" ]; then
    ffmpeg -y -i "$WAV" -codec:a libmp3lame -qscale:a 2 "$MP3" 2>/dev/null
    rm "$WAV"
    echo "[audio] Created: $MP3"

    git add "$MP3"
    git commit -m "Update audio: ${BASE}.mp3

Regenerated after chapter edit.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
    git push
    echo "[audio] Pushed: $MP3"
else
    echo "[audio] ERROR: WAV not generated for $BASE"
    exit 1
fi
