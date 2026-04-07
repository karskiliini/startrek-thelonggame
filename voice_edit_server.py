#!/usr/bin/env python3
"""Voice edit server — receives transcribed voice commands from the web player
and applies them to screenplay scenes using Claude Code CLI.

Usage:
  export VOICE_EDIT_TOKEN="your-secret-token"
  python voice_edit_server.py

Then expose via Cloudflare Tunnel:
  cloudflared tunnel --url http://localhost:8742
"""

import os
import subprocess
import sys
from pathlib import Path
from fastapi import FastAPI, HTTPException, Header
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

PROJECT_DIR = Path("/Users/marski/git/startrek-thelonggame")
PORT = 8742

AUTH_TOKEN = os.environ.get("VOICE_EDIT_TOKEN")
if not AUTH_TOKEN:
    print("ERROR: VOICE_EDIT_TOKEN environment variable not set", file=sys.stderr)
    print("Generate one with: python -c 'import secrets; print(secrets.token_urlsafe(32))'", file=sys.stderr)
    sys.exit(1)

app = FastAPI()

# Allow requests from GitHub Pages and local dev
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://karskiliini.github.io",
        "http://localhost:8000",
        "http://127.0.0.1:8000",
        "null",  # for local file:// testing
    ],
    allow_credentials=False,
    allow_methods=["POST", "OPTIONS"],
    allow_headers=["*"],
)


class VoiceEditRequest(BaseModel):
    transcription: str
    scene_file: str  # relative path, e.g. "v2/05_the_dinner.md"
    version: str  # "v1" or "v2"


def build_prompt(req: VoiceEditRequest) -> str:
    """Build the prompt sent to Claude Code CLI."""
    return f"""You are editing a Star Trek screenplay. The user just spoke a command into their phone while looking at a specific scene. The speech was transcribed to text.

**Scene file:** {req.scene_file}
**Transcribed voice command:** "{req.transcription}"

**Your task:**

1. First, determine if this voice command is actually a screenplay editing request (e.g., "change X to Y", "rewrite this line", "make this scene shorter", "remove the reference to Z"). If the transcription is random chatter, a question about how to use the app, or something clearly unrelated to editing the screenplay, respond with exactly:

   REJECT: <brief reason why>

2. If it IS an edit request, apply the change to the scene file using the Edit tool. Keep the screenplay's existing tone — restrained, observational, precise. Never add emojis. Preserve the existing formatting (screenplay character names in ALL CAPS, dialogue indented, etc.). After making the change, respond with exactly:

   DONE: <one sentence describing what you changed>

**Important:**
- Work only on the specified scene file: {req.scene_file}
- Do not commit to git yourself — the server will handle that
- Do not run any other tools besides Read and Edit
- Respond with ONLY "REJECT: ..." or "DONE: ..." — no preamble, no explanation beyond that one line
"""


@app.post("/api/voice-edit")
async def voice_edit(
    req: VoiceEditRequest,
    authorization: str = Header(None),
):
    # Auth check
    if authorization != f"Bearer {AUTH_TOKEN}":
        raise HTTPException(401, "Unauthorized")

    # Validate scene file path (prevent path traversal)
    scene_path = PROJECT_DIR / req.scene_file
    try:
        scene_path.resolve().relative_to(PROJECT_DIR.resolve())
    except ValueError:
        raise HTTPException(400, "Invalid scene file path")

    if not scene_path.exists():
        raise HTTPException(404, f"Scene file not found: {req.scene_file}")

    # Build prompt and call Claude Code CLI
    prompt = build_prompt(req)

    try:
        result = subprocess.run(
            ["claude", "-p", prompt],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(504, "Claude Code timed out")
    except FileNotFoundError:
        raise HTTPException(500, "Claude Code CLI not found. Is it installed and in PATH?")

    if result.returncode != 0:
        return {
            "status": "error",
            "message": f"Claude Code failed: {result.stderr.strip() or result.stdout.strip()}",
            "file_updated": False,
        }

    output = result.stdout.strip()

    # Parse response
    if output.startswith("REJECT:"):
        return {
            "status": "rejected",
            "message": output[len("REJECT:"):].strip(),
            "file_updated": False,
        }

    if output.startswith("DONE:"):
        message = output[len("DONE:"):].strip()
        # Commit and push the change
        commit_msg = f"Voice edit: {message}\n\nCommand: \"{req.transcription}\"\n\nCo-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
        try:
            subprocess.run(
                ["git", "add", req.scene_file],
                cwd=str(PROJECT_DIR),
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "commit", "-m", commit_msg],
                cwd=str(PROJECT_DIR),
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "push"],
                cwd=str(PROJECT_DIR),
                check=True,
                capture_output=True,
                timeout=60,
            )
        except subprocess.CalledProcessError as e:
            return {
                "status": "error",
                "message": f"Edit applied but commit failed: {e.stderr.decode() if e.stderr else str(e)}",
                "file_updated": True,
            }

        return {
            "status": "done",
            "message": message,
            "file_updated": True,
        }

    # Unexpected output — return as-is
    return {
        "status": "error",
        "message": f"Unexpected Claude output: {output[:500]}",
        "file_updated": False,
    }


@app.get("/api/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    print(f"Starting voice edit server on port {PORT}")
    print(f"Project directory: {PROJECT_DIR}")
    print(f"Expose publicly with: cloudflared tunnel --url http://localhost:{PORT}")
    uvicorn.run(app, host="127.0.0.1", port=PORT)
