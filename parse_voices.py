#!/usr/bin/env python3
"""Parse a screenplay markdown file into voice-tagged blocks for TTS.

Output format: one block per line as JSON:
  {"voice": "Carter", "text": "The kitchen was not large..."}

Voice mapping:
  KIRK     → Mike
  McCOY    → Davis
  SPOCK    → Davis
  VOSS     → Grace
  HUMMER   → Frank
  narrator → Carter (default)
  all others → Carter
"""

import json
import os
import re
import sys

VOICE_MAP = {
    "KIRK": "Mike",
    "McCOY": "Davis",
    "SPOCK": "Davis",
    "ADMIRAL VOSS": "Grace",
    "VOSS": "Grace",
    "HUMMER": "Frank",
    "MAREK": "Davis",
    "K'TAGH": "Davis",
    "SORAK": "Davis",
    "GENERAL KORD": "Davis",
    "CARDASSIAN": "Davis",
    "KLINGON": "Davis",
    "CHEN": "Davis",
}
DEFAULT_VOICE = "Carter"

# Phonetic substitutions applied to all text
PHONETIC = [
    (r'\bVoss\b', 'Vawss'),
    (r'\bVOSS\b', 'VAWSS'),
    (r'\bKirk\b', 'Kurk'),
    (r'\bKIRK\b', 'KURK'),
]

def apply_phonetic(text):
    for pattern, replacement in PHONETIC:
        text = re.sub(pattern, replacement, text)
    return text

def strip_md(line):
    """Strip markdown formatting from a line."""
    line = re.sub(r'\*\*', '', line)
    line = re.sub(r'\*', '', line)
    return line

def parse_screenplay(filepath):
    """Parse markdown screenplay into voice-tagged blocks."""
    with open(filepath, 'r') as f:
        lines = f.readlines()

    blocks = []
    current_voice = DEFAULT_VOICE
    current_text = []

    def flush():
        nonlocal current_text
        text = '\n'.join(current_text).strip()
        if text:
            text = apply_phonetic(text)
            blocks.append({"voice": current_voice, "text": text})
        current_text = []

    for line in lines:
        line = line.rstrip()

        # Skip headers, scene end markers
        if re.match(r'^#{1,2}\s', line):
            continue
        if line.startswith('*End of Scene'):
            continue
        if line == '---':
            continue

        # Scene headings (backtick lines) — narrator
        if re.match(r'^`.*`$', line):
            flush()
            current_voice = DEFAULT_VOICE
            heading = line.strip('`').strip()
            if heading:
                current_text.append(heading)
            flush()
            continue

        # Character name line: **NAME** or **NAME** *(CONT'D)*
        char_match = re.match(r'^\*\*([A-Z][A-Z \'\-]+?)(?:\s*\*\*\s*\*\(CONT\'D\)\*|\*\*)', line)
        if char_match:
            flush()
            char_name = char_match.group(1).strip()
            # Check for parenthetical on same line: **NAME** *(stage direction)*
            rest = line[char_match.end():].strip()

            # Map character to voice
            current_voice = DEFAULT_VOICE
            for key, voice in VOICE_MAP.items():
                if key in char_name:
                    current_voice = voice
                    break
            continue

        # Parenthetical: *(quiet)* — keep with current speaker
        if re.match(r'^\*\(.*\)\*$', line):
            paren = strip_md(line)
            current_text.append(paren)
            continue

        # Empty line — paragraph break within same speaker
        if line.strip() == '':
            continue

        # Block quote
        if line.startswith('>'):
            line = line.lstrip('> ')

        # Regular text — strip markdown
        clean = strip_md(line)
        if clean.strip():
            current_text.append(clean.strip())

    flush()

    # Merge consecutive blocks with same voice
    merged = []
    for block in blocks:
        if merged and merged[-1]["voice"] == block["voice"]:
            merged[-1]["text"] += "\n" + block["text"]
        else:
            merged.append(block)

    return merged

if __name__ == "__main__":
    if len(sys.argv) == 2:
        # Legacy mode: print JSONL to stdout
        blocks = parse_screenplay(sys.argv[1])
        for block in blocks:
            print(json.dumps(block))
    elif len(sys.argv) == 4:
        # File mode: write hash-keyed files
        import hashlib
        md_file = sys.argv[1]
        cache_dir = sys.argv[2]
        hashes_file = sys.argv[3]

        os.makedirs(cache_dir, exist_ok=True)

        blocks = parse_screenplay(md_file)
        hash_list = []
        for block in blocks:
            key = f"{block['voice']}:{block['text']}"
            h = hashlib.md5(key.encode()).hexdigest()

            with open(os.path.join(cache_dir, f"{h}.txt"), 'w') as f:
                f.write(block['text'])
            with open(os.path.join(cache_dir, f"{h}.voice"), 'w') as f:
                f.write(block['voice'])

            hash_list.append(h)

        with open(hashes_file, 'w') as f:
            f.write('\n'.join(hash_list) + '\n')
    else:
        print(f"Usage: {sys.argv[0]} <scene.md> [cache_dir hashes_file]", file=sys.stderr)
        sys.exit(1)
