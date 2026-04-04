#!/usr/bin/env python3
"""Parse a Final Draft-style indented screenplay into voice-tagged blocks for TTS.

Format detection by indentation:
  0 spaces:   Action/narrative/scene headings → narrator (Carter)
  25 spaces:  Character name (ALL CAPS)       → narrator speaks the name
  15 spaces:  Parenthetical                   → narrator
  10 spaces:  Dialogue                        → character's voice

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
    "BONES": "Davis",
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

# Display names for narrator to speak
DISPLAY_NAMES = {
    "BONES": "Bones",
    "LT. COMMANDER": "Lieutenant Commander",
}

# Phonetic substitutions applied to all text
PHONETIC = [
    (r'\bVoss\b', 'Vawss'),
    (r'\bVOSS\b', 'VAWSS'),
    (r'\bKirk\b', 'Kurk'),
    (r'\bKIRK\b', 'KURK'),
    (r'\bEnterprise\b', 'Enter Prize'),
    (r'\bENTERPRISE\b', 'ENTER PRIZE'),
    (r"Rek'thar", "Rec tar"),
    (r"REK'THAR", "REC TAR"),
]

# Indentation thresholds
CHAR_NAME_INDENT = 20   # 25 spaces in practice, detect at 20+
PAREN_INDENT = 12       # 15 spaces in practice, detect at 12+
DIALOGUE_INDENT = 6     # 10 spaces in practice, detect at 6+


def format_name(raw_name):
    """Format character name for narrator to speak."""
    # Strip (CONT'D) suffix
    name = re.sub(r"\s*\(CONT'D\)\s*$", '', raw_name).strip()
    if name in DISPLAY_NAMES:
        return DISPLAY_NAMES[name]
    return name.title()


def apply_phonetic(text):
    for pattern, replacement in PHONETIC:
        text = re.sub(pattern, replacement, text)
    return text


def get_indent(line):
    """Return number of leading spaces."""
    return len(line) - len(line.lstrip(' '))


def voice_for_character(char_name):
    """Look up voice for a character name."""
    for key, voice in VOICE_MAP.items():
        if key in char_name:
            return voice
    return DEFAULT_VOICE


def parse_screenplay(filepath):
    """Parse indented screenplay into voice-tagged blocks."""
    with open(filepath, 'r') as f:
        lines = f.readlines()

    blocks = []
    current_voice = DEFAULT_VOICE
    current_char_voice = DEFAULT_VOICE  # voice for current character's dialogue
    current_text = []

    def flush():
        nonlocal current_text
        text = '\n'.join(current_text).strip()
        if text:
            text = apply_phonetic(text)
            blocks.append({"voice": current_voice, "text": text})
        current_text = []

    for raw_line in lines:
        line = raw_line.rstrip()

        # Skip markdown headers
        if re.match(r'^#{1,2}\s', line):
            continue

        # Empty line — just a separator
        if line.strip() == '':
            continue

        indent = get_indent(line)
        content = line.strip()

        # Character name (25+ spaces, ALL CAPS)
        if indent >= CHAR_NAME_INDENT:
            flush()
            # Determine character voice
            current_char_voice = voice_for_character(content)
            # Narrator speaks the name
            current_voice = DEFAULT_VOICE
            current_text.append(format_name(content) + ".")
            flush()
            # Set voice for upcoming dialogue
            current_voice = current_char_voice
            continue

        # Parenthetical (15 spaces, starts with '(')
        if indent >= PAREN_INDENT and content.startswith('('):
            # (beat) and (pause) are not spoken — they create a natural pause
            # by splitting the text block (the TTS treats separate blocks as pauses)
            if content.strip('() ').lower() in ('beat', 'pause', 'beat — '):
                flush()
                continue
            # Other parentheticals (stage directions) stay with current speaker
            current_text.append(content)
            continue

        # Dialogue (10 spaces)
        if indent >= DIALOGUE_INDENT:
            if current_voice != current_char_voice:
                flush()
                current_voice = current_char_voice
            current_text.append(content)
            continue

        # Action/narrative/scene headings (0 indent)
        if current_voice != DEFAULT_VOICE:
            flush()
            current_voice = DEFAULT_VOICE
        current_text.append(content)

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
