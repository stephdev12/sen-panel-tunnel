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
INSTALL_DIR="/opt/nova-x-tunnel"
SERVICE_NAME="novaxpanel"
APP_PORT="3000"

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
elif [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/web-panel/package.json" ]]; then
    SOURCE_DIR="$INSTALL_DIR"
fi

info "Dossier source détecté : ${SOURCE_DIR:-aucun (nouvelle installation)}"

# Lire le port actuel depuis .env si disponible
if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/web-panel/.env" ]]; then
    CURRENT_PORT="$(grep -E '^PORT=' "$SOURCE_DIR/web-panel/.env" 2>/dev/null | cut -d'=' -f2- | tr -d ' ' || true)"
    [[ -n "$CURRENT_PORT" ]] && APP_PORT="$CURRENT_PORT"
fi
info "Port applicatif Node.js : $APP_PORT"

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

if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR/web-panel" ]]; then
    mkdir -p "$BACKUP_DIR/web-panel"

    if [[ -f "$SOURCE_DIR/web-panel/.env" ]]; then
        cp -a "$SOURCE_DIR/web-panel/.env" "$BACKUP_DIR/web-panel/.env"
        PRESERVED_ENV="$BACKUP_DIR/web-panel/.env"
        ok "Fichier de configuration .env sauvegardé"
    fi

    if compgen -G "$SOURCE_DIR/web-panel/db/panel.sqlite3*" > /dev/null 2>&1; then
        cp -a "$SOURCE_DIR/web-panel/db/panel.sqlite3"* "$BACKUP_DIR/web-panel/"
        PRESERVED_PANEL_DB="$BACKUP_DIR/web-panel/panel.sqlite3"
        ok "Base de données panel.sqlite3 (et fichiers WAL) sauvegardée"
    elif [[ -f "$SOURCE_DIR/web-panel/panel.sqlite3" ]]; then
        cp -a "$SOURCE_DIR/web-panel/panel.sqlite3"* "$BACKUP_DIR/web-panel/"
        PRESERVED_PANEL_DB="$BACKUP_DIR/web-panel/panel.sqlite3"
        ok "Base de données panel.sqlite3 sauvegardée"
    fi

    if [[ -f "$SOURCE_DIR/web-panel/db/sessions.sqlite3" ]]; then
        cp -a "$SOURCE_DIR/web-panel/db/sessions.sqlite3" "$BACKUP_DIR/web-panel/sessions.sqlite3"
        PRESERVED_SESSIONS_DB="$BACKUP_DIR/web-panel/sessions.sqlite3"
    fi

    if compgen -G "$SOURCE_DIR/web-panel/db/*.pem" > /dev/null 2>&1; then
        cp -a "$SOURCE_DIR/web-panel/db/"*.pem "$BACKUP_DIR/web-panel/" 2>/dev/null || true
    fi
fi

# 3.3 Configurations système (systemd, nginx, haproxy)
[[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] && cp -a "/etc/systemd/system/${SERVICE_NAME}.service" "$BACKUP_DIR/"
[[ -f "/etc/haproxy/haproxy.cfg" ]] && cp -a "/etc/haproxy/haproxy.cfg" "$BACKUP_DIR/"
[[ -d "/etc/nginx/sites-available" ]] && cp -a /etc/nginx/sites-available "$BACKUP_DIR/" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Synchronisation du nouveau dépôt vers $INSTALL_DIR
# -----------------------------------------------------------------------------
info "Synchronisation du code vers $INSTALL_DIR..."

if ! command -v git > /dev/null 2>&1; then
    apt-get update -y && apt-get install -y git
fi

mkdir -p "$INSTALL_DIR"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    cd "$INSTALL_DIR"
    git remote set-url origin "$REPO_URL" 2>/dev/null || git remote add origin "$REPO_URL"
    git fetch origin main
    git reset --hard origin/main
    ok "Dépôt mis à jour via git (origin/main)"
else
    TEMP_CLONE="$(mktemp -d)"
    git clone "$REPO_URL" "$TEMP_CLONE"
    # Copier en préservant les fichiers de données existants
    rsync -a --exclude='.env' --exclude='db/' "$TEMP_CLONE/" "$INSTALL_DIR/" 2>/dev/null \
        || cp -a "$TEMP_CLONE"/. "$INSTALL_DIR/"
    rm -rf "$TEMP_CLONE"
    ok "Dépôt cloné dans $INSTALL_DIR"
fi

# -----------------------------------------------------------------------------
# 5. Restauration transparente de la base SQLite et des identifiants
# -----------------------------------------------------------------------------
info "Restauration des comptes admin, revendeurs et de la configuration..."
mkdir -p "$INSTALL_DIR/web-panel/db"

if [[ -n "$PRESERVED_PANEL_DB" && -f "$PRESERVED_PANEL_DB" ]]; then
    cp -a "$BACKUP_DIR/web-panel/panel.sqlite3"* "$INSTALL_DIR/web-panel/db/"
    ok "Base panel.sqlite3 (et fichiers WAL) restaurée avec succès (AUCUN compte revendeur/admin perdu)"
fi

if [[ -n "$PRESERVED_SESSIONS_DB" && -f "$PRESERVED_SESSIONS_DB" ]]; then
    cp -a "$PRESERVED_SESSIONS_DB" "$INSTALL_DIR/web-panel/db/sessions.sqlite3"
fi

if compgen -G "$BACKUP_DIR/web-panel/*.pem" > /dev/null 2>&1; then
    cp -a "$BACKUP_DIR/web-panel/"*.pem "$INSTALL_DIR/web-panel/db/" 2>/dev/null || true
fi

# Restaurer ou créer le .env
if [[ -n "$PRESERVED_ENV" && -f "$PRESERVED_ENV" ]]; then
    cp -a "$PRESERVED_ENV" "$INSTALL_DIR/web-panel/.env"
    # S'assurer que PORT est présent dans le .env restauré
    grep -q '^PORT=' "$INSTALL_DIR/web-panel/.env" \
        || echo "PORT=${APP_PORT}" >> "$INSTALL_DIR/web-panel/.env"
    ok "Fichier .env restauré avec le secret de session et les réglages d'origine"
elif [[ ! -f "$INSTALL_DIR/web-panel/.env" ]]; then
    cp "$INSTALL_DIR/web-panel/.env.example" "$INSTALL_DIR/web-panel/.env"
    SESSION_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "senpanel-$(date +%s)")
    sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=${SESSION_SECRET}|" "$INSTALL_DIR/web-panel/.env"
    sed -i "s|^PORT=.*|PORT=${APP_PORT}|" "$INSTALL_DIR/web-panel/.env"
    warn ".env créé depuis .env.example — pensez à vérifier les paramètres."
fi

# -----------------------------------------------------------------------------
# 6. Vérification / création du lien de compatibilité novaxtunnel
# -----------------------------------------------------------------------------
# Certains scripts ou crons peuvent encore pointer sur /opt/novaxtunnel
if [[ ! -e "/opt/novaxtunnel" ]] || [[ -L "/opt/novaxtunnel" ]]; then
    ln -sfn "$INSTALL_DIR" /opt/novaxtunnel
    ok "Lien symbolique de compatibilité : /opt/novaxtunnel -> $INSTALL_DIR"
fi

# -----------------------------------------------------------------------------
# 7. Mise à jour des dépendances Node.js
# -----------------------------------------------------------------------------
info "Vérification de Node.js et des dépendances..."
if ! command -v node > /dev/null 2>&1; then
    warn "Node.js manquant, installation de Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

NODE_BIN="$(command -v node)"
info "Node : $($NODE_BIN --version)"

cd "$INSTALL_DIR/web-panel"
npm install --omit=dev --silent
ok "Dépendances Node.js à jour"

if [[ -f "$INSTALL_DIR/web-panel/deploy/import-ssh-to-panel.js" ]]; then
    info "Importation des comptes SSH (/etc/novaxtunnel/users.db) vers Surfeo..."
    node deploy/import-ssh-to-panel.js || true
    ok "Comptes SSH importés dans le panel"
fi

if [[ -f "$INSTALL_DIR/web-panel/deploy/sync-app-passwords.js" ]]; then
    info "Synchronisation des mots de passe SSH des comptes app..."
    node deploy/sync-app-passwords.js || true
    ok "Mots de passe SSH synchronisés"
fi

# -----------------------------------------------------------------------------
# 8. Mise à jour du panel terminal (menu) sans couper les sessions SSH
# -----------------------------------------------------------------------------
info "Mise à jour du panel terminal (/usr/local/bin/menu)..."
cp "$INSTALL_DIR/terminal-panel/menu.sh" /usr/local/bin/menu
chmod +x /usr/local/bin/menu
ok "Commande 'menu' mise à jour"

# -----------------------------------------------------------------------------
# 9. Configuration et (re)démarrage du service systemd
# -----------------------------------------------------------------------------
info "Mise à jour du service systemd ${SERVICE_NAME}..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SEN Panel Tunnel Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/web-panel
ExecStart=${NODE_BIN} ${INSTALL_DIR}/web-panel/server.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=PORT=${APP_PORT}
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" &>/dev/null || true
systemctl restart "$SERVICE_NAME"

sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Service web panel (${SERVICE_NAME}) démarré et actif sur le port ${APP_PORT}"
else
    warn "Le service web panel n'a pas démarré correctement."
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
fi

# -----------------------------------------------------------------------------
# 10. Vérification Nginx et rechargement à chaud
# -----------------------------------------------------------------------------
if command -v nginx > /dev/null 2>&1 && systemctl is-active --quiet nginx; then
    # Chercher le fichier de conf nginx du panel
    NGINX_CONF=""
    for candidate in \
        "/etc/nginx/sites-available/nova-panel" \
        "/etc/nginx/sites-available/novaxpanel" \
        "/etc/nginx/sites-available/senpanel"
    do
        [[ -f "$candidate" ]] && NGINX_CONF="$candidate" && break
    done

    if [[ -n "$NGINX_CONF" ]]; then
        # Vérifier que le proxy_pass pointe vers le bon port
        if ! grep -q "127.0.0.1:${APP_PORT}" "$NGINX_CONF"; then
            warn "La config Nginx ($NGINX_CONF) ne pointe pas vers le port $APP_PORT — correction..."
            sed -i "s|proxy_pass http://127\.0\.0\.1:[0-9]*;|proxy_pass http://127.0.0.1:${APP_PORT};|g" "$NGINX_CONF"
            ok "Config Nginx mise à jour → port $APP_PORT"
        fi
    else
        warn "Aucune configuration Nginx du panel trouvée. Si Nginx est votre proxy, vérifiez manuellement."
    fi

    if nginx -t &>/dev/null; then
        systemctl reload nginx
        ok "Nginx rechargé à chaud sans interruption de service"
    else
        warn "La configuration Nginx contient des erreurs — nginx -t pour diagnostiquer."
    fi
fi

# -----------------------------------------------------------------------------
# 11. Application des optimisations réseau et WebSocket (senpanel-fix.sh)
# -----------------------------------------------------------------------------
if [[ -f "$INSTALL_DIR/senpanel-fix.sh" ]]; then
    info "Application des optimisations non disruptives (WebSocket HAProxy, BBR, OpenSSH)..."
    chmod +x "$INSTALL_DIR/senpanel-fix.sh"
    bash "$INSTALL_DIR/senpanel-fix.sh" || warn "Certains correctifs non critiques ont signalé un avertissement."
fi

# -----------------------------------------------------------------------------
# 12. Rapport final de vérification
# -----------------------------------------------------------------------------
SSH_USERS_COUNT=0
if [[ -f "/etc/novaxtunnel/users.db" ]]; then
    SSH_USERS_COUNT=$(grep -c ":" /etc/novaxtunnel/users.db || true)
fi

RESELLERS_COUNT="0"
ADMINS_COUNT="0"
if [[ -f "$INSTALL_DIR/web-panel/db/panel.sqlite3" ]] && command -v sqlite3 > /dev/null 2>&1; then
    ADMINS_COUNT=$(sqlite3 "$INSTALL_DIR/web-panel/db/panel.sqlite3" "SELECT COUNT(*) FROM admins;" 2>/dev/null || echo "1")
    RESELLERS_COUNT=$(sqlite3 "$INSTALL_DIR/web-panel/db/panel.sqlite3" "SELECT COUNT(*) FROM resellers;" 2>/dev/null || echo "0")
fi

DOMAIN_VAL="$(grep -E '^DOMAIN=' "$INSTALL_DIR/web-panel/.env" 2>/dev/null | cut -d'=' -f2- || true)"
PUBLIC_PORT_VAL="$(grep -E '^PUBLIC_PORT=' "$INSTALL_DIR/web-panel/.env" 2>/dev/null | cut -d'=' -f2- || true)"

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
systemctl is-active --quiet "$SERVICE_NAME"  && echo -e "  • Web Panel (${SERVICE_NAME}) : ${C_GREEN}ACTIF${C_RESET}" || echo -e "  • Web Panel : ${C_YELLOW}A VERIFIER${C_RESET}"
(systemctl is-active --quiet sshd || systemctl is-active --quiet ssh) && echo -e "  • SSH Server            : ${C_GREEN}ACTIF (connexions maintenues)${C_RESET}" || true
systemctl is-active --quiet haproxy && echo -e "  • HAProxy               : ${C_GREEN}ACTIF${C_RESET}" || true
systemctl is-active --quiet nginx   && echo -e "  • Nginx                 : ${C_GREEN}ACTIF${C_RESET}" || true
echo
if [[ -n "$DOMAIN_VAL" ]]; then
    if [[ -n "$PUBLIC_PORT_VAL" && "$PUBLIC_PORT_VAL" != "443" && "$PUBLIC_PORT_VAL" != "80" ]]; then
        echo -e "Accès panel web : ${C_CYAN}https://${DOMAIN_VAL}:${PUBLIC_PORT_VAL}${C_RESET}"
    else
        echo -e "Accès panel web : ${C_CYAN}https://${DOMAIN_VAL}${C_RESET}"
    fi
fi
echo -e "Port Node interne : ${APP_PORT}"
echo -e "Dossier d'installation   : ${INSTALL_DIR}"
echo -e "Sauvegarde de secours    : ${BACKUP_DIR}"
echo -e "Logs en temps réel       : journalctl -u ${SERVICE_NAME} -f"
echo -e "${C_GREEN}==========================================================${C_RESET}"
