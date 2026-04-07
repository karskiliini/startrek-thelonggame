# Voice Edit Setup

How to enable voice-to-edit for the screenplay via your phone.

## Architecture

```
Phone (GitHub Pages player.html)
    │
    │ HTTPS (with Bearer token)
    ▼
Cloudflare Tunnel (public URL)
    │
    ▼
Home computer (voice_edit_server.py)
    │
    ▼
Claude Code CLI (uses your existing login)
    │
    ▼
Edits v1/ or v2/ scene file → git commit + push
```

The player on GitHub Pages loads mp3s and text as before, but adds a microphone
button. When pressed, it uses the browser's Web Speech API to transcribe your
voice, sends the transcription to your home computer via a Cloudflare Tunnel,
and your home computer uses Claude Code CLI to apply the edit.

**Your Claude Code subscription handles the LLM call — no API keys needed.**

## Prerequisites

- Python 3.10+
- Claude Code CLI installed and logged in (`claude` command works)
- Cloudflare Tunnel (`cloudflared`) — free, no account required for quick tunnels
- git repository cloned and configured to push to GitHub

## 1. Install Python dependencies

```bash
cd /Users/marski/git/startrek-thelonggame
python3 -m venv .venv-voice
source .venv-voice/bin/activate
pip install fastapi uvicorn pydantic
```

## 2. Install Cloudflare Tunnel

```bash
brew install cloudflare/cloudflare/cloudflared
```

## 3. Generate an auth token

```bash
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
```

Save the output — you will need it for both the server and the phone.

## 4. Start the server

In one terminal:

```bash
cd /Users/marski/git/startrek-thelonggame
source .venv-voice/bin/activate
export VOICE_EDIT_TOKEN="your-generated-token-here"
python voice_edit_server.py
```

The server runs on `http://localhost:8742`.

## 5. Start the tunnel

In another terminal:

```bash
cloudflared tunnel --url http://localhost:8742
```

Cloudflared prints a public URL like `https://random-words.trycloudflare.com`.
Copy this URL.

## 6. Configure the player

1. Open the player on your phone (GitHub Pages URL)
2. Tap the settings icon (gear) in the top right
3. Paste the Cloudflare Tunnel URL
4. Paste the auth token
5. Save

The settings are stored in localStorage on your phone. Nobody else can access them.

## 7. Use it

1. Open a scene in the text view
2. Tap the microphone button
3. Speak a command, e.g. "Change Rek'thar to Nak'thar"
4. The browser transcribes your speech
5. The transcription is sent to your home computer
6. Claude Code applies the edit and commits
7. The player reloads the updated scene

## Security notes

- The auth token is a shared secret between the phone and the server
- The token is stored in localStorage on the phone (not exposed in the URL or git)
- The server only accepts requests with a valid Bearer token
- CORS is restricted to `https://karskiliini.github.io`
- The Cloudflare Tunnel URL is random and changes every time you restart cloudflared (unless you use a named tunnel)
- Path traversal is prevented — the server only accepts scene files under the project directory

## Stopping

- Ctrl+C the server
- Ctrl+C the tunnel

The player.html on GitHub Pages still works for listening and reading, but the microphone button will fail until both are running again.

## Optional: Persistent tunnel URL

Quick tunnels get a new random URL every restart. If you want a persistent URL:

```bash
cloudflared tunnel login
cloudflared tunnel create screenplay-voice
cloudflared tunnel route dns screenplay-voice voice.yourdomain.com
cloudflared tunnel run --url http://localhost:8742 screenplay-voice
```

This requires a Cloudflare account and a domain.
