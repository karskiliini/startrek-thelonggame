# Star Trek: The Long Game — Project Workflow

## Project Type
Screenplay / story development. Not code. All content is markdown.

## Language
User communicates in Finnish and English interchangeably. Respond in the language the user uses.

## File Structure
- `00_opening_credits.md` through `14_anyones_to_win.md` — screenplay scenes
- `star_trek_long_game_bible.md` — story bible (worldbuilding, characters, thematic architecture)
- `audio/` — generated MP3 files (one per scene + full concatenation)
- `VibeVoice/` — TTS engine (gitignored, local only)
- `text_input/` — plain text chunks for TTS (gitignored, local only)
- `tts_sync.sh` — audio generation script
- `.tts_checksums` — MD5 checksums for change detection

## Git Workflow
- Push frequently. User wants changes on GitHub immediately.
- Commit messages should describe the creative change, not just "update file".
- Audio files are committed to the repo (not LFS).

## Audio Generation (TTS)
- Engine: VibeVoice-Realtime-0.5B, runs locally on M2 Pro via MPS
- Voice: Carter (single narrator)
- Run `zsh tts_sync.sh` to generate audio for changed scenes
- Script uses MD5 checksums to detect which `.md` files changed
- Texts over 500 words are split into ~500-word chunks (resplit threshold: 700 words)
- Chunk WAVs are cached locally — unchanged chunks reuse existing WAVs
- Each scene MP3 is pushed to GitHub immediately after generation
- Full screenplay MP3 (`star_trek_the_long_game_full.mp3`) is rebuilt and pushed after each scene
- Kill any running TTS before starting a new sync

## When User Says "puske muutokset, triggaa mp3"
1. `git add` + `git commit` + `git push` any uncommitted changes
2. Kill any running TTS processes
3. Run `nohup zsh tts_sync.sh > tts_log.txt 2>&1 &`
4. Verify with `sleep 5 && grep -E "^(OK|CHANGED|NEW|===)" tts_log.txt`

## Creative Rules
- User makes all creative decisions. Propose options, don't decide.
- When editing scenes, preserve the screenplay's restrained observational tone.
- Never add emojis to screenplay files.
- Marek = Charles Dance. Cooking metaphor is central to his character.
- K'Tagh = Tuco/Stallone energy. Aggressive, unpredictable, "mad dog".
- Sorak = Hugo Weaving. CIA. Never signs anything.
- Voss = Rosamund Pike / Robin Wright. Severe bun. Power is institutional.
- Hummer = Karl Urban (25-30y). Nobody's son.
- Kirk, Spock, McCoy = Shatner, Nimoy, Kelley at Star Trek VI age.
- Timeline: post-Star Trek VI. Khitomer Accords in force.

## Hummer Timeline
- 16: leaves Vega Colony
- 16-18: freight hauler
- 18-20: asteroid mining in Kerata belt
- 20-24: Starfleet Academy
- 24-28: service on other ships
- ~28: transferred to Enterprise (arranged by Sorak via Voss)
- ~30: film events (12 years since the belt)

## Scene Numbering
When adding new scenes, renumber all subsequent scenes. Update:
1. Filenames (`git mv`)
2. Scene headers inside files
3. Audio filenames in `audio/`
4. Both chapter lists in `tts_sync.sh`
5. Clear `.tts_checksums` after renumbering

## Key Metaphors
- Grey water: the murky reality of compromise. Never clears during the film.
- Marek's apron: Cardassian leather, family heirloom, knives in sheaths. Politics = cooking.
- "You are a tool": the worst thing you can call a Klingon.
- Mad dog doctrine: Klingon High Command deploys volatile commanders for deniable aggression.
