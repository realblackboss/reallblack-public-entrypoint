FROM mcr.microsoft.com/devcontainers/base:bookworm

# Firefox ESR retains its native security behavior in this Codespaces container.
# GitHub Codespaces supplies SSH via the sshd devcontainer feature.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         firefox-esr xvfb x11vnc novnc websockify dbus-x11 openbox \
         fonts-liberation fonts-noto-color-emoji ca-certificates openssl procps curl \
    && rm -rf /var/lib/apt/lists/*

ENV DISPLAY=:99
