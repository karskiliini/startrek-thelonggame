#!/bin/bash
set -e
cd /Users/marski/git/startrek-thelonggame
source VibeVoice/.venv/bin/activate

chapters=(
    00_opening_credits
    03_the_dinner
    02_orders
    04_grey_water
    05_the_incident
    05b_the_call
    06_ready_room
    07_sorak_hand
    08_ktagh
    09_the_canyon
    10_the_con
    11_kobayashi_maru
    12_anyones_to_win
    01_the_table
)

for base in "${chapters[@]}"; do
    mp3="audio/${base}.mp3"

    # Skip if already generated
    if [ -f "$mp3" ]; then
        echo "SKIP: $mp3 already exists"
        continue
    fi

    echo ""
    echo "=== Generating: $base ==="
    echo "Started at: $(date)"
    echo ""

    python VibeVoice/demo/realtime_model_inference_from_file.py \
        --model_path microsoft/VibeVoice-Realtime-0.5B \
        --txt_path "text_input/${base}.txt" \
        --speaker_name Carter \
        --output_dir audio/ \
        --device mps

    wav="audio/${base}_generated.wav"
    if [ -f "$wav" ]; then
        ffmpeg -y -i "$wav" -codec:a libmp3lame -qscale:a 2 "$mp3" 2>/dev/null
        rm "$wav"
        echo "Converted: $mp3"

        git add "$mp3"
        git commit -m "Add audio: ${base}.mp3

Generated with VibeVoice-Realtime-0.5B (Carter voice)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
        git push
        echo "Pushed: $mp3 at $(date)"
    else
        echo "ERROR: WAV not generated for $base"
    fi
done

echo ""
echo "=== ALL DONE at $(date) ==="
