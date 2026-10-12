#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.ig-local-private"
PROFILE_DIR="${STATE_DIR}/chrome-profile"
PW_FILE="${STATE_DIR}/vnc-password"
VNC_FILE="${STATE_DIR}/vncpasswd"
LOG_DIR="${STATE_DIR}/logs"
mkdir -p "$PROFILE_DIR" "$LOG_DIR"
chmod 700 "$STATE_DIR" "$PROFILE_DIR" "$LOG_DIR"

# Password and browser cookies only live in the private Codespace workspace.
if [[ ! -s "$PW_FILE" || ! -s "$VNC_FILE" ]]; then
  PASS="$(openssl rand -hex 4)"
  printf '%s\n' "$PASS" > "$PW_FILE"
  chmod 600 "$PW_FILE"
  x11vnc -storepasswd "$PASS" "$VNC_FILE" >/dev/null
  chmod 600 "$VNC_FILE"
fi

export DISPLAY=:99
if ! pgrep -f 'Xvfb :99 -screen' >/dev/null; then
  nohup Xvfb :99 -screen 0 1366x850x24 -nolisten tcp > "$LOG_DIR/xvfb.log" 2>&1 < /dev/null &
  sleep 2
fi
if ! pgrep -f 'openbox --sm-disable' >/dev/null; then
  nohup openbox --sm-disable > "$LOG_DIR/openbox.log" 2>&1 < /dev/null &
fi
if ! pgrep -f 'x11vnc.*-rfbport 5900' >/dev/null; then
  nohup x11vnc -display :99 -listen 127.0.0.1 -noipv6 -rfbport 5900 -rfbauth "$VNC_FILE" \
    -forever -shared -noxdamage -xkb > "$LOG_DIR/vnc.log" 2>&1 < /dev/null &
  sleep 2
fi
if ! pgrep -f 'websockify.*6080' >/dev/null; then
  nohup websockify --web /usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900 \
    > "$LOG_DIR/websockify.log" 2>&1 < /dev/null &
fi
if ! pgrep -f "chromium.*${PROFILE_DIR}" >/dev/null; then
  nohup chromium --user-data-dir="$PROFILE_DIR" --no-first-run --no-default-browser-check \
    --disable-dev-shm-usage --disable-gpu --window-size=1280,800 \
    --new-window https://www.instagram.com/ > "$LOG_DIR/chromium.log" 2>&1 < /dev/null &
fi

echo "INSTAGRAM CLOUD: interface remota privativa em https://<seu-codespace>-6080.app.github.dev/vnc.html?autoconnect=1"
echo "A porta 6080 deve permanecer PRIVATE no GitHub. Sua senha de acesso VNC:"
echo "  cat .ig-local-private/vnc-password"
echo "Nunca salve credenciais no git nem envie por chat."
