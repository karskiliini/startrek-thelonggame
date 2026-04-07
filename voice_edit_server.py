#!/usr/bin/env python3
"""Voice edit server — receives transcribed voice commands from the web player
and proposes edits via Claude Code CLI. User approves before commit.

Flow:
1. POST /api/voice-edit → Claude proposes change, returns diff
2. Phone shows diff to user for approval
3. POST /api/voice-edit-approve → server commits, pushes, triggers TTS
4. POST /api/voice-edit-cancel → server reverts the proposed change
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
    sys.exit(1)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://karskiliini.github.io",
        "http://localhost:8000",
        "http://127.0.0.1:8000",
        "null",
    ],
    allow_credentials=False,
    allow_methods=["POST", "OPTIONS"],
    allow_headers=["*"],
)


class VoiceEditRequest(BaseModel):
    transcription: str
    scene_file: str
    version: str


class ApprovalRequest(BaseModel):
    scene_file: str
    transcription: str


def check_auth(authorization: str):
    if authorization != f"Bearer {AUTH_TOKEN}":
        raise HTTPException(401, "Unauthorized")


def validate_scene_path(scene_file: str) -> Path:
    """Ensure scene file is under project dir and exists."""
    scene_path = PROJECT_DIR / scene_file
    try:
        scene_path.resolve().relative_to(PROJECT_DIR.resolve())
    except ValueError:
        raise HTTPException(400, "Invalid scene file path")
    if not scene_path.exists():
        raise HTTPException(404, f"Scene file not found: {scene_file}")
    return scene_path


def build_prompt(req: VoiceEditRequest) -> str:
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
- Do NOT run git commands — the server will handle committing
- Do not run any other tools besides Read and Edit
- Respond with ONLY "REJECT: ..." or "DONE: ..." — no preamble, no explanation beyond that one line
"""


@app.post("/api/voice-edit")
async def voice_edit(
    req: VoiceEditRequest,
    authorization: str = Header(None),
):
    """Apply edit proposal to the file (but don't commit). Return diff for approval."""
    check_auth(authorization)
    validate_scene_path(req.scene_file)

    # Make sure working tree is clean for this file before starting
    check = subprocess.run(
        ["git", "status", "--porcelain", req.scene_file],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
    )
    if check.stdout.strip():
        # Existing uncommitted changes — revert them first so we start clean
        subprocess.run(
            ["git", "checkout", "--", req.scene_file],
            cwd=str(PROJECT_DIR),
            capture_output=True,
        )

    prompt = build_prompt(req)

    try:
        result = subprocess.run(
            ["claude", "-p", prompt],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=180,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(504, "Claude Code timed out")
    except FileNotFoundError:
        raise HTTPException(500, "Claude Code CLI not found")

    if result.returncode != 0:
        return {
            "status": "error",
            "message": f"Claude Code failed: {result.stderr.strip() or result.stdout.strip()}",
        }

    output = result.stdout.strip()

    if output.startswith("REJECT:"):
        # Revert any stray changes just in case
        subprocess.run(
            ["git", "checkout", "--", req.scene_file],
            cwd=str(PROJECT_DIR),
            capture_output=True,
        )
        return {
            "status": "rejected",
            "message": output[len("REJECT:"):].strip(),
        }

    if output.startswith("DONE:"):
        message = output[len("DONE:"):].strip()

        # Get the diff
        diff_result = subprocess.run(
            ["git", "diff", "--no-color", req.scene_file],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
        )
        diff = diff_result.stdout.strip()

        if not diff:
            return {
                "status": "no_change",
                "message": "Claude reported DONE but no actual change was made",
            }

        return {
            "status": "pending_approval",
            "message": message,
            "diff": diff,
            "scene_file": req.scene_file,
            "transcription": req.transcription,
        }

    # Unexpected output
    subprocess.run(
        ["git", "checkout", "--", req.scene_file],
        cwd=str(PROJECT_DIR),
        capture_output=True,
    )
    return {
        "status": "error",
        "message": f"Unexpected Claude output: {output[:500]}",
    }


@app.post("/api/voice-edit-approve")
async def approve_edit(
    req: ApprovalRequest,
    authorization: str = Header(None),
):
    """Commit the pending change, push, and trigger TTS regeneration."""
    check_auth(authorization)
    validate_scene_path(req.scene_file)

    # Verify there's actually something to commit
    check = subprocess.run(
        ["git", "status", "--porcelain", req.scene_file],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
    )
    if not check.stdout.strip():
        return {
            "status": "error",
            "message": "No pending changes to commit",
        }

    commit_msg = f"Voice edit: {req.transcription[:80]}\n\nCo-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"

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

        # Push with retry
        push_ok = False
        for attempt in range(5):
            push_result = subprocess.run(
                ["git", "push"],
                cwd=str(PROJECT_DIR),
                capture_output=True,
                text=True,
                timeout=60,
            )
            if push_result.returncode == 0:
                push_ok = True
                break
            subprocess.run(
                ["git", "pull", "--rebase", "--autostash"],
                cwd=str(PROJECT_DIR),
                capture_output=True,
                timeout=60,
            )

        if not push_ok:
            return {
                "status": "commit_ok_push_failed",
                "message": "Committed locally but push failed. Try again manually.",
            }
    except subprocess.CalledProcessError as e:
        return {
            "status": "error",
            "message": f"Commit failed: {e.stderr.decode() if e.stderr else str(e)}",
        }

    # Trigger TTS in background (detached, fire and forget)
    try:
        subprocess.Popen(
            ["nohup", "zsh", "tts_sync.sh"],
            cwd=str(PROJECT_DIR),
            stdout=open(str(PROJECT_DIR / "tts_log.txt"), "w"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        tts_triggered = True
    except Exception as e:
        tts_triggered = False

    return {
        "status": "approved",
        "message": "Committed and pushed. TTS regeneration started." if tts_triggered else "Committed and pushed. TTS trigger failed.",
        "tts_triggered": tts_triggered,
    }


@app.post("/api/voice-edit-cancel")
async def cancel_edit(
    req: ApprovalRequest,
    authorization: str = Header(None),
):
    """Revert the pending change in the working tree."""
    check_auth(authorization)
    validate_scene_path(req.scene_file)

    subprocess.run(
        ["git", "checkout", "--", req.scene_file],
        cwd=str(PROJECT_DIR),
        capture_output=True,
    )

    return {
        "status": "cancelled",
        "message": "Pending change reverted",
    }


@app.get("/api/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    print(f"Starting voice edit server on port {PORT}")
    print(f"Project directory: {PROJECT_DIR}")
    uvicorn.run(app, host="127.0.0.1", port=PORT)
