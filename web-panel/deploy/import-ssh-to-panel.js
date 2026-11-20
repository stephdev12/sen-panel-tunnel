#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const baseDir = path.resolve(__dirname, '..');
const config = require(path.join(baseDir, 'config.js'));
const Database = require('better-sqlite3');
const { createActivationKey } = require(path.join(baseDir, 'lib', 'activationKey.js'));

const db = new Database(config.PANEL_DB_FILE);

// Check profile
let defaultProfile = db.prepare("SELECT id FROM connection_profiles WHERE is_active = 1 AND type = 'ssh' LIMIT 1").get();
const profileId = defaultProfile ? defaultProfile.id : 1;

if (!fs.existsSync(config.SSH_USERS_DB)) {
  console.log(`[WARN] Fichier introuvable : ${config.SSH_USERS_DB}`);
  process.exit(0);
}

const raw = fs.readFileSync(config.SSH_USERS_DB, 'utf8');
const lines = raw.split('\n').filter(Boolean);
console.log(`[INFO] Lecture de ${lines.length} utilisateurs dans ${config.SSH_USERS_DB}...`);

let imported = 0;
let existing = 0;

const insertAccount = db.prepare(`
  INSERT INTO app_accounts (username, type, profile_id, state, quota_gb, expiry_date, password)
  VALUES (?, 'ssh', ?, 'pending', ?, ?, ?)
`);

const insertKey = db.prepare(`
  INSERT INTO activation_keys (key_hash, app_account_id, server_code, key_last4, status)
  VALUES (?, ?, ?, ?, 'unused')
`);

for (const line of lines) {
  const parts = line.split(':');
  if (parts.length < 2) continue;
  const username = parts[0].trim();
  const password = parts[1].trim();
  const expiry = parts[2] && parts[2].trim() ? parts[2].trim() : null;
  const quota = parts[4] ? (parseFloat(parts[4]) || 0) : 0;

  const found = db.prepare('SELECT id FROM app_accounts WHERE username = ?').get(username);
  if (found) {
    db.prepare('UPDATE app_accounts SET password = ?, quota_gb = COALESCE(NULLIF(quota_gb, 0), ?), expiry_date = COALESCE(expiry_date, ?) WHERE id = ?')
      .run(password, quota, expiry, found.id);
    existing++;
  } else {
    const res = insertAccount.run(username, profileId, quota, expiry, password);
    const newId = res.lastInsertRowid;
    try {
      const { keyHash, keyLast4, serverCode } = createActivationKey();
      insertKey.run(keyHash, newId, serverCode, keyLast4);
    } catch (e) {
      console.warn(`[WARN] Erreur création clé pour ${username}: ${e.message}`);
    }
    imported++;
  }
}

console.log(`\n[SUCCESS] Synchronisation terminée :`);
console.log(`  - Nouveaux comptes importés : ${imported}`);
console.log(`  - Comptes existants mis à jour : ${existing}`);
console.log(`  - Total comptes Surfeo dans le panel : ${db.prepare('SELECT count(*) c FROM app_accounts').get().c}`);
