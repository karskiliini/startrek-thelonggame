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
- 18-20: asteroid mining in Cordia belt
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

## Screenplay Structure
- The full film follows a **five-act structure**: Setup → Rising Action → False Victory → Catastrophe → Resolution. The false victory must be convincing enough that the catastrophe is genuinely shocking.
- Every individual scene follows a **three-act structure**: Beginning state → Turn → New state. If a scene starts and ends in the same state, it's unnecessary — cut or merge it.
- Use the **scene-three-acts** skill when writing or reviewing scenes.

## Dramatic Principles
- **Escalation through geography.** Each physical stop on Enterprise's journey is worse than the last. Geography IS the drama. Don't tell the audience things are getting worse — show them a worse place.
- **Delayed character introduction.** Major antagonists (especially Marek) are introduced only at the moment of maximum impact. Other characters talk about them first — the audience builds expectations before the reality.
- **Dual-level antagonist.** One enemy is physically dangerous (K'Tagh — weapons, violence). The other is intellectually dangerous (Marek — paperwork, infrastructure, thirty years). The scene where the intellectual dominates the physical reveals the true power structure.
- **Constructed deniability.** The audience SEES the lie being built (K'Tagh ordering the attack, then rehearsing the denial). Characters don't know. Tension comes from this information asymmetry.
- **Show don't tell through contrast.** Beautiful from orbit, hell on the ground. Registry says 92% human, sensors say 51%. Official story vs. reality — shown through visual contrast, never through exposition.

## Casting Update
- K'Tagh = Raymond Cruz (Tuco, Breaking Bad)
- Toral (IKS Vor'nak captain) = Stallone in his 30s
- K'Tagh's ship: IKS Rek'thar — "The Dread"

## Thematic Parallels
- Sicario: Federation is already at war but refuses to call it war. Sorak is the handler operating in the grey zone.
- Israel-Palestine: 300,000 Cardassians who built everything, being told to leave their homes. Legal right vs. moral reality.
- USA-Mexico border: Labour the Federation needed, used, and now wants expelled. Infrastructure dependency.
- Apocalypse Now: The journey upriver. Each stop more lawless. Civilization fades.
