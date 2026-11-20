#!/usr/bin/env bash
# update-panel-fix.sh - Met à jour SEN PANEL TUNNEL et synchronise les mots de passe SSH
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Veuillez exécuter ce script en root (sudo bash $0)"
  exit 1
fi

INSTALL_DIR=""
for dir in "/opt/nova-x-tunnel" "/opt/novaxtunnel" "/opt/senpanel" "/var/www/novaxtunnel"; do
  if [ -d "$dir/web-panel" ]; then
    INSTALL_DIR="$dir"
    break
  fi
done

if [ -z "$INSTALL_DIR" ]; then
  echo "[ERREUR] Dossier d'installation du panel introuvable !"
  exit 1
fi

echo "=========================================================="
echo " [1/4] Mise à jour du code dans $INSTALL_DIR..."
echo "=========================================================="
cd "$INSTALL_DIR"
git fetch origin main || git fetch origin master
git reset --hard origin/main 2>/dev/null || git reset --hard origin/master

echo "=========================================================="
echo " [2/4] Vérification des dépendances..."
echo "=========================================================="
cd "$INSTALL_DIR/web-panel"
npm install --omit=dev --silent 2>/dev/null || true

echo "=========================================================="
echo " [3/4] Synchronisation des mots de passe SSH..."
echo "=========================================================="
node deploy/sync-app-passwords.js

echo "=========================================================="
echo " [4/4] Redémarrage du service panel..."
echo "=========================================================="
if systemctl is-active --quiet novaxpanel; then
  systemctl restart novaxpanel
  echo "[OK] Service novaxpanel redémarré avec succès."
elif systemctl is-active --quiet senpanel; then
  systemctl restart senpanel
  echo "[OK] Service senpanel redémarré avec succès."
else
  systemctl restart novaxpanel 2>/dev/null || systemctl restart senpanel 2>/dev/null || true
  echo "[INFO] Commande de redémarrage envoyée."
fi

echo
echo "=========================================================="
echo " [TERMINÉ] Le panel est à jour et les mots de passe sont prêts !"
echo "=========================================================="
