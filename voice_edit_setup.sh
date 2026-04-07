#!/bin/bash
# Voice Edit — automatic setup and launch script
#
# Does everything needed to run the voice edit feature:
# 1. Creates Python venv and installs dependencies
# 2. Installs cloudflared (if missing)
# 3. Generates auth token (if missing)
# 4. Starts the voice edit server
# 5. Starts the Cloudflare Tunnel
# 6. Prints the tunnel URL and token for easy copy-paste
#
# Usage:
#   ./voice_edit_setup.sh          # install + run
#   ./voice_edit_setup.sh install  # install only
#   ./voice_edit_setup.sh run      # run only (assumes installed)
#   ./voice_edit_setup.sh stop     # stop running server and tunnel

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

VENV_DIR=".venv-voice"
TOKEN_FILE=".voice_edit_token"
SERVER_PID_FILE=".voice_edit_server.pid"
TUNNEL_PID_FILE=".voice_edit_tunnel.pid"
TUNNEL_URL_FILE=".voice_edit_tunnel_url"
SERVER_LOG=".voice_edit_server.log"
TUNNEL_LOG=".voice_edit_tunnel.log"

MODE="${1:-all}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${BLUE}[voice-edit]${NC} $1"; }
ok()     { echo -e "${GREEN}[voice-edit]${NC} $1"; }
warn()   { echo -e "${YELLOW}[voice-edit]${NC} $1"; }
error()  { echo -e "${RED}[voice-edit]${NC} $1"; }

stop_server() {
    if [ -f "$SERVER_PID_FILE" ]; then
        local pid=$(cat "$SERVER_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping server (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$SERVER_PID_FILE"
    fi
    pkill -f "voice_edit_server.py" 2>/dev/null || true
}

stop_tunnel() {
    if [ -f "$TUNNEL_PID_FILE" ]; then
        local pid=$(cat "$TUNNEL_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping tunnel (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$TUNNEL_PID_FILE"
    fi
    pkill -f "cloudflared tunnel --url http://localhost:8742" 2>/dev/null || true
}

stop_all() {
    stop_server
    stop_tunnel
    ok "All stopped."
}

if [ "$MODE" = "stop" ]; then
    stop_all
    exit 0
fi

# === INSTALL ===

if [ "$MODE" = "all" ] || [ "$MODE" = "install" ]; then
    log "Checking prerequisites..."

    # Python 3
    if ! command -v python3 >/dev/null 2>&1; then
        error "python3 is required but not installed."
        exit 1
    fi
    ok "python3 found: $(python3 --version)"

    # Claude Code CLI
    if ! command -v claude >/dev/null 2>&1; then
        error "claude CLI not found. Install Claude Code first."
        error "https://docs.anthropic.com/en/docs/claude-code"
        exit 1
    fi
    ok "claude CLI found."

    # Python venv
    if [ ! -d "$VENV_DIR" ]; then
        log "Creating Python virtual environment in $VENV_DIR..."
        python3 -m venv "$VENV_DIR"
    fi

    log "Installing Python dependencies..."
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet fastapi uvicorn pydantic
    ok "Python dependencies installed."

    # Cloudflared
    if ! command -v cloudflared >/dev/null 2>&1; then
        log "cloudflared not found — installing via Homebrew..."
        if ! command -v brew >/dev/null 2>&1; then
            error "Homebrew not installed. Install it first: https://brew.sh"
            exit 1
        fi
        brew install cloudflare/cloudflare/cloudflared
    fi
    ok "cloudflared found: $(cloudflared --version 2>&1 | head -1)"

    # Auth token
    if [ ! -f "$TOKEN_FILE" ]; then
        log "Generating auth token..."
        python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        ok "Auth token saved to $TOKEN_FILE (chmod 600)"
    else
        ok "Auth token already exists at $TOKEN_FILE"
    fi

    ok "Install complete."

    if [ "$MODE" = "install" ]; then
        echo
        log "Run './voice_edit_setup.sh run' to start the server and tunnel."
        exit 0
    fi
fi

# === RUN ===

log "Stopping any existing server/tunnel..."
stop_all

if [ ! -d "$VENV_DIR" ]; then
    error "Virtual environment not found. Run './voice_edit_setup.sh install' first."
    exit 1
fi

if [ ! -f "$TOKEN_FILE" ]; then
    error "Auth token not found. Run './voice_edit_setup.sh install' first."
    exit 1
fi

TOKEN=$(cat "$TOKEN_FILE")

# Start server
log "Starting voice edit server..."
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
VOICE_EDIT_TOKEN="$TOKEN" nohup python voice_edit_server.py > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
echo $SERVER_PID > "$SERVER_PID_FILE"
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    error "Server failed to start. Check $SERVER_LOG:"
    tail -20 "$SERVER_LOG"
    exit 1
fi
ok "Server running on http://localhost:8742 (PID $SERVER_PID)"

# Start tunnel
log "Starting Cloudflare Tunnel..."
nohup cloudflared tunnel --url http://localhost:8742 > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!
echo $TUNNEL_PID > "$TUNNEL_PID_FILE"

# Wait for tunnel URL to appear in log
log "Waiting for tunnel URL..."
TUNNEL_URL=""
for i in $(seq 1 30); do
    if grep -q "trycloudflare.com" "$TUNNEL_LOG" 2>/dev/null; then
        TUNNEL_URL=$(grep -Eo "https://[a-z0-9-]+\.trycloudflare\.com" "$TUNNEL_LOG" | head -1)
        if [ -n "$TUNNEL_URL" ]; then
            break
        fi
    fi
    sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
    error "Could not detect tunnel URL. Check $TUNNEL_LOG:"
    tail -20 "$TUNNEL_LOG"
    exit 1
fi

echo "$TUNNEL_URL" > "$TUNNEL_URL_FILE"
ok "Tunnel running at $TUNNEL_URL (PID $TUNNEL_PID)"

# Test health endpoint
log "Testing health endpoint..."
if curl -sf "http://localhost:8742/api/health" > /dev/null; then
    ok "Server is healthy."
else
    warn "Health check failed — server may still be starting."
fi

echo
echo "=============================================="
echo -e "${GREEN}Voice Edit is running!${NC}"
echo "=============================================="
echo
echo -e "${YELLOW}Paste these into the player settings (⚙):${NC}"
echo
echo -e "${BLUE}Server URL:${NC}  $TUNNEL_URL"
echo -e "${BLUE}Auth Token:${NC} $TOKEN"
echo
echo "=============================================="
echo
echo "Open player on your phone:"
echo "  https://karskiliini.github.io/startrek-thelonggame/player.html"
echo
echo "Logs:"
echo "  Server: tail -f $SERVER_LOG"
echo "  Tunnel: tail -f $TUNNEL_LOG"
echo
echo "Stop everything:"
echo "  ./voice_edit_setup.sh stop"
echo
