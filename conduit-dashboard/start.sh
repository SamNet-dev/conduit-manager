#!/bin/bash
# Start Conduit Dashboard in background
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$DIR/.dashboard.pid"
LOG="$DIR/.dashboard.log"
PORT="${DASHBOARD_PORT:-3456}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! command -v node >/dev/null 2>&1; then
  echo "❌ Node.js is not installed. Install it first:"
  echo "   curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -"
  echo "   sudo apt-get install -y nodejs"
  exit 1
fi

# Warn if not root and not in docker group (server.js will also warn, but catch early)
if [ "$(id -u)" -ne 0 ]; then
  if ! id -nG | grep -qw docker; then
    echo "⚠  Not running as root and not in the docker group."
    echo "   The dashboard needs docker access to read Conduit stats."
    echo "   Either run with sudo or add yourself to the docker group:"
    echo "   sudo usermod -aG docker \$USER && newgrp docker"
    echo ""
    echo "   Continuing anyway — some endpoints may fail."
    echo ""
  fi
fi

# ── Check if already running ──────────────────────────────────────────────────

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")
  echo "Dashboard already running (PID $(cat "$PIDFILE"))"
  echo "→ http://localhost:${PORT}"
  echo "→ http://${LAN_IP}:${PORT}"
  exit 0
fi

# ── Start the server ──────────────────────────────────────────────────────────

nohup node "$DIR/server.js" > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 1

if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")
  echo "✅ Conduit Dashboard started (PID $(cat "$PIDFILE"))"
  echo "→ Local: http://localhost:${PORT}"
  echo "→ LAN:   http://${LAN_IP}:${PORT}"
  echo ""
  echo "   Logs: tail -f $LOG"
  echo "   Stop: $DIR/stop.sh"
else
  echo "❌ Failed to start. Check log:"
  cat "$LOG"
  rm -f "$PIDFILE"
  exit 1
fi
