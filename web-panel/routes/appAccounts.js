const express = require('express');
const fs = require('fs');
const path = require('path');
const config = require('../config');
const db = require('../db/database');
const system = require('../lib/system');
const { validateDeviceId, formatDeviceId } = require('../lib/crockford');
const { createActivationKey } = require('../lib/activationKey');
const { requireAdmin } = require('../middleware/auth');
const audit = require('../lib/audit');

const router = express.Router();
router.use(requireAdmin);

function getUserUsedBytes(username) {
  const usageFile = path.join(config.BANDWIDTH_DIR, `${username}.usage`);
  try {
    if (fs.existsSync(usageFile)) {
      const content = fs.readFileSync(usageFile, 'utf8').trim();
      const bytes = parseInt(content, 10);
      return isNaN(bytes) ? 0 : bytes;
    }
  } catch {}
  return 0;
}

// List app accounts
router.get('/', (req, res) => {
  const accounts = db.prepare(`
    SELECT a.*, p.name AS profile_name, p.version AS profile_version,
           r.username AS reseller_name,
           k.key_last4, k.status AS key_status
    FROM app_accounts a
    LEFT JOIN connection_profiles p ON a.profile_id = p.id
    LEFT JOIN resellers r ON a.reseller_id = r.id
    LEFT JOIN activation_keys k ON k.app_account_id = a.id AND k.status != 'revoked'
    ORDER BY a.id DESC
  `).all();

  const accountsWithUsage = accounts.map((a) => {
    const usedBytes = getUserUsedBytes(a.username);
    const quotaGb = parseFloat(a.quota_gb) || 0;
    const quotaBytes = quotaGb > 0 ? Math.round(quotaGb * 1024 * 1024 * 1024) : 0;
    const percent = quotaBytes > 0 ? Math.min(100, Math.round((usedBytes / quotaBytes) * 100)) : 0;
    return {
      ...a,
      usedBytes,
      quotaBytes,
      percentUsed: percent
    };
  });

  const profiles = db.prepare('SELECT * FROM connection_profiles WHERE is_active = 1 ORDER BY name ASC').all();
  const createdKey = req.session.createdKey || null;
  req.session.createdKey = null; // show once

  res.render('admin/app_accounts', {
    accounts: accountsWithUsage,
    profiles,
    createdKey,
    error: req.query.error,
    success: req.query.success
  });
});

// Create app-linked account
router.post('/create', (req, res) => {
  try {
    const { username, password, device_id, type, profile_id, expiry_date, quota_gb, max_connections } = req.body;
    if (!username || !device_id || !profile_id) {
      throw new Error('Nom d\'utilisateur, ID appareil et profil sont requis.');
    }

    const formattedDeviceId = formatDeviceId(device_id);
    if (!validateDeviceId(formattedDeviceId)) {
      throw new Error('Format d\'ID appareil invalide (attendu: XXXX-XXXX-XXXX-X, Crockford base32 valide).');
    }

    const profile = db.prepare('SELECT * FROM connection_profiles WHERE id = ?').get(profile_id);
    if (!profile) throw new Error('Profil de connexion sélectionné introuvable.');

    // Check if account with same username already exists
    if (system.sshUserExistsOnSystem(username)) {
      throw new Error(`L'utilisateur système "${username}" existe déjà.`);
    }

    // Create system / users.db entry for SSH
    const finalPassword = password && password.trim() ? password.trim() : system.randomPassword(16);
    system.createSshUser({
      username,
      password: finalPassword,
      expiryDate: expiry_date || '',
      maxConnections: parseInt(max_connections, 10) || 1,
      quotaGb: quota_gb === '' ? null : parseFloat(quota_gb)
    });

    // Insert into app_accounts
    const insertAccount = db.prepare(`
      INSERT INTO app_accounts (username, type, profile_id, device_id, state, quota_gb, expiry_date, password)
      VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)
    `).run(username, type || 'ssh', profile_id, formattedDeviceId, parseFloat(quota_gb) || 0, expiry_date || '', finalPassword);

    const accountId = insertAccount.lastInsertRowid;

    // Generate activation key
    const actKey = createActivationKey();
    db.prepare(`
      INSERT INTO activation_keys (app_account_id, key_hash, key_last4, status)
      VALUES (?, ?, ?, 'unused')
    `).run(accountId, actKey.keyHash, actKey.keyLast4);

    audit.log('admin', req.session.username, 'app_account_create', `Création du compte app "${username}" lié à ${formattedDeviceId}`);

    // Store created key in session to display once
    req.session.createdKey = {
      username,
      deviceId: formattedDeviceId,
      key: actKey.key,
      serverCode: actKey.serverCode
    };

    res.redirect('/admin/app-accounts?success=' + encodeURIComponent(`Compte ${username} créé avec succès.`));
  } catch (e) {
    res.redirect('/admin/app-accounts?error=' + encodeURIComponent(e.message));
  }
});

// Regenerate key
router.post('/:id/regenerate-key', (req, res) => {
  const id = req.params.id;
  try {
    const account = db.prepare('SELECT * FROM app_accounts WHERE id = ?').get(id);
    if (!account) throw new Error('Compte introuvable.');

    // Revoke old keys
    db.prepare('UPDATE activation_keys SET status = \'revoked\' WHERE app_account_id = ?').run(id);

    // Generate new key
    const actKey = createActivationKey();
    db.prepare(`
      INSERT INTO activation_keys (app_account_id, key_hash, key_last4, status)
      VALUES (?, ?, ?, 'unused')
    `).run(id, actKey.keyHash, actKey.keyLast4);

    db.prepare('UPDATE app_accounts SET state = \'pending\', public_key = NULL WHERE id = ?').run(id);

    audit.log('admin', req.session.username, 'app_key_regenerate', `Régénération de la clé pour "${account.username}"`);

    req.session.createdKey = {
      username: account.username,
      deviceId: account.device_id,
      key: actKey.key,
      serverCode: actKey.serverCode
    };

    res.redirect('/admin/app-accounts?success=' + encodeURIComponent('Nouvelle clé générée.'));
  } catch (e) {
    res.redirect('/admin/app-accounts?error=' + encodeURIComponent(e.message));
  }
});

// Change device ID (app reinstallation)
router.post('/:id/change-device-id', (req, res) => {
  const id = req.params.id;
  try {
    const { new_device_id } = req.body;
    if (!new_device_id) throw new Error('Nouvel ID appareil requis.');

    const formatted = formatDeviceId(new_device_id);
    if (!validateDeviceId(formatted)) {
      throw new Error('Format d\'ID appareil invalide.');
    }

    const account = db.prepare('SELECT * FROM app_accounts WHERE id = ?').get(id);
    if (!account) throw new Error('Compte introuvable.');

    // Update device ID and reset public key so the new device can activate
    db.prepare(`
      UPDATE app_accounts
      SET device_id = ?, public_key = NULL, state = 'pending'
      WHERE id = ?
    `).run(formatted, id);

    // Revoke old key and make a fresh key for this device
    db.prepare('UPDATE activation_keys SET status = \'revoked\' WHERE app_account_id = ?').run(id);
    const actKey = createActivationKey();
    db.prepare(`
      INSERT INTO activation_keys (app_account_id, key_hash, key_last4, status)
      VALUES (?, ?, ?, 'unused')
    `).run(id, actKey.keyHash, actKey.keyLast4);

    audit.log('admin', req.session.username, 'app_change_device', `Changement d'ID appareil pour "${account.username}": ${account.device_id} -> ${formatted}`);

    req.session.createdKey = {
      username: account.username,
      deviceId: formatted,
      key: actKey.key,
      serverCode: actKey.serverCode
    };

    res.redirect('/admin/app-accounts?success=' + encodeURIComponent(`ID appareil mis à jour pour ${account.username}.`));
  } catch (e) {
    res.redirect('/admin/app-accounts?error=' + encodeURIComponent(e.message));
  }
});

// Revoke account
router.post('/:id/revoke', (req, res) => {
  const id = req.params.id;
  try {
    const account = db.prepare('SELECT * FROM app_accounts WHERE id = ?').get(id);
    if (!account) throw new Error('Compte introuvable.');

    db.prepare('UPDATE app_accounts SET state = \'revoked\' WHERE id = ?').run(id);
    db.prepare('UPDATE activation_keys SET status = \'revoked\' WHERE app_account_id = ?').run(id);

    audit.log('admin', req.session.username, 'app_account_revoke', `Révocation du compte app "${account.username}"`);
    res.redirect('/admin/app-accounts?success=' + encodeURIComponent(`Compte ${account.username} révoqué.`));
  } catch (e) {
    res.redirect('/admin/app-accounts?error=' + encodeURIComponent(e.message));
  }
});

// Delete account
router.post('/:id/delete', (req, res) => {
  const id = req.params.id;
  try {
    const account = db.prepare('SELECT * FROM app_accounts WHERE id = ?').get(id);
    if (!account) throw new Error('Compte introuvable.');

    // Delete system user
    try { system.deleteSshUser(account.username); } catch {}

    db.prepare('DELETE FROM app_accounts WHERE id = ?').run(id);

    audit.log('admin', req.session.username, 'app_account_delete', `Suppression du compte app "${account.username}"`);
    res.redirect('/admin/app-accounts?success=' + encodeURIComponent(`Compte ${account.username} supprimé.`));
  } catch (e) {
    res.redirect('/admin/app-accounts?error=' + encodeURIComponent(e.message));
  }
});

module.exports = router;
