FROM mcr.microsoft.com/devcontainers/base:bookworm

# Virtual desktop + Chromium and a lightweight window manager.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         chromium xvfb x11vnc novnc websockify dbus-x11 openbox \
         fonts-liberation fonts-noto-color-emoji ca-certificates openssl procps curl \
    && rm -rf /var/lib/apt/lists/*

ENV DISPLAY=:99
