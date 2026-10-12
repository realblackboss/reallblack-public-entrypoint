#!/usr/bin/env bash
set -euo pipefail

# Do NOT store Instagram credentials, tokens or VNC passwords in Git.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/.ig-local-private"
PROFILE="$STATE/firefox-profile"
VNC_PW="$STATE/vnc-password"
VNC_HASH="$STATE/vncpasswd"
LOG="$STATE/logs"
mkdir -p "$PROFILE" "$LOG"
chmod 700 "$STATE" "$PROFILE" "$LOG"

if [[ ! -s "$VNC_PW" || ! -s "$VNC_HASH" ]]; then
  PASS="$(openssl rand -hex 4)"
  printf '%s\n' "$PASS" > "$VNC_PW"
  chmod 600 "$VNC_PW"
  x11vnc -storepasswd "$PASS" "$VNC_HASH" > /dev/null
  chmod 600 "$VNC_HASH"
fi

export DISPLAY=:99

# setsid -f detaches the processes from GitHub Codespaces postStartCommand,
# avoiding an unexpected SIGHUP after startup.
if ! pgrep -f '^Xvfb :99 -screen' >/dev/null; then
  nohup setsid -f Xvfb :99 -screen 0 1366x850x24 -nolisten tcp > "$LOG/xvfb.log" 2>&1 < /dev/null &
  sleep 2
fi
if ! pgrep -x openbox >/dev/null; then
  nohup setsid -f openbox --sm-disable > "$LOG/openbox.log" 2>&1 < /dev/null &
fi
if ! ss -lnt | grep -Eq ':5900[[:space:]]'; then
  nohup setsid -f x11vnc -display :99 -listen 127.0.0.1 -noipv6 -rfbport 5900 \
    -rfbauth "$VNC_HASH" -forever -shared -noxdamage -xkb > "$LOG/vnc.log" 2>&1 < /dev/null &
  sleep 2
fi
if ! ss -lnt | grep -Eq ':6080[[:space:]]'; then
  nohup setsid -f websockify --web /usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900 \
    > "$LOG/websockify.log" 2>&1 < /dev/null &
fi
if ! pgrep -f '^firefox-esr --no-remote --profile ' >/dev/null; then
  nohup setsid -f firefox-esr --no-remote --profile "$PROFILE" \
    --new-window https://www.instagram.com/ > "$LOG/firefox.log" 2>&1 < /dev/null &
fi
echo 'IG CLOUD READY: use the PRIVATE 6080 port in GitHub Codespaces.'
echo 'The remote desktop password is available ONLY inside the Codespace:'
echo '  cat .ig-local-private/vnc-password'
