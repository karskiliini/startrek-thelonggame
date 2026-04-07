#!/bin/zsh
# TTS Sync — content-addressed paragraph caching
# Processes BOTH v1/ and v2/ markdown files → audio/v1/ and audio/v2/ MP3s
# WAVs keyed purely by content hash (shared across versions)
# Note: no `set -e` — we handle errors explicitly so the script never dies
# mid-run and leaves audio generation incomplete.
cd /Users/marski/git/startrek-thelonggame || exit 1

CACHE=".cache"
MANIFEST="$CACHE/manifest"
MIN_MERGE=30
MAX_CHUNK=300
source VibeVoice/.venv/bin/activate
mkdir -p audio/v1 audio/v2 "$CACHE/wav" "$CACHE/txt" "$MANIFEST"

# v1 chapters (original structure)
v1_chapters=(
    00_opening_credits
    01_the_table
    02_orders
    03_the_dinner
    03b_the_leash
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

# v2 chapters (new Apocalypse Now structure)
v2_chapters=(
    01_the_dark
    03_orders
    03b_the_leash
    04_the_briefing
    05_the_dinner
    06_first_light
    07_vega
    08_sorak
    09_the_knife
    10_grey_water
    11_the_surface
    12_the_cook
    13_the_clock
    14_the_order
    15_sorak_hand
    16_ktagh
    17_the_belt
    18_the_canyon
    19_the_conn
    20_kobayashi_maru
    21_anyones_to_win
)

get_old_sum() {
    # $1 = version (v1/v2), $2 = base name
    local f="$MANIFEST/${1}_${2}.md5"
    if [[ -f "$f" ]]; then cat "$f"; else echo ""; fi
}

# Parse screenplay into voice-tagged blocks using Python parser
parse_voices() {
    # $1 = md file path, $2 = version, $3 = base name
    local md="$1" version="$2" scene="$3"
    python parse_voices.py "$md" "$CACHE/txt" "$MANIFEST/${version}_${scene}.hashes"
    local count=$(wc -l < "$MANIFEST/${version}_${scene}.hashes" | tr -d ' ')
    echo $count
}

# Generate WAVs for a list of jobs in one Python process (model loaded once).
# Input: lines of "txt_path|voice|wav_out" on stdin
# Returns 0 if all jobs succeeded, non-zero otherwise.
generate_wavs_batch() {
    local jobs_json="["
    local first=true
    local job_count=0
    while IFS='|' read -r txt voice wav; do
        [[ -z "$txt" ]] && continue
        if $first; then
            first=false
        else
            jobs_json+=","
        fi
        jobs_json+="{\"txt\":\"$txt\",\"voice\":\"$voice\",\"wav\":\"$wav\"}"
        job_count=$((job_count + 1))
    done
    jobs_json+="]"

    if [[ $job_count -eq 0 ]]; then
        return 0
    fi

    echo "$jobs_json" | python batch_tts.py --device mps
}

# Process one version (v1 or v2)
# Usage: process_version <version> <source_dir> <chapters_varname>
process_version() {
    local version="$1"
    local source_dir="$2"
    local -a chapters
    eval "chapters=(\"\${${3}[@]}\")"

    local audio_dir="audio/${version}"

    echo ""
    echo "=================================="
    echo "Processing ${version} (${source_dir}/)"
    echo "=================================="

    local changed=()
    for base in "${chapters[@]}"; do
        local md="${source_dir}/${base}.md"
        [[ ! -f "$md" ]] && echo "SKIP: $md not found" && continue

        local sum=$(md5 -q "$md")
        local mp3="${audio_dir}/${base}.mp3"
        local old_sum=$(get_old_sum "$version" "$base")

        if [[ ! -f "$mp3" ]] || [[ "$old_sum" != "$sum" ]]; then
            changed+=("$base")
            [[ ! -f "$mp3" ]] && echo "NEW:     ${version}/${base}" || echo "CHANGED: ${version}/${base}"
        else
            echo "OK:      ${version}/${base}"
        fi
    done

    if [[ ${#changed[@]} -eq 0 ]]; then
        echo "=== ${version}: All audio up to date ==="
        return 0
    fi

    echo ""
    echo "=== ${version}: ${#changed[@]} chapter(s) need regeneration ==="
    echo ""

    for base in "${changed[@]}"; do
        local md="${source_dir}/${base}.md"
        local mp3="${audio_dir}/${base}.mp3"

        echo ""
        echo "=== Generating ${version}/${base} ==="
        echo "Started at: $(date)"

        # Parse into voice-tagged blocks
        local num_chunks=$(parse_voices "$md" "$version" "$base")
        echo "Voice blocks: $num_chunks"

        # Separate cached blocks from those needing generation
        local chunk_wavs=()
        local cached_count=0
        local gen_count=0
        local jobs_input=""
        while IFS= read -r h; do
            local txt_file="$CACHE/txt/${h}.txt"
            local wav_file="$CACHE/wav/${h}.wav"
            local voice_file="$CACHE/txt/${h}.voice"

            if [[ -f "$wav_file" ]]; then
                cached_count=$((cached_count + 1))
            else
                local voice=$(cat "$voice_file")
                jobs_input+="${txt_file}|${voice}|${wav_file}"$'\n'
                gen_count=$((gen_count + 1))
            fi
            chunk_wavs+=("$wav_file")
        done < "$MANIFEST/${version}_${base}.hashes"

        echo "Cached: $cached_count | To generate: $gen_count"

        # Generate all missing blocks in one Python process (model loaded once)
        local all_ok=true
        if [[ $gen_count -gt 0 ]]; then
            if ! printf "%s" "$jobs_input" | generate_wavs_batch; then
                echo "ERROR: batch generation failed for ${version}/${base}"
                all_ok=false
            else
                # Verify all WAVs now exist
                for wav in "${chunk_wavs[@]}"; do
                    if [[ ! -f "$wav" ]]; then
                        echo "ERROR: expected WAV missing after batch: $wav"
                        all_ok=false
                        break
                    fi
                done
            fi
        fi

        if ! $all_ok; then
            echo "ERROR: skipping ${version}/${base}"
            continue
        fi

        # Merge paragraph WAVs into scene MP3
        if [[ ${#chunk_wavs[@]} -eq 1 ]]; then
            ffmpeg -y -i "${chunk_wavs[1]}" -codec:a libmp3lame -qscale:a 2 "$mp3" 2>/dev/null
        else
            local concat_tmp=$(mktemp)
            for w in "${chunk_wavs[@]}"; do
                echo "file '$(pwd)/$w'" >> "$concat_tmp"
            done
            ffmpeg -y -f concat -safe 0 -i "$concat_tmp" -codec:a libmp3lame -qscale:a 2 "$mp3" 2>/dev/null
            rm "$concat_tmp"
        fi

        echo "Created: $mp3"

        # Update scene checksum
        md5 -q "$md" > "$MANIFEST/${version}_${base}.md5"

        # Commit the MP3 — skip if ffmpeg produced byte-identical output
        git add "$mp3" 2>/dev/null || true
        if git diff --cached --quiet -- "$mp3" 2>/dev/null; then
            echo "No change to commit for $mp3 (byte-identical)"
        else
            if git commit -m "Update ${version} audio: ${base}.mp3

Regenerated ($gen_count of $num_chunks paragraphs, $cached_count cached).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>" 2>&1; then

                # Push with retry — handles concurrent pushes from voice_edit_setup.sh
                local push_ok=false
                for push_attempt in 1 2 3 4 5; do
                    if git push 2>&1; then
                        push_ok=true
                        break
                    fi
                    echo "Push attempt $push_attempt failed, rebasing and retrying..."
                    git pull --rebase --autostash 2>&1 || true
                    sleep 2
                done

                if $push_ok; then
                    echo "Pushed: $mp3 at $(date)"
                else
                    echo "WARNING: Could not push $mp3 after 5 attempts. Continuing..."
                fi
            else
                echo "WARNING: Commit failed for $mp3. Continuing..."
            fi
        fi
    done
}

# Process both versions
process_version "v1" "v1" "v1_chapters"
process_version "v2" "v2" "v2_chapters"

echo ""
echo "=== Done at $(date) ==="
