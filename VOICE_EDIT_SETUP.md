# Voice Edit Setup

The GitHub Pages player sends voice requests through an HTTPS Cloudflare tunnel
into the loopback-only voice editor on port 8742. Claude receives the selected scene as text and returns a JSON proposal with
all tools disabled, in an empty temporary working directory. The real repository stays untouched
until you review the displayed diff and explicitly approve it.

## Prerequisites

- macOS, Homebrew, Python 3.10+, Git push access to this repository.
- A logged-in Claude Code CLI **2.1.248 or newer** supporting `--restricted`.
  Unsupported versions fail closed; do not remove the restriction flags.
- Create the local token file once, with a random secret. This command writes the
  secret to disk without putting its value in shell history:

```bash
(umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > .voice_edit_token)
./voice_edit_setup.sh
```

The setup script installs the pinned web dependencies from requirements-voice.txt,
starts one server process, opens a Cloudflare tunnel, and prints its URL/token.
Treat the terminal output as a secret. Paste the URL and token into the player
settings on your own phone. The token is stored in that browser's localStorage;
use a trusted device and do not share its browser profile or terminal output.

`./voice_edit_setup.sh install`, `run`, and `stop` install, start, and stop the
service separately. Runtime `.voice_edit_*` files remain ignored by Git. The
published voice_edit_config.json contains only the tunnel URL.

## Preview and approval

1. Select a scene in version v1 or v2 and speak an editing request.
2. The server accepts only existing, tracked `v1/*.md` or `v2/*.md` scene files
   with simple filenames. Symlinks, directories and other repository files are
   rejected. A scene with uncommitted changes must be handled locally first.
3. Claude receives only that scene text and the transcription. All built-in
   tools, MCP servers, skills and slash commands are disabled; restricted mode
   excludes inherited user settings. Only the server can write scene files.
   The transcription is limited to 8,000 characters and the request to 16 KiB.
4. Review the diff. One proposal can be pending for up to ten minutes. Approval
   and cancellation carry its random ID and scene name. Restarting the server
   discards pending proposals, so request a fresh preview afterward.
5. Approval verifies the scene is still clean and byte-identical to the original,
   commits only that scene, pushes once, and triggers the existing TTS workflow.
   Cancellation only discards the proposal; neither action reverts your edits.

A push failure leaves the commit locally for manual resolution. The editor,
setup publisher and TTS publisher never auto-rebase or auto-stash user work;
these commits exclude unrelated staged files. TTS remains the existing local
VibeVoice/ffmpeg workflow and may regenerate other changed audio as before.

## Access and maintenance

The server binds to 127.0.0.1 and requires a token of at least 32 characters for
all mutation requests. Use HTTPS through the tunnel for phone access. Allowed
browser origins are https://karskiliini.github.io and the local development
origins http://localhost:8000 and http://127.0.0.1:8000. Opaque (`null`) and other
origins are rejected, independently of CORS. Keep the single server process;
proposal state is intentionally in memory and is not shared across workers.

Claude CLI is a trusted installed executable; restrictions depend on its current
implementation and managed administrator policy. Keep it updated. This change
does not audit or install the separate ML/audio stack, contact Claude, publish
changes, or regenerate audio during automated tests.

```bash
python3 -m pip install --only-binary=:all: -r requirements-voice.txt httpx pytest
python3 -m pytest tests/test_voice_edit_security.py -q
tail -f .voice_edit_server.log
tail -f .voice_edit_tunnel.log
```

Tests use fake Claude, Git and TTS providers and temporary scene fixtures.
