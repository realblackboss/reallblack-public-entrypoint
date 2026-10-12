FROM mcr.microsoft.com/devcontainers/base:bookworm

# Chromium with a real virtual desktop (no Meta app/API keys, no paid browser service)
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         chromium xvfb x11vnc novnc websockify dbus-x11 \
         fonts-liberation fonts-noto-color-emoji ca-certificates openssl procps curl \
    && rm -rf /var/lib/apt/lists/*

ENV DISPLAY=:99
