#!/usr/bin/env bash
# update.sh - Mise à jour sécurisée du panel sans perte de données
set -e

if [[ $EUID -ne 0 ]]; then
   echo "Erreur : ce script doit être exécuté en root (sudo bash $0)"
   exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================================="
echo " [1/4] Sauvegarde des données (SQLite & .env)..."
echo "=========================================================="
BACKUP_DIR="/root/senpanel_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
if [ -f "$SCRIPT_DIR/db/panel.sqlite3" ]; then
  cp -p "$SCRIPT_DIR/db/panel.sqlite3" "$BACKUP_DIR/"
  echo "[OK] Base SQLite sauvegardée dans $BACKUP_DIR/panel.sqlite3"
fi
if [ -f "$SCRIPT_DIR/.env" ]; then
  cp -p "$SCRIPT_DIR/.env" "$BACKUP_DIR/"
  echo "[OK] Fichier .env sauvegardé dans $BACKUP_DIR/.env"
fi

echo "=========================================================="
echo " [2/4] Récupération du nouveau code..."
echo "=========================================================="
cd "$ROOT_DIR"
git fetch origin main || git fetch origin master
git reset --hard origin/main 2>/dev/null || git reset --hard origin/master

echo "=========================================================="
echo " [3/4] Vérification des modules Node.js..."
echo "=========================================================="
cd "$SCRIPT_DIR"
npm install --omit=dev --silent 2>/dev/null || npm install --omit=dev

echo "=========================================================="
echo " [4/4] Redémarrage du service..."
echo "=========================================================="
if systemctl is-active --quiet senpanel; then
  systemctl restart senpanel
  echo "[OK] Service senpanel redémarré avec succès."
elif systemctl is-active --quiet novaxpanel; then
  systemctl restart novaxpanel
  echo "[OK] Service novaxpanel redémarré avec succès."
else
  systemctl restart senpanel 2>/dev/null || systemctl restart novaxpanel 2>/dev/null || true
  echo "[INFO] Commande de redémarrage envoyée."
fi

echo
echo "=========================================================="
echo " [TERMINÉ] Le panel est à jour avec la nouvelle interface !"
echo "=========================================================="
