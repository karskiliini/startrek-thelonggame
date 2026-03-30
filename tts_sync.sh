#!/bin/zsh
# TTS Sync — generates audio only for changed chapters
# Splits any text over 500 words into ~500-word chunks for fast generation.
# Produces per-chunk MP3s, per-scene merged MP3, and full screenplay MP3.
set -e
cd /Users/marski/git/startrek-thelonggame

CHECKSUM_FILE=".tts_checksums"
MAX_WORDS=500
RESPLIT_THRESHOLD=700
source VibeVoice/.venv/bin/activate
mkdir -p audio text_input

chapters=(
    00_opening_credits
    02_orders
    03_the_dinner
    04_grey_water
    05_the_incident
    05b_the_call
    06_the_cook
    07_ready_room
    08_sorak_hand
    09_ktagh
    10_the_canyon
    11_the_conn
    12_kobayashi_maru
    13_anyones_to_win
    01_the_table
)

touch "$CHECKSUM_FILE"

get_old_sum() {
    grep "^${1}=" "$CHECKSUM_FILE" 2>/dev/null | cut -d= -f2
}

md_to_txt() {
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
        "$1"
}

# Split a text file into ~MAX_WORDS chunks at short-line boundaries
# Uses hysteresis: only re-splits if any existing chunk exceeds RESPLIT_THRESHOLD
split_text() {
    local infile="$1" prefix="$2"
    local total_words=$(wc -w < "$infile" | tr -d ' ')

    # If total is under MAX_WORDS, no splitting needed
    if [[ $total_words -le $MAX_WORDS ]]; then
        cp "$infile" "${prefix}_001.txt"
        echo 1
        return
    fi

    # Check if existing chunks are still usable (hysteresis)
    local existing_chunks=("${prefix}"_[0-9][0-9][0-9].txt(N))
    if [[ ${#existing_chunks[@]} -gt 0 ]]; then
        local needs_resplit=false
        for echunk in "${existing_chunks[@]}"; do
            local cwords=$(wc -w < "$echunk" | tr -d ' ')
            if [[ $cwords -gt $RESPLIT_THRESHOLD ]]; then
                needs_resplit=true
                break
            fi
        done

        if ! $needs_resplit; then
            # Re-distribute text into existing chunk structure
            # (same number of chunks, same split points)
            local nchunks=${#existing_chunks[@]}
            local total_lines=$(wc -l < "$infile" | tr -d ' ')
            local lines_per=$(( total_lines / nchunks ))
            local chunk=1 start=1

            while [[ $chunk -le $nchunks ]]; do
                if [[ $chunk -eq $nchunks ]]; then
                    tail -n +"$start" "$infile" > "${prefix}_$(printf '%03d' $chunk).txt"
                else
                    local target_end=$(( start + lines_per - 1 ))
                    local split_at=$(awk -v s="$((target_end - 15))" -v e="$((target_end + 15))" \
                        'NR >= s && NR <= e && length($0) < 5 { last=NR } END { print last }' "$infile")
                    [[ -z "$split_at" || "$split_at" -eq 0 ]] && split_at=$target_end
                    sed -n "${start},${split_at}p" "$infile" > "${prefix}_$(printf '%03d' $chunk).txt"
                    start=$((split_at + 1))
                fi
                chunk=$((chunk + 1))
            done
            echo $nchunks
            return
        fi

        # Needs resplit — clean old chunks and their WAV caches
        echo "(resplitting — a chunk exceeded $RESPLIT_THRESHOLD words)" >&2
        rm -f "${prefix}"_[0-9][0-9][0-9].txt
        rm -f audio/$(basename "$prefix")_[0-9][0-9][0-9].wav
        rm -f audio/$(basename "$prefix")_[0-9][0-9][0-9].md5
    fi

    # Fresh split at ~MAX_WORDS boundaries
    local num_chunks=$(( (total_words + MAX_WORDS - 1) / MAX_WORDS ))
    local total_lines=$(wc -l < "$infile" | tr -d ' ')
    local lines_per_chunk=$(( total_lines / num_chunks ))
    local chunk=1 start=1

    while [[ $chunk -le $num_chunks ]]; do
        if [[ $chunk -eq $num_chunks ]]; then
            tail -n +"$start" "$infile" > "${prefix}_$(printf '%03d' $chunk).txt"
        else
            local target_end=$(( start + lines_per_chunk - 1 ))
            local split_at=$(awk -v s="$((target_end - 15))" -v e="$((target_end + 15))" \
                'NR >= s && NR <= e && length($0) < 5 { last=NR } END { print last }' "$infile")
            [[ -z "$split_at" || "$split_at" -eq 0 ]] && split_at=$target_end
            sed -n "${start},${split_at}p" "$infile" > "${prefix}_$(printf '%03d' $chunk).txt"
            start=$((split_at + 1))
        fi
        chunk=$((chunk + 1))
    done
    echo $num_chunks
}

# Generate WAV from a text file
generate_wav() {
    local txt="$1" wav_out="$2"
    python VibeVoice/demo/realtime_model_inference_from_file.py \
        --model_path microsoft/VibeVoice-Realtime-0.5B \
        --txt_path "$txt" \
        --speaker_name Carter \
        --output_dir audio/ \
        --device mps
    # The script names output based on input filename
    local auto_name="audio/$(basename "${txt%.txt}")_generated.wav"
    if [[ -f "$auto_name" ]]; then
        mv "$auto_name" "$wav_out"
        return 0
    fi
    return 1
}

# Find changed files
changed=()
for base in "${chapters[@]}"; do
    md="${base}.md"
    [[ ! -f "$md" ]] && echo "SKIP: $md not found" && continue

    sum=$(md5 -q "$md")
    mp3="audio/${base}.mp3"
    old_sum=$(get_old_sum "$base")

    if [[ ! -f "$mp3" ]] || [[ "$old_sum" != "$sum" ]]; then
        changed+=("$base")
        [[ ! -f "$mp3" ]] && echo "NEW:     $base" || echo "CHANGED: $base"
    else
        echo "OK:      $base"
    fi
done

if [[ ${#changed[@]} -eq 0 ]]; then
    echo ""
    echo "=== All audio up to date ==="
    exit 0
fi

echo ""
echo "=== ${#changed[@]} chapter(s) need regeneration ==="
echo ""

for base in "${changed[@]}"; do
    md="${base}.md"
    txt="text_input/${base}.txt"
    mp3="audio/${base}.mp3"

    # Convert markdown to plain text
    md_to_txt "$md" > "$txt"

    word_count=$(wc -w < "$txt" | tr -d ' ')
    echo ""
    echo "=== Generating: $base ($word_count words) ==="
    echo "Started at: $(date)"

    # Split into chunks
    num_chunks=$(split_text "$txt" "text_input/${base}")
    echo "Chunks: $num_chunks"

    # Generate each chunk
    chunk_wavs=()
    all_ok=true
    for i in $(seq -f '%03g' 1 $num_chunks); do
        chunk_txt="text_input/${base}_${i}.txt"
        chunk_wav="audio/${base}_${i}.wav"
        chunk_words=$(wc -w < "$chunk_txt" | tr -d ' ')

        # Reuse existing WAV if the text hasn't changed
        if [[ -f "$chunk_wav" ]]; then
            chunk_wav_sum=$(md5 -q "$chunk_txt")
            chunk_wav_marker="audio/${base}_${i}.md5"
            old_chunk_sum=""
            [[ -f "$chunk_wav_marker" ]] && old_chunk_sum=$(cat "$chunk_wav_marker")
            if [[ "$chunk_wav_sum" == "$old_chunk_sum" ]]; then
                echo "--- Chunk $i ($chunk_words words) — cached ---"
                chunk_wavs+=("$chunk_wav")
                continue
            fi
        fi

        echo "--- Chunk $i ($chunk_words words) ---"

        if generate_wav "$chunk_txt" "$chunk_wav"; then
            # Save checksum for this chunk's text
            md5 -q "$chunk_txt" > "audio/${base}_${i}.md5"
            chunk_wavs+=("$chunk_wav")
        else
            echo "ERROR: chunk $i failed for $base"
            all_ok=false
            break
        fi
    done

    if ! $all_ok; then
        echo "ERROR: skipping $base"
        continue
    fi

    # Merge chunks into scene MP3
    if [[ ${#chunk_wavs[@]} -eq 1 ]]; then
        ffmpeg -y -i "${chunk_wavs[1]}" -codec:a libmp3lame -qscale:a 2 "$mp3" 2>/dev/null
    else
        concat_tmp=$(mktemp)
        for w in "${chunk_wavs[@]}"; do
            echo "file '$(pwd)/$w'" >> "$concat_tmp"
        done
        ffmpeg -y -f concat -safe 0 -i "$concat_tmp" -codec:a libmp3lame -qscale:a 2 "$mp3" 2>/dev/null
        rm "$concat_tmp"
    fi

    # Keep chunk WAVs locally for reuse (not pushed to git)

    echo "Created: $mp3"

    # Update checksum
    new_sum=$(md5 -q "$md")
    grep -v "^${base}=" "$CHECKSUM_FILE" > "${CHECKSUM_FILE}.tmp" 2>/dev/null || true
    echo "${base}=${new_sum}" >> "${CHECKSUM_FILE}.tmp"
    mv "${CHECKSUM_FILE}.tmp" "$CHECKSUM_FILE"

    # Push
    git add "$mp3"
    git commit -m "Update audio: ${base}.mp3

Regenerated after chapter edit ($num_chunks chunks).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
    git push
    echo "Pushed: $mp3 at $(date)"
done

# Combine all chapters into full screenplay MP3 (story order)
echo ""
echo "=== Combining all chapters ==="

all_chapters=(
    00_opening_credits
    01_the_table
    02_orders
    03_the_dinner
    04_grey_water
    05_the_incident
    05b_the_call
    06_the_cook
    07_ready_room
    08_sorak_hand
    09_ktagh
    10_the_canyon
    11_the_conn
    12_kobayashi_maru
    13_anyones_to_win
)

all_exist=true
for ch in "${all_chapters[@]}"; do
    if [[ ! -f "audio/${ch}.mp3" ]]; then
        echo "MISSING: audio/${ch}.mp3 — skipping combined file"
        all_exist=false
        break
    fi
done

if $all_exist; then
    concat_list=$(mktemp)
    for ch in "${all_chapters[@]}"; do
        echo "file '$(pwd)/audio/${ch}.mp3'" >> "$concat_list"
    done

    ffmpeg -y -f concat -safe 0 -i "$concat_list" -codec:a libmp3lame -qscale:a 2 audio/star_trek_the_long_game_full.mp3 2>/dev/null
    rm "$concat_list"

    echo "Created: audio/star_trek_the_long_game_full.mp3"

    git add audio/star_trek_the_long_game_full.mp3
    git commit -m "Update combined audio: star_trek_the_long_game_full.mp3

All chapters concatenated in story order.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
    git push
    echo "Pushed: combined MP3 at $(date)"
fi

echo ""
echo "=== Done at $(date) ==="
