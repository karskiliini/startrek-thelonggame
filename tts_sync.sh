#!/bin/zsh
# TTS Sync — content-addressed paragraph caching
# WAVs keyed purely by content hash — no scene prefix, no numbering.
# .cache/manifest.json maps scenes → ordered hash lists.
# All intermediate files live in .cache/
set -e
cd /Users/marski/git/startrek-thelonggame

CACHE=".cache"
MANIFEST="$CACHE/manifest"
MIN_MERGE=30
MAX_CHUNK=300
source VibeVoice/.venv/bin/activate
mkdir -p audio "$CACHE/wav" "$CACHE/txt"

chapters=(
    00_opening_credits
    01_the_table
    02_orders
    03_the_dinner
    04_grey_water
    05_the_incident
    06_the_cook
    07_the_call
    08_the_order
    09_ready_room
    10_sorak_hand
    11_ktagh
    12_the_belt
    13_the_canyon
    14_the_conn
    15_kobayashi_maru
    16_anyones_to_win
)

mkdir -p "$MANIFEST"

get_old_sum() {
    local f="$MANIFEST/${1}.md5"
    if [[ -f "$f" ]]; then cat "$f"; else echo ""; fi
}

md_to_txt() {
    # Legacy single-voice conversion (unused in multi-voice mode)
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
        -e 's/Voss/Vawss/g' \
        -e 's/VOSS/VAWSS/g' \
        -e 's/Kirk/Kurk/g' \
        -e 's/KIRK/KURK/g' \
        "$1"
}

# Parse screenplay into voice-tagged blocks using Python parser
parse_voices() {
    local md="$1" scene="$2"
    # Python writes hash-keyed files directly and outputs hash list
    python parse_voices.py "$md" "$CACHE/txt" "$MANIFEST/${scene}.hashes"
    local count=$(wc -l < "$MANIFEST/${scene}.hashes" | tr -d ' ')
    echo $count
}

# Split text at blank lines into paragraph chunks.
# Merges tiny adjacent paragraphs (< MIN_MERGE words), caps at MAX_CHUNK.
# Writes hash-keyed txt files to $CACHE/txt/, hash list to manifest.
split_paragraphs() {
    local infile="$1" scene="$2"
    local merged_chunks=()
    local accum="" accum_words=0
    local line_buf="" buf_words=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
            if [[ $buf_words -gt 0 ]]; then
                if [[ $accum_words -gt 0 ]]; then
                    accum="${accum}
${line_buf}"
                else
                    accum="$line_buf"
                fi
                accum_words=$((accum_words + buf_words))
                if [[ $accum_words -ge $MAX_CHUNK ]] || [[ $buf_words -ge $MIN_MERGE ]]; then
                    merged_chunks+=("$accum")
                    accum="" accum_words=0
                fi
                line_buf="" buf_words=0
            fi
        else
            if [[ -n "$line_buf" ]]; then
                line_buf="${line_buf}
${line}"
            else
                line_buf="$line"
            fi
            local lw=$(echo "$line" | wc -w | tr -d ' ')
            buf_words=$((buf_words + lw))
        fi
    done < "$infile"

    # Flush remaining
    if [[ $buf_words -gt 0 ]]; then
        if [[ $accum_words -gt 0 ]]; then accum="${accum}
${line_buf}"; else accum="$line_buf"; fi
        accum_words=$((accum_words + buf_words))
    fi
    [[ $accum_words -gt 0 ]] && merged_chunks+=("$accum")

    # Fallback
    if [[ ${#merged_chunks[@]} -eq 0 ]]; then
        local content=$(cat "$infile")
        local h=$(echo "$content" | md5)
        echo "$content" > "$CACHE/txt/${h}.txt"
        echo "$h" > "$MANIFEST/${scene}.hashes"
        echo 1
        return
    fi

    local hash_list=()
    for chunk_content in "${merged_chunks[@]}"; do
        local h=$(echo "$chunk_content" | md5)
        echo "$chunk_content" > "$CACHE/txt/${h}.txt"
        hash_list+=("$h")
    done
    printf '%s\n' "${hash_list[@]}" > "$MANIFEST/${scene}.hashes"
    echo ${#merged_chunks[@]}
}

# Generate WAV from a text file with specified voice
generate_wav() {
    local txt="$1" wav_out="$2" voice="${3:-Carter}"
    python VibeVoice/demo/realtime_model_inference_from_file.py \
        --model_path microsoft/VibeVoice-Realtime-0.5B \
        --txt_path "$txt" \
        --speaker_name "$voice" \
        --output_dir "$CACHE/" \
        --device mps
    local auto_name="$CACHE/$(basename "${txt%.txt}")_generated.wav"
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
    mp3="audio/${base}.mp3"

    echo ""
    echo "=== Generating: $base ==="
    echo "Started at: $(date)"

    # Parse into voice-tagged blocks
    num_chunks=$(parse_voices "$md" "$base")
    echo "Voice blocks: $num_chunks"

    # Generate each block with correct voice
    chunk_wavs=()
    all_ok=true
    cached_count=0
    gen_count=0
    para_num=0
    while IFS= read -r h; do
        para_num=$((para_num + 1))
        txt_file="$CACHE/txt/${h}.txt"
        wav_file="$CACHE/wav/${h}.wav"
        voice_file="$CACHE/txt/${h}.voice"
        chunk_words=$(wc -w < "$txt_file" | tr -d ' ')
        voice=$(cat "$voice_file")

        if [[ -f "$wav_file" ]]; then
            cached_count=$((cached_count + 1))
            chunk_wavs+=("$wav_file")
            continue
        fi

        gen_count=$((gen_count + 1))
        echo "--- Block $para_num/$num_chunks ($chunk_words words, $voice) ---"

        if generate_wav "$txt_file" "$wav_file" "$voice"; then
            chunk_wavs+=("$wav_file")
        else
            echo "ERROR: block $para_num failed for $base"
            all_ok=false
            break
        fi
    done < "$MANIFEST/${base}.hashes"

    echo "Cached: $cached_count | Generated: $gen_count"

    if ! $all_ok; then
        echo "ERROR: skipping $base"
        continue
    fi

    # Merge paragraph WAVs into scene MP3
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

    echo "Created: $mp3"

    # Update scene checksum
    md5 -q "$md" > "$MANIFEST/${base}.md5"

    # Push
    git add "$mp3"
    git commit -m "Update audio: ${base}.mp3

Regenerated ($gen_count of $num_chunks paragraphs, $cached_count cached).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
    git push
    echo "Pushed: $mp3 at $(date)"

    # Rebuild full MP3 after each scene
    all_chapters=(
        00_opening_credits 01_the_table 02_orders 03_the_dinner
        04_grey_water 05_the_incident 06_the_cook 07_the_call
        08_the_order 09_ready_room 10_sorak_hand 11_ktagh
        12_the_belt 13_the_canyon 14_the_conn 15_kobayashi_maru 16_anyones_to_win
    )
    all_exist=true
    for ch in "${all_chapters[@]}"; do
        [[ ! -f "audio/${ch}.mp3" ]] && all_exist=false && break
    done
    if $all_exist; then
        concat_list=$(mktemp)
        for ch in "${all_chapters[@]}"; do
            echo "file '$(pwd)/audio/${ch}.mp3'" >> "$concat_list"
        done
        ffmpeg -y -f concat -safe 0 -i "$concat_list" -codec:a libmp3lame -qscale:a 2 audio/star_trek_the_long_game_full.mp3 2>/dev/null
        rm "$concat_list"
        git add audio/star_trek_the_long_game_full.mp3
        git commit -m "Update full audio (after ${base}.mp3)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
        git push
        echo "Updated full MP3 at $(date)"
    fi
done

echo ""
echo "=== Done at $(date) ==="
