#!/usr/bin/env bash
# =============================================================================
# senpanel-fix.sh - Corrections SEN PANEL TUNNEL pour VPS SSH-WebSocket + CloudFront
#
# Ce que fait le script (idempotent : on peut le relancer sans risque) :
#   1. nginx   : sort le panel web des ports 80/443 (-> 2045) pour libérer HAProxy
#   2. HAProxy : envoie le trafic du port 80 vers le proxy WebSocket (444)
#                => accepte n'importe quel chemin (/sen, /tieme, ...) et répond 101
#   3. Comptage: compatibilité OpenSSH >= 9.8 (processus "sshd-session")
#   4. Quota   : ne compte plus le trafic en double (wchar seul)
#   5. Réseau  : BBR + tampons TCP
#   5b. Capacité: limites de fichiers, sshd (exemption 127.0.0.1, MaxStartups),
#                backlog du proxy Python (5 -> 1024), swap si RAM < 2,5 Go
#   6. Pare-feu: ufw (80, 443, panel) s'il est actif
#   7. Test    : vérifie que /sen répond 101 en local
#
# Usage :   sudo bash senpanel-fix.sh [--reset-usage]
#   --reset-usage : remet à 0 la consommation de tous les comptes
# =============================================================================
set -uo pipefail

PANEL_PORT="${PANEL_PORT:-2045}"
WS_PORT="${WS_PORT:-444}"
TEST_PATH="${TEST_PATH:-/sen}"
RESET_USAGE=0
[[ "${1:-}" == "--reset-usage" ]] && RESET_USAGE=1

NGX_PANEL="/etc/nginx/sites-available/nova-panel"
[[ ! -f "$NGX_PANEL" && -f "/etc/nginx/sites-available/novaxpanel" ]] && NGX_PANEL="/etc/nginx/sites-available/novaxpanel"
[[ ! -f "$NGX_PANEL" && -f "/etc/nginx/sites-available/senpanel" ]] && NGX_PANEL="/etc/nginx/sites-available/senpanel"

HAP_CFG="/etc/haproxy/haproxy.cfg"
MENU="/usr/local/bin/menu"
LIMITER="/usr/local/bin/novaxtunnel-limiter.sh"
BW_DIR="/etc/novaxtunnel/bandwidth"
BACKUP_DIR="/root/senpanel-backup-$(date +%Y%m%d-%H%M%S)"

C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[36m'; C_0=$'\e[0m'
info() { echo "${C_B}[..]${C_0} $*"; }
ok()   { echo "${C_G}[OK]${C_0} $*"; }
warn() { echo "${C_Y}[!!]${C_0} $*"; }
err()  { echo "${C_R}[XX]${C_0} $*"; }

if [[ $EUID -ne 0 ]]; then
    err "Lance ce script en root : sudo bash $0"
    exit 1
fi

mkdir -p "$BACKUP_DIR"
backup() { [[ -f "$1" ]] && cp -a "$1" "$BACKUP_DIR/$(basename "$1")"; }
restore() { [[ -f "$BACKUP_DIR/$(basename "$1")" ]] && cp -a "$BACKUP_DIR/$(basename "$1")" "$1"; }

echo "Sauvegardes dans : $BACKUP_DIR"
echo

# -----------------------------------------------------------------------------
# 1. nginx : le panel web doit libérer les ports 80/443
# -----------------------------------------------------------------------------
info "1/7 nginx : déplacement du panel hors des ports 80/443"
if [[ -f "$NGX_PANEL" ]]; then
    if grep -qE 'listen[[:space:]]+(\[::\]:)?(80|443)\b' "$NGX_PANEL"; then
        backup "$NGX_PANEL"
        sed -i \
            -e "s/listen \[::\]:443 ssl ipv6only=on;/listen [::]:${PANEL_PORT} ssl ipv6only=on;/" \
            -e "s/listen 443 ssl;/listen ${PANEL_PORT} ssl;/" \
            -e '/listen \[::\]:80;/d' \
            -e 's/listen 80;/listen 127.0.0.1:8881;/' \
            "$NGX_PANEL"
        if nginx -t &>/dev/null; then
            ok "Panel déplacé sur le port ${PANEL_PORT}"
        else
            err "nginx -t a échoué, restauration de l'ancien fichier"
            restore "$NGX_PANEL"
            nginx -t 2>&1 | tail -5
        fi
    else
        ok "Le panel n'écoute déjà plus sur 80/443"
    fi
else
    warn "Pas de site nginx pour le panel, étape ignorée"
fi

# -----------------------------------------------------------------------------
# 2. HAProxy : port 80 -> proxy WebSocket
# -----------------------------------------------------------------------------
info "2/7 HAProxy : aiguillage du port 80 vers le proxy WebSocket (${WS_PORT})"
if [[ -f "$HAP_CFG" ]]; then
    if grep -q '^backend direct_sshp' "$HAP_CFG"; then
        backup "$HAP_CFG"
        sed -i "/^backend direct_sshp/,/^backend /s#127\.0\.0\.1:8888#127.0.0.1:${WS_PORT}#" "$HAP_CFG"
        if haproxy -c -f "$HAP_CFG" &>/dev/null; then
            ok "backend direct_sshp -> 127.0.0.1:${WS_PORT}"
        else
            err "Config HAProxy invalide, restauration"
            restore "$HAP_CFG"
            haproxy -c -f "$HAP_CFG" 2>&1 | tail -5
        fi
    else
        warn "backend direct_sshp introuvable dans $HAP_CFG, étape ignorée"
    fi
else
    warn "$HAP_CFG introuvable (HAProxy non installé ?), étape ignorée"
fi

# Ordre important : nginx libère 80/443, HAProxy les prend, puis nginx revient
if systemctl list-unit-files 2>/dev/null | grep -q '^haproxy'; then
    systemctl stop nginx &>/dev/null
    systemctl reset-failed haproxy &>/dev/null
    systemctl restart haproxy
    systemctl start nginx &>/dev/null
    sleep 1
    if systemctl is-active --quiet haproxy; then
        ok "HAProxy actif"
    else
        err "HAProxy ne démarre pas. Détails :"
        haproxy -c -f "$HAP_CFG" 2>&1 | tail -5
        journalctl -u haproxy -n 10 --no-pager 2>/dev/null | tail -10
        ss -tlnp 2>/dev/null | grep -E ':(80|443)\s'
    fi
    systemctl is-active --quiet nginx || warn "nginx n'est pas actif (journalctl -u nginx -n 20)"
fi

# Le proxy WebSocket doit répondre 101
if systemctl cat pyproxy-ws &>/dev/null; then
    if systemctl cat pyproxy-ws --no-pager 2>/dev/null | grep -q -- '--response-code 101'; then
        ok "pyproxy-ws configuré avec --response-code 101"
    else
        warn "pyproxy-ws ne force pas le code 101 (systemctl cat pyproxy-ws). Ajoute :"
        warn "  --response-code 101 --response-msg @Labokingfreesurf --default-host 127.0.0.1:22"
    fi
fi

# -----------------------------------------------------------------------------
# 3. Comptage des sessions : OpenSSH >= 9.8 utilise "sshd-session"
# -----------------------------------------------------------------------------
info "3/7 Comptage des connexions (sshd + sshd-session)"
for f in "$MENU" "$LIMITER"; do
    if [[ -f "$f" ]]; then
        backup "$f"
        sed -i 's/ps -C sshd -o/ps -C sshd,sshd-session -o/g' "$f"
        sed -i 's/\[\[ "\$comm" == "sshd" \]\]/[[ "$comm" == "sshd" || "$comm" == "sshd-session" ]]/' "$f"
        ok "Patché : $f"
    else
        warn "Introuvable : $f"
    fi
done

# -----------------------------------------------------------------------------
# 4. Quota : plus de double comptage
# -----------------------------------------------------------------------------
# Panel web (Node) : même problème de nom de processus (lib/system.js)
PANEL_DIR=$(systemctl show novaxpanel -p WorkingDirectory --value 2>/dev/null)
[[ -z "$PANEL_DIR" && -d "/opt/nova-x-tunnel/web-panel" ]] && PANEL_DIR="/opt/nova-x-tunnel/web-panel"
PANEL_JS="${PANEL_DIR}/lib/system.js"
if [[ -n "$PANEL_DIR" && -f "$PANEL_JS" ]]; then
    if grep -q "'-C', 'sshd', '-o'" "$PANEL_JS"; then
        backup "$PANEL_JS"
        sed -i "s/\['-C', 'sshd', '-o'/['-C', 'sshd,sshd-session', '-o'/" "$PANEL_JS"
        if ! command -v node &>/dev/null || node --check "$PANEL_JS" 2>/dev/null; then
            systemctl restart novaxpanel &>/dev/null || true
            ok "Panel web patché : $PANEL_JS"
        else
            err "Syntaxe JS invalide après le patch, restauration"
            restore "$PANEL_JS"
        fi
    else
        ok "Panel web : aucun patch nécessaire"
    fi
else
    warn "Panel web introuvable, patch ignoré"
fi

info "4/7 Quota de bande passante (wchar seul)"
if [[ -f "$LIMITER" ]]; then
    if grep -q 'cur=\$((rchar + wchar))' "$LIMITER"; then
        sed -i 's/cur=\$((rchar + wchar))/cur=$wchar/' "$LIMITER"
        ok "Limiteur : cur=\$wchar"
        # Les anciens fichiers de suivi ont été écrits avec l'ancienne formule
        systemctl stop novaxtunnel-limiter &>/dev/null
        rm -f "$BW_DIR/pidtrack/"*.last 2>/dev/null
    else
        ok "Limiteur déjà corrigé"
    fi
    if (( RESET_USAGE )); then
        for u in "$BW_DIR"/*.usage; do
            [[ -f "$u" ]] && echo 0 > "$u"
        done
        ok "Consommations remises à 0"
    fi
    systemctl restart novaxtunnel-limiter &>/dev/null
    systemctl is-active --quiet novaxtunnel-limiter \
        && ok "Limiteur actif" || warn "Limiteur inactif (systemctl status novaxtunnel-limiter)"
fi
if [[ -f "$MENU" ]] && grep -q 'rchar' "$MENU"; then
    warn "menu contient aussi 'rchar' : l'affichage de la conso peut rester doublé."
fi

# -----------------------------------------------------------------------------
# 5. Réseau : BBR + tampons TCP
# -----------------------------------------------------------------------------
info "5/7 Optimisation réseau (BBR, tampons TCP)"
modprobe tcp_bbr &>/dev/null || true
cat > /etc/sysctl.d/99-novax-tuning.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 262144 33554432
net.ipv4.tcp_wmem=4096 262144 33554432
net.ipv4.tcp_mtu_probing=1
EOF
sysctl --system &>/dev/null || true
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
[[ "$cc" == "bbr" ]] && ok "BBR actif" || warn "BBR non actif (contrôle actuel : $cc)"

# -----------------------------------------------------------------------------
# 5b. Capacité : limites, sshd, file d'attente du proxy Python, swap
# -----------------------------------------------------------------------------
info "5b/7 Capacité (limites de fichiers, sshd, backlog proxy, swap)"

# Limites de descripteurs de fichiers
for s in pyproxy-ws pyproxy-socks haproxy ssh; do
    if systemctl cat "$s" &>/dev/null; then
        mkdir -p "/etc/systemd/system/$s.service.d"
        printf '[Service]\nLimitNOFILE=1048576\n' > "/etc/systemd/system/$s.service.d/limits.conf"
    fi
done

# File d'attente de connexions et keepalive
cat > /etc/sysctl.d/98-novax-conn.conf <<'EOF'
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10000 65535
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=4
EOF
sysctl --system &>/dev/null || true

# sshd : exemption 127.0.0.1
mkdir -p /etc/ssh/sshd_config.d
SSHD_CAP="/etc/ssh/sshd_config.d/00-novax-capacity.conf"
{
    echo "MaxStartups 200:30:500"
    echo "MaxSessions 100"
    echo "ClientAliveInterval 60"
    echo "ClientAliveCountMax 5"
    if sshd -T 2>/dev/null | grep -qi '^persourcepenalties'; then
        echo "PerSourcePenaltyExemptList 127.0.0.1/32,::1/128"
    fi
} > "$SSHD_CAP"
if sshd -t 2>/dev/null; then
    ok "sshd : $SSHD_CAP appliqué"
    sshd -T 2>/dev/null | grep -iE '^(maxstartups|persourcepenaltyexemptlist) ' | sed 's/^/     /' || true
    if ! sshd -T 2>/dev/null | grep -qi '^maxstartups 200:30:500'; then
        if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
            backup /etc/ssh/sshd_config
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
            if sshd -t 2>/dev/null; then
                ok "Include sshd_config.d ajouté en tête de sshd_config"
            else
                err "sshd -t a échoué après l'ajout de l'Include, restauration"
                restore /etc/ssh/sshd_config
            fi
        fi
    fi
else
    err "sshd -t a échoué, suppression de $SSHD_CAP"
    rm -f "$SSHD_CAP"
fi

# Proxy Python : backlog 5 -> 1024
for f in /etc/novaxtunnel/pyproxy/*.py; do
    if [[ -f "$f" ]] && grep -q '\.listen(5)' "$f"; then
        backup "$f"
        sed -i 's/\.listen(5)/.listen(1024)/' "$f"
        ok "Backlog du proxy relevé : $(basename "$f")"
    fi
done

# Swap si RAM < 2,5 Go
if [[ -f /proc/meminfo ]]; then
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if (( mem_mb < 2500 )) && [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
        if fallocate -l 2G /swapfile 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile &>/dev/null && swapon /swapfile; then
            grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            ok "Swap de 2 Go créé (RAM : ${mem_mb} Mo)"
        fi
    fi
fi

# Recharge services
systemctl daemon-reload
systemctl reload ssh &>/dev/null || systemctl reload sshd &>/dev/null || true
for s in pyproxy-ws pyproxy-socks haproxy; do
    systemctl cat "$s" &>/dev/null && systemctl restart "$s" &>/dev/null || true
done
sleep 1
ok "Services rechargés"

# -----------------------------------------------------------------------------
# 6. Pare-feu local
# -----------------------------------------------------------------------------
info "6/7 Pare-feu"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp &>/dev/null || true
    ufw allow 443/tcp &>/dev/null || true
    ufw allow "${PANEL_PORT}/tcp" &>/dev/null || true
    ok "ufw : ports 80, 443 et ${PANEL_PORT} autorisés"
else
    ok "ufw inactif, rien à faire"
fi

# -----------------------------------------------------------------------------
# 7. Test final
# -----------------------------------------------------------------------------
info "7/7 Test WebSocket local sur ${TEST_PATH}"
resp=$(timeout 5 curl -si -m 3 --http1.1 \
    -H "Upgrade: websocket" -H "Connection: Upgrade" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
    "http://127.0.0.1${TEST_PATH}" 2>/dev/null | head -2 | tr -d '\r')
if echo "$resp" | head -1 | grep -q ' 101 '; then
    ok "101 reçu"
    echo "$resp" | sed -n '2p' | grep -q '^SSH-' && ok "Bannière SSH reçue : $(echo "$resp" | sed -n '2p')"
else
    warn "Pas de 101 sur ${TEST_PATH} (normal si le proxy WebSocket n'est pas encore démarré)."
fi

echo
echo "=================================================="
echo " ✅ Correctifs appliqués avec succès."
echo "=================================================="
