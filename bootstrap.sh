#!/bin/bash
# SEN PANEL TUNNEL - bootstrap script
#
# Installation (première fois) OU mise à jour (fois suivantes) — même commande :
#
#   curl -fsSL https://raw.githubusercontent.com/stephdev12/sen-panel-tunnel/main/bootstrap.sh | sudo bash
#
set -e

REPO_URL="https://github.com/stephdev12/sen-panel-tunnel.git"
INSTALL_DIR="/opt/novaxtunnel"

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (sudo)."
  exit 1
fi

echo "=================================================="
echo "           SEN PANEL TUNNEL - BOOTSTRAP           "
echo "=================================================="

# ---------- 1. Clone (première fois) ou pull (mise à jour) ----------
if ! command -v git >/dev/null 2>&1; then
  echo "📦 Installation de git..."
  apt-get update -y
  apt-get install -y git
fi

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "🔄 Repository already present in $INSTALL_DIR — updating (git pull)..."
  git -C "$INSTALL_DIR" pull
  MODE="update"
else
  echo "📥 Cloning repository into $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
  MODE="install"
fi

cd "$INSTALL_DIR"

# ---------- 2. Panel terminal ----------
if [ -x /usr/local/bin/menu ]; then
  echo "🔄 Terminal panel already installed → minor update (menu.sh only)."
  bash terminal-panel/update.sh
else
  echo "📥 Terminal panel missing → complete installation."
  bash terminal-panel/install.sh
fi

# ---------- 3. Panel web (optionnel) ----------
if [ -r /dev/tty ]; then
  read -r -p "👉 Install/update the web panel too? (y/n): " DO_WEB < /dev/tty
else
  echo "⚠️  No interactive terminal detected (non-interactive execution) — web panel skipped."
  echo "    Rerun with 'bash web-panel/deploy/ubuntu24-install.sh' or 'bash web-panel/deploy/install.sh --domain <your-domain>'."
  DO_WEB="n"
fi

if [[ "$DO_WEB" =~ ^[oOyY] ]]; then
  if systemctl list-unit-files 2>/dev/null | grep -q "^novaxpanel.service"; then
    echo "🔄 Web panel already installed → update (code + restart)."
    bash web-panel/update.sh
  else
    echo "Choisir l'installateur pour le panel web :"
    echo "  1) Installateur Ubuntu 24.04 (Nginx + Let's Encrypt certbot automatique) [Recommandé]"
    echo "  2) Déploiement interactif avancé (modes Nginx ou Node direct)"
    if [ -r /dev/tty ]; then
      read -r -p "Choix [1/2] (défaut 1): " WEB_INSTALLER_CHOICE < /dev/tty
    else
      WEB_INSTALLER_CHOICE="1"
    fi

    if [[ "${WEB_INSTALLER_CHOICE:-1}" == "1" ]]; then
      bash web-panel/deploy/ubuntu24-install.sh
    else
      if [ -r /dev/tty ]; then
        read -r -p "👉 Domain name for the web panel (e.g., panel.yourdomain.com), or leave empty for auto-detection: " DOMAIN < /dev/tty
      else
        DOMAIN=""
      fi
      bash web-panel/deploy/install.sh --domain "$DOMAIN"
    fi
  fi
fi

# ---------- 4. Correctifs VPS & Optimisations WebSocket (script correctif 2) ----------
if [ -r /dev/tty ]; then
  read -r -p "👉 Appliquer les optimisations VPS (HAProxy WebSocket, BBR, OpenSSH 9.8+, quotas)? (y/n) [y]: " DO_FIX < /dev/tty
  DO_FIX="${DO_FIX:-y}"
else
  DO_FIX="y"
fi

if [[ "$DO_FIX" =~ ^[oOyY] ]]; then
  echo "⚡ Exécution des correctifs senpanel-fix.sh..."
  bash "$INSTALL_DIR/senpanel-fix.sh" || true
fi

bash terminal-panel/nostra.sh

echo "=================================================="
echo " ✅ Completed (mode: $MODE)."
echo "    Terminal panel : type 'menu'"
if [ -x /usr/local/bin/novaxpanel ]; then
  echo "    Web panel (maintenance) : type 'novaxpanel'"
fi
echo "    Local repository    : $INSTALL_DIR"
echo "=================================================="
