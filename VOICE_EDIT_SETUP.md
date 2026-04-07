# Voice Edit Setup

Voice-to-edit for the screenplay via your phone.

## TL;DR

```bash
./voice_edit_setup.sh
```

That's it. The script does everything. It will:

1. Check prerequisites (python3, claude CLI, brew)
2. Create a Python venv and install dependencies
3. Install `cloudflared` via Homebrew if missing
4. Generate an auth token (one-time, saved in `.voice_edit_token`)
5. Start the voice edit server (FastAPI)
6. Start the Cloudflare Tunnel
7. Print the tunnel URL and auth token for you to paste into the player

## Architecture

```
Phone (GitHub Pages player.html)
    │
    │ HTTPS with Bearer token
    ▼
Cloudflare Tunnel (https://xxx.trycloudflare.com)
    │
    ▼
Home computer (voice_edit_server.py, port 8742)
    │
    ▼
Claude Code CLI (uses your existing login)
    │
    ▼
Edits v1/ or v2/ scene file → git commit + push
```

The player on GitHub Pages loads mp3s and text as before, but adds a microphone
button. When pressed, it uses the browser's Web Speech API to transcribe your
voice, sends the transcription to your home computer via the tunnel, and the
server uses Claude Code CLI to apply the edit.

**No Anthropic API keys needed — uses your existing Claude Code login.**

## Commands

```bash
./voice_edit_setup.sh          # Install (if needed) + run
./voice_edit_setup.sh install  # Install only
./voice_edit_setup.sh run      # Run only (assumes installed)
./voice_edit_setup.sh stop     # Stop server and tunnel
```

## Prerequisites

- macOS with Homebrew
- Python 3.10+
- Claude Code CLI logged in (`claude` command works)
- This git repo configured to push to GitHub

## How to use

1. Run `./voice_edit_setup.sh`
2. Copy the printed **Server URL** and **Auth Token**
3. Open the player on your phone: `https://karskiliini.github.io/startrek-thelonggame/player.html`
4. Tap the gear icon (⚙) top right → paste URL and token → Save
5. Select a scene, switch to text view
6. Tap the microphone button
7. Speak a command, e.g. "Change Rek'thar to Nak'thar in this scene"
8. Wait for confirmation — the scene will reload with the change applied

The server auto-commits and pushes, so the edits land on GitHub immediately.

## Security

- Auth token is a shared secret stored in `.voice_edit_token` on your Mac (chmod 600)
- Token is stored in browser localStorage on your phone only
- Server only accepts requests with a valid Bearer token
- CORS restricted to `https://karskiliini.github.io`
- Path traversal protection — only scene files under the project directory
- Tunnel URL is random per run (unless you set up a named tunnel)
- `.voice_edit_*` files are gitignored

## What Claude does with your voice

The server sends your transcription to `claude -p` with a prompt that:

1. **Validates** the request is a screenplay edit (rejects random chatter)
2. **Applies** the edit using the Edit tool, preserving screenplay formatting
3. **Returns** either `REJECT: <reason>` or `DONE: <description>`

On `DONE`, the server commits and pushes the change to GitHub.

## Logs

```bash
tail -f .voice_edit_server.log   # FastAPI server logs
tail -f .voice_edit_tunnel.log   # Cloudflare Tunnel logs
```

## Stopping

```bash
./voice_edit_setup.sh stop
```

Or just close the terminal that ran it — the PID files will be stale but
nothing will be running.

## Optional: persistent tunnel URL

Quick tunnels get a new URL every restart. For a stable URL, set up a named
tunnel with a Cloudflare account:

```bash
cloudflared tunnel login
cloudflared tunnel create screenplay-voice
cloudflared tunnel route dns screenplay-voice voice.yourdomain.com
# Then modify voice_edit_setup.sh to run the named tunnel instead
```
