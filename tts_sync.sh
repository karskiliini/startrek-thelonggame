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
source VibeVoice/.venv/bin/activate
mkdir -p audio "$CACHE/wav" "$CACHE/txt"

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

mkdir -p "$MANIFEST"

get_old_sum() {
    local f="$MANIFEST/${1}.md5"
    [[ -f "$f" ]] && cat "$f"
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

# Split text at ===SPLIT=== markers, merge tiny paragraphs.
# Writes hash-keyed txt files to $CACHE/txt/ and hash list to manifest.
split_paragraphs() {
    local infile="$1" scene="$2"
    local total_words=$(wc -w < "$infile" | tr -d ' ')

    if ! grep -q '===SPLIT===' "$infile" || [[ $total_words -le $MIN_MERGE ]]; then
        local content=$(grep -v '===SPLIT===' "$infile")
        local h=$(echo "$content" | md5)
        echo "$content" > "$CACHE/txt/${h}.txt"
        echo "$h" > "$MANIFEST/${scene}.hashes"
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

    # Write hash-keyed txt files and ordered hash list
    local hash_list=()
    for chunk_content in "${merged_chunks[@]}"; do
        local h=$(echo "$chunk_content" | md5)
        echo "$chunk_content" > "$CACHE/txt/${h}.txt"
        hash_list+=("$h")
    done

    rm -rf "$tmpdir"
    printf '%s\n' "${hash_list[@]}" > "$MANIFEST/${scene}.hashes"
    echo ${#merged_chunks[@]}
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

    # Convert markdown to plain text
    local scene_txt="$CACHE/txt/${base}_full.txt"
    md_to_txt "$md" > "$scene_txt"

    word_count=$(wc -w < "$scene_txt" | tr -d ' ')
    echo ""
    echo "=== Generating: $base ($word_count words) ==="
    echo "Started at: $(date)"

    # Split into paragraph chunks
    num_chunks=$(split_paragraphs "$scene_txt" "$base")
    echo "Paragraphs: $num_chunks"

    # Generate each paragraph — keyed purely by content hash
    chunk_wavs=()
    all_ok=true
    cached_count=0
    gen_count=0
    local para_num=0
    while IFS= read -r h; do
        para_num=$((para_num + 1))
        local txt_file="$CACHE/txt/${h}.txt"
        local wav_file="$CACHE/wav/${h}.wav"
        local chunk_words=$(wc -w < "$txt_file" | tr -d ' ')

        if [[ -f "$wav_file" ]]; then
            cached_count=$((cached_count + 1))
            chunk_wavs+=("$wav_file")
            continue
        fi

        gen_count=$((gen_count + 1))
        echo "--- Paragraph $para_num/$num_chunks ($chunk_words words) ---"

        if generate_wav "$txt_file" "$wav_file"; then
            chunk_wavs+=("$wav_file")
        else
            echo "ERROR: paragraph $para_num failed for $base"
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
