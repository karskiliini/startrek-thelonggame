#!/bin/zsh
# TTS Sync — paragraph-level caching
# Splits at --- markers, merges tiny paragraphs (< 30 words).
# Caches WAVs per paragraph — only regenerates changed paragraphs.
# All intermediate files live in .cache/
set -e
cd /Users/marski/git/startrek-thelonggame

CACHE=".cache"
CHECKSUM_FILE="$CACHE/checksums"
MIN_MERGE=30
source VibeVoice/.venv/bin/activate
mkdir -p audio "$CACHE"

chapters=(
    00_opening_credits
    02_orders
    03_the_dinner
    04_grey_water
    05_the_incident
    06_the_call
    07_the_cook
    08_the_order
    09_ready_room
    10_sorak_hand
    11_ktagh
    12_the_canyon
    13_the_conn
    14_kobayashi_maru
    15_anyones_to_win
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
        -e 's/^---$/===SPLIT===/' \
        -e '/^`/d' \
        -e '/^>/ s/^>[[:space:]]*//' \
        -e '/^[[:space:]]*$/d' \
        "$1"
}

# Split text at ===SPLIT=== markers into paragraph chunks
# Merges adjacent tiny sections (< MIN_MERGE words) with next section
split_paragraphs() {
    local infile="$1" prefix="$2"
    local total_words=$(wc -w < "$infile" | tr -d ' ')

    if ! grep -q '===SPLIT===' "$infile" || [[ $total_words -le $MIN_MERGE ]]; then
        grep -v '===SPLIT===' "$infile" > "${prefix}_001.txt"
        echo 1
        return
    fi

    local tmpdir=$(mktemp -d)
    awk -v prefix="$tmpdir/raw_" '
        BEGIN { chunk=1; outfile=prefix sprintf("%03d", chunk) ".txt" }
        /^===SPLIT===$/ {
            close(outfile)
            chunk++
            outfile=prefix sprintf("%03d", chunk) ".txt"
            next
        }
        { print >> outfile }
    ' "$infile"

    local raw_files=("$tmpdir"/raw_[0-9][0-9][0-9].txt(N))
    local merged_chunks=()
    local accum=""
    local accum_words=0

    for rf in "${raw_files[@]}"; do
        [[ ! -s "$rf" ]] && continue
        local content=$(cat "$rf")
        local wc=$(echo "$content" | wc -w | tr -d ' ')

        if [[ $accum_words -gt 0 ]]; then
            accum="${accum}
${content}"
            accum_words=$((accum_words + wc))
        else
            accum="$content"
            accum_words=$wc
        fi

        if [[ $accum_words -ge $MIN_MERGE ]]; then
            merged_chunks+=("$accum")
            accum=""
            accum_words=0
        fi
    done

    if [[ $accum_words -gt 0 ]]; then
        if [[ ${#merged_chunks[@]} -gt 0 ]]; then
            local last_idx=${#merged_chunks[@]}
            merged_chunks[$last_idx]="${merged_chunks[$last_idx]}
${accum}"
        else
            merged_chunks+=("$accum")
        fi
    fi

    local num_chunks=${#merged_chunks[@]}
    # Write hash-keyed txt files, output ordered hash list
    local hash_list=()
    for chunk_content in "${merged_chunks[@]}"; do
        local chunk_hash=$(echo "$chunk_content" | md5)
        echo "$chunk_content" > "${prefix}_${chunk_hash}.txt"
        hash_list+=("$chunk_hash")
    done

    rm -rf "$tmpdir"
    # Return num_chunks on stdout, write hash list to .hashes file
    printf '%s\n' "${hash_list[@]}" > "${prefix}.hashes"
    echo $num_chunks
}

# Generate WAV from a text file
generate_wav() {
    local txt="$1" wav_out="$2"
    python VibeVoice/demo/realtime_model_inference_from_file.py \
        --model_path microsoft/VibeVoice-Realtime-0.5B \
        --txt_path "$txt" \
        --speaker_name Carter \
        --output_dir "$CACHE/" \
        --device mps
    local auto_name="${CACHE}/$(basename "${txt%.txt}")_generated.wav"
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
    txt="${CACHE}/${base}.txt"
    mp3="audio/${base}.mp3"

    # Convert markdown to plain text
    md_to_txt "$md" > "$txt"

    word_count=$(wc -w < "$txt" | tr -d ' ')
    echo ""
    echo "=== Generating: $base ($word_count words) ==="
    echo "Started at: $(date)"

    # Split into paragraph chunks
    num_chunks=$(split_paragraphs "$txt" "${CACHE}/${base}")
    echo "Paragraphs: $num_chunks"

    # Generate each paragraph — keyed by content hash
    chunk_wavs=()
    all_ok=true
    cached_count=0
    gen_count=0
    local para_num=0
    while IFS= read -r chunk_hash; do
        para_num=$((para_num + 1))
        chunk_txt="${CACHE}/${base}_${chunk_hash}.txt"
        chunk_wav="${CACHE}/${base}_${chunk_hash}.wav"
        chunk_words=$(wc -w < "$chunk_txt" | tr -d ' ')

        # Reuse existing WAV if content matches (hash-keyed)
        if [[ -f "$chunk_wav" ]]; then
            cached_count=$((cached_count + 1))
            chunk_wavs+=("$chunk_wav")
            continue
        fi

        gen_count=$((gen_count + 1))
        echo "--- Paragraph $para_num/$num_chunks ($chunk_words words) ---"

        if generate_wav "$chunk_txt" "$chunk_wav"; then
            chunk_wavs+=("$chunk_wav")
        else
            echo "ERROR: paragraph $para_num failed for $base"
            all_ok=false
            break
        fi
    done < "${CACHE}/${base}.hashes"

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
    new_sum=$(md5 -q "$md")
    grep -v "^${base}=" "$CHECKSUM_FILE" > "${CHECKSUM_FILE}.tmp" 2>/dev/null || true
    echo "${base}=${new_sum}" >> "${CHECKSUM_FILE}.tmp"
    mv "${CHECKSUM_FILE}.tmp" "$CHECKSUM_FILE"

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
        04_grey_water 05_the_incident 06_the_call 07_the_cook
        08_the_order 09_ready_room 10_sorak_hand 11_ktagh
        12_the_canyon 13_the_conn 14_kobayashi_maru 15_anyones_to_win
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
