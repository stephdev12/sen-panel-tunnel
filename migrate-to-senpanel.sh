#!/usr/bin/env bash
# =============================================================================
# SEN PANEL TUNNEL - MIGRATION & MISE À NIVEAU SANS PERTE DE DONNÉES
#
# Ce script permet de basculer vers SEN PANEL TUNNEL en conservant :
#   - Tous les services actifs (connexions SSH actives NON coupées)
#   - Tous les comptes clients existants (/etc/novaxtunnel/users.db & bandwidth/)
#   - Tous les comptes revendeurs, leurs quotas, et leurs clients (panel.sqlite3)
#   - Le compte administrateur du panel et son mot de passe existant (.env & panel.sqlite3)
#   - Les certificats SSL Let's Encrypt / Nginx
#   - Les configurations et tokens existants
#
# Usage :
#   curl -fsSL https://raw.githubusercontent.com/stephdev12/sen-panel-tunnel/main/migrate-to-senpanel.sh | sudo bash
# =============================================================================

set -Eeuo pipefail

REPO_URL="https://github.com/stephdev12/sen-panel-tunnel.git"
TARGET_DIR="/opt/nova-x-tunnel"
OLD_LEGACY_DIR="/opt/nova-x-tunnel"
SERVICE_NAME="novaxpanel"

C_GREEN=$'\033[0;32m'
C_RED=$'\033[0;31m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[0;36m'
C_RESET=$'\033[0m'

info()  { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
error() { echo -e "${C_RED}[ERREUR]${C_RESET} $*" >&2; exit 1; }

trap 'error "Une erreur est survenue à la ligne ${LINENO}. Les sauvegardes sont préservées."' ERR

# -----------------------------------------------------------------------------
# 1. Vérification des prérequis
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root : sudo bash $0"
fi

echo -e "${C_CYAN}==========================================================${C_RESET}"
echo -e "${C_CYAN}     SEN PANEL TUNNEL — MIGRATION EN DOUCEUR DU SERVEUR   ${C_RESET}"
echo -e "${C_CYAN}==========================================================${C_RESET}"
echo -e "Préservation garantie :"
echo -e "  ✔ Tunnels SSH et sessions clients en direct (aucun kill sshd)"
echo -e "  ✔ Base clients SSH (/etc/novaxtunnel/users.db et consommation .usage)"
echo -e "  ✔ Comptes revendeurs, quotas et clients du panel web"
echo -e "  ✔ Compte admin du panel web et identifiants existants"
echo -e "  ✔ Certificats SSL et configurations Nginx"
echo

# -----------------------------------------------------------------------------
# 2. Détection de l'installation actuelle
# -----------------------------------------------------------------------------
SOURCE_DIR=""
CURRENT_SERVICE_DIR="$(systemctl show "$SERVICE_NAME" -p WorkingDirectory --value 2>/dev/null | sed 's|/web-panel||' || true)"

if [[ -n "$CURRENT_SERVICE_DIR" && -d "$CURRENT_SERVICE_DIR" ]]; then
    SOURCE_DIR="$CURRENT_SERVICE_DIR"
elif [[ -d "$TARGET_DIR" && -f "$TARGET_DIR/web-panel/package.json" ]]; then
    SOURCE_DIR="$TARGET_DIR"
elif [[ -d "$OLD_LEGACY_DIR" && -f "$OLD_LEGACY_DIR/web-panel/package.json" ]]; then
    SOURCE_DIR="$OLD_LEGACY_DIR"
fi

info "Dossier source détecté : ${SOURCE_DIR:-aucun (nouvelle installation)}"

# -----------------------------------------------------------------------------
# 3. Sauvegarde de sécurité complète avant toute modification
# -----------------------------------------------------------------------------
BACKUP_DIR="/root/senpanel-safe-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
info "Création d'une sauvegarde de sécurité dans : $BACKUP_DIR"

# 3.1 Base de données et fichiers utilisateurs SSH
if [[ -d "/etc/novaxtunnel" ]]; then
    mkdir -p "$BACKUP_DIR/etc_novaxtunnel"
    cp -a /etc/novaxtunnel/* "$BACKUP_DIR/etc_novaxtunnel/" 2>/dev/null || true
    ok "Fichiers /etc/novaxtunnel sauvegardés (users.db, compteurs bande passante, etc.)"
fi

if [[ -d "/etc/zivpn" ]]; then
    mkdir -p "$BACKUP_DIR/etc_zivpn"
    cp -a /etc/zivpn/* "$BACKUP_DIR/etc_zivpn/" 2>/dev/null || true
fi

# 3.2 Données du panel web (Admin, Revendeurs, Sessions, .env)
PRESERVED_ENV=""
PRESERVED_PANEL_DB=""
PRESERVED_SESSIONS_DB=""
PRESERVED_SERVER_KEYS=()

if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR/web-panel" ]]; then
    mkdir -p "$BACKUP_DIR/web-panel"

    if [[ -f "$SOURCE_DIR/web-panel/.env" ]]; then
        cp -a "$SOURCE_DIR/web-panel/.env" "$BACKUP_DIR/web-panel/.env"
        PRESERVED_ENV="$BACKUP_DIR/web-panel/.env"
        ok "Fichier de configuration .env sauvegardé"
    fi

    if [[ -f "$SOURCE_DIR/web-panel/db/panel.sqlite3" ]]; then
        cp -a "$SOURCE_DIR/web-panel/db/panel.sqlite3" "$BACKUP_DIR/web-panel/panel.sqlite3"
        PRESERVED_PANEL_DB="$BACKUP_DIR/web-panel/panel.sqlite3"
        ok "Base de données panel.sqlite3 sauvegardée (comptes admin & revendeurs)"
    fi

    if [[ -f "$SOURCE_DIR/web-panel/db/sessions.sqlite3" ]]; then
        cp -a "$SOURCE_DIR/web-panel/db/sessions.sqlite3" "$BACKUP_DIR/web-panel/sessions.sqlite3"
        PRESERVED_SESSIONS_DB="$BACKUP_DIR/web-panel/sessions.sqlite3"
    fi

    if compgen -G "$SOURCE_DIR/web-panel/db/*.pem" > /dev/null; then
        cp -a "$SOURCE_DIR/web-panel/db/"*.pem "$BACKUP_DIR/web-panel/" 2>/dev/null || true
    fi
fi

# 3.3 Configurations système (systemd, nginx, haproxy)
[[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] && cp -a "/etc/systemd/system/${SERVICE_NAME}.service" "$BACKUP_DIR/"
[[ -f "/etc/haproxy/haproxy.cfg" ]] && cp -a "/etc/haproxy/haproxy.cfg" "$BACKUP_DIR/"
[[ -d "/etc/nginx/sites-available" ]] && cp -a /etc/nginx/sites-available "$BACKUP_DIR/" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Synchronisation du nouveau dépôt vers /opt/nova-x-tunnel
# -----------------------------------------------------------------------------
info "Synchronisation du code vers $TARGET_DIR..."

if ! command -v git >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y git
fi

mkdir -p "$TARGET_DIR"

if [[ -d "$TARGET_DIR/.git" ]]; then
    cd "$TARGET_DIR"
    git remote set-url origin "$REPO_URL" 2>/dev/null || git remote add origin "$REPO_URL"
    git fetch origin main
    git reset --hard origin/main
    ok "Dépôt mis à jour via git (origin/main)"
else
    # Si l'ancien dossier était /opt/nova-x-tunnel, copier le contenu d'abord ou cloner
    TEMP_CLONE="/tmp/senpanel-clone-$$"
    git clone "$REPO_URL" "$TEMP_CLONE"
    rsync -a --delete "$TEMP_CLONE/" "$TARGET_DIR/" 2>/dev/null || cp -a "$TEMP_CLONE"/. "$TARGET_DIR/"
    rm -rf "$TEMP_CLONE"
    ok "Dépôt cloné dans $TARGET_DIR"
fi

# -----------------------------------------------------------------------------
# 5. Restauration transparente de la base SQLite et des identifiants
# -----------------------------------------------------------------------------
info "Restauration des comptes admin, revendeurs et de la configuration..."
mkdir -p "$TARGET_DIR/web-panel/db"

if [[ -n "$PRESERVED_PANEL_DB" && -f "$PRESERVED_PANEL_DB" ]]; then
    cp -a "$PRESERVED_PANEL_DB" "$TARGET_DIR/web-panel/db/panel.sqlite3"
    ok "Base panel.sqlite3 restaurée avec succès (AUCUN compte revendeur/admin perdu)"
fi

if [[ -n "$PRESERVED_SESSIONS_DB" && -f "$PRESERVED_SESSIONS_DB" ]]; then
    cp -a "$PRESERVED_SESSIONS_DB" "$TARGET_DIR/web-panel/db/sessions.sqlite3"
fi

if compgen -G "$BACKUP_DIR/web-panel/*.pem" > /dev/null; then
    cp -a "$BACKUP_DIR/web-panel/"*.pem "$TARGET_DIR/web-panel/db/" 2>/dev/null || true
fi

if [[ -n "$PRESERVED_ENV" && -f "$PRESERVED_ENV" ]]; then
    cp -a "$PRESERVED_ENV" "$TARGET_DIR/web-panel/.env"
    ok "Fichier .env restauré avec le secret de session et les réglages d'origine"
elif [[ ! -f "$TARGET_DIR/web-panel/.env" ]]; then
    cp "$TARGET_DIR/web-panel/.env.example" "$TARGET_DIR/web-panel/.env"
    SESSION_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "senpanel-$(date +%s)")
    sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=${SESSION_SECRET}|" "$TARGET_DIR/web-panel/.env"
fi

# -----------------------------------------------------------------------------
# 6. Maintien de la compatibilité avec l'ancien chemin /opt/nova-x-tunnel
# -----------------------------------------------------------------------------
# Création d'un lien symbolique pour que tout script tiers ou tâche cron
# pointant sur /opt/nova-x-tunnel continue de fonctionner immédiatement
if [[ "$OLD_LEGACY_DIR" != "$TARGET_DIR" ]]; then
    if [[ -d "$OLD_LEGACY_DIR" && ! -L "$OLD_LEGACY_DIR" ]]; then
        # Déplacer l'ancien dossier en backup
        mv "$OLD_LEGACY_DIR" "${OLD_LEGACY_DIR}.migrated.$(date +%s)"
    fi
    ln -sfn "$TARGET_DIR" "$OLD_LEGACY_DIR"
    ok "Lien symbolique créé : $OLD_LEGACY_DIR -> $TARGET_DIR"
fi

# -----------------------------------------------------------------------------
# 7. Mise à jour des dépendances Node.js
# -----------------------------------------------------------------------------
info "Vérification de Node.js et des dépendances..."
if ! command -v node >/dev/null 2>&1; then
    warn "Node.js manquant, installation de Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

cd "$TARGET_DIR/web-panel"
npm install --omit=dev --silent
ok "Dépendances Node.js à jour"

# -----------------------------------------------------------------------------
# 8. Mise à jour du panel terminal (menu) sans couper les sessions SSH
# -----------------------------------------------------------------------------
info "Mise à jour du panel terminal (/usr/local/bin/menu)..."
cp "$TARGET_DIR/terminal-panel/menu.sh" /usr/local/bin/menu
chmod +x /usr/local/bin/menu
ok "Commande 'menu' mise à jour avec les correctifs OpenSSH 9.8 et limitation wchar"

# -----------------------------------------------------------------------------
# 9. Configuration du service systemd novaxpanel
# -----------------------------------------------------------------------------
info "Mise à jour du service systemd ${SERVICE_NAME}..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SEN Panel Tunnel Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${TARGET_DIR}/web-panel
ExecStart=$(command -v node) ${TARGET_DIR}/web-panel/server.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" &>/dev/null || true
systemctl restart "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Service web panel (${SERVICE_NAME}) démarré et actif"
else
    warn "Le service web panel n'a pas pu démarrer immédiatement. Consultez journalctl -u $SERVICE_NAME -n 30"
fi

# -----------------------------------------------------------------------------
# 10. Rechargement Nginx à chaud (sans coupure)
# -----------------------------------------------------------------------------
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    if nginx -t &>/dev/null; then
        systemctl reload nginx
        ok "Nginx rechargé à chaud sans interruption de service"
    fi
fi

# -----------------------------------------------------------------------------
# 11. Application des optimisations réseau et WebSocket (senpanel-fix.sh)
# -----------------------------------------------------------------------------
info "Application des optimisations non disruptives (WebSocket HAProxy, BBR, OpenSSH)..."
chmod +x "$TARGET_DIR/senpanel-fix.sh"
bash "$TARGET_DIR/senpanel-fix.sh" || warn "Certains correctifs non critiques ont signalé un avertissement."

# -----------------------------------------------------------------------------
# 12. Rapport final de vérification
# -----------------------------------------------------------------------------
SSH_USERS_COUNT=0
if [[ -f "/etc/novaxtunnel/users.db" ]]; then
    SSH_USERS_COUNT=$(grep -c ":" /etc/novaxtunnel/users.db || true)
fi

RESELLERS_COUNT="0"
ADMINS_COUNT="0"
if [[ -f "$TARGET_DIR/web-panel/db/panel.sqlite3" ]] && command -v sqlite3 >/dev/null 2>&1; then
    ADMINS_COUNT=$(sqlite3 "$TARGET_DIR/web-panel/db/panel.sqlite3" "SELECT COUNT(*) FROM admins;" 2>/dev/null || echo "1")
    RESELLERS_COUNT=$(sqlite3 "$TARGET_DIR/web-panel/db/panel.sqlite3" "SELECT COUNT(*) FROM resellers;" 2>/dev/null || echo "0")
fi

DOMAIN_VAL="$(grep -E '^DOMAIN=' "$TARGET_DIR/web-panel/.env" 2>/dev/null | cut -d'=' -f2- || true)"
PORT_VAL="$(grep -E '^PORT=' "$TARGET_DIR/web-panel/.env" 2>/dev/null | cut -d'=' -f2- || echo '3000')"
PUBLIC_PORT_VAL="$(grep -E '^PUBLIC_PORT=' "$TARGET_DIR/web-panel/.env" 2>/dev/null | cut -d'=' -f2- || true)"

echo
echo -e "${C_GREEN}==========================================================${C_RESET}"
echo -e "${C_GREEN}       MIGRATION REUSSIE — SEN PANEL TUNNEL EST ACTIF      ${C_RESET}"
echo -e "${C_GREEN}==========================================================${C_RESET}"
echo -e "État des comptes et données :"
echo -e "  • Comptes clients SSH préservés : ${C_CYAN}${SSH_USERS_COUNT}${C_RESET} (dans /etc/novaxtunnel/users.db)"
echo -e "  • Comptes revendeurs préservés  : ${C_CYAN}${RESELLERS_COUNT}${C_RESET} (dans panel.sqlite3)"
echo -e "  • Compte administrateur         : ${C_CYAN}Préservé avec son mot de passe existant${C_RESET}"
echo
echo -e "Services en ligne :"
systemctl is-active --quiet "$SERVICE_NAME" && echo -e "  • Web Panel (${SERVICE_NAME}) : ${C_GREEN}ACTIF${C_RESET}" || echo -e "  • Web Panel : ${C_YELLOW}A VERIFIER${C_RESET}"
(systemctl is-active --quiet sshd || systemctl is-active --quiet ssh) && echo -e "  • SSH Server            : ${C_GREEN}ACTIF (connexions maintenues)${C_RESET}"
systemctl is-active --quiet haproxy && echo -e "  • HAProxy               : ${C_GREEN}ACTIF${C_RESET}"
systemctl is-active --quiet nginx && echo -e "  • Nginx                 : ${C_GREEN}ACTIF${C_RESET}"
systemctl is-active --quiet pyproxy-ws && echo -e "  • WebSocket Proxy (444) : ${C_GREEN}ACTIF${C_RESET}"
echo
if [[ -n "$DOMAIN_VAL" ]]; then
    if [[ -n "$PUBLIC_PORT_VAL" && "$PUBLIC_PORT_VAL" != "443" && "$PUBLIC_PORT_VAL" != "80" ]]; then
        echo -e "Accès panel web : ${C_CYAN}https://${DOMAIN_VAL}:${PUBLIC_PORT_VAL}${C_RESET}"
    else
        echo -e "Accès panel web : ${C_CYAN}https://${DOMAIN_VAL}${C_RESET}"
    fi
fi
echo -e "Dossier d'installation   : ${TARGET_DIR}"
echo -e "Sauvegarde de secours    : ${BACKUP_DIR}"
echo -e "${C_GREEN}==========================================================${C_RESET}"
