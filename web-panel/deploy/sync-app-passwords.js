#!/usr/bin/env node
/**
 * Synchronise les mots de passe SSH depuis /etc/novaxtunnel/users.db
 * vers la table SQLite app_accounts pour que l'API mobile (/api/app/v1/config)
 * fournisse toujours le mot de passe SSH attendu à l'application Surfeo.
 */
const fs = require('fs');
const path = require('path');

// Recherche du dossier web-panel
const baseDir = path.resolve(__dirname, '..');
const config = require(path.join(baseDir, 'config.js'));
const Database = require('better-sqlite3');

const db = new Database(config.PANEL_DB_FILE);

// Migration des colonnes si manquantes
try { db.exec('ALTER TABLE app_accounts ADD COLUMN quota_gb REAL DEFAULT 0'); } catch {}
try { db.exec('ALTER TABLE app_accounts ADD COLUMN expiry_date TEXT'); } catch {}
try { db.exec('ALTER TABLE app_accounts ADD COLUMN password TEXT'); } catch {}

// Lecture de users.db
let users = [];
if (fs.existsSync(config.SSH_USERS_DB)) {
  const raw = fs.readFileSync(config.SSH_USERS_DB, 'utf8');
  users = raw.split('\n').filter(Boolean).map(line => {
    const [u, p, exp, conn, bw] = line.split(':');
    return { username: u, password: p, exp, conn, bw };
  });
  console.log(`[INFO] Lu ${users.length} entrées dans ${config.SSH_USERS_DB}`);
} else {
  console.warn(`[WARN] Fichier introuvable : ${config.SSH_USERS_DB}`);
}

const accounts = db.prepare('SELECT id, username, password FROM app_accounts').all();
let updated = 0;
for (const acc of accounts) {
  const match = users.find(u => u.username && u.username.toLowerCase() === (acc.username || '').toLowerCase());
  if (match && match.password && (!acc.password || acc.password.trim() === '')) {
    db.prepare('UPDATE app_accounts SET password = ? WHERE id = ?').run(match.password, acc.id);
    console.log(`[OK] Mot de passe synchronisé pour : ${acc.username} (longueur: ${match.password.length})`);
    updated++;
  } else if (acc.password && acc.password.trim() !== '') {
    console.log(`[INFO] Compte ${acc.username} possède déjà son mot de passe.`);
  } else {
    console.warn(`[WARN] Aucun mot de passe dans users.db pour : ${acc.username}`);
  }
}

console.log(`\n Résultat : ${updated} compte(s) mis à jour sur ${accounts.length} compte(s) au total.`);
