const express = require('express');
const fs = require('fs');
const path = require('path');
const db = require('../db/database');
const quota = require('../lib/quota');
const clientsLib = require('../lib/clients');
const system = require('../lib/system');
const { validateDeviceId, formatDeviceId } = require('../lib/crockford');
const { createActivationKey } = require('../lib/activationKey');
const audit = require('../lib/audit');
const connectionInfo = require('../lib/connectionInfo');
const config = require('../config');
const { requireReseller } = require('../middleware/auth');

const router = express.Router();
router.use(requireReseller);

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

function loadSelf(req) {
  return db.prepare('SELECT * FROM resellers WHERE id = ?').get(req.session.userId);
}

function actorFrom(req) {
  return { type: 'reseller', name: req.session.username };
}

router.get('/', (req, res) => {
  const reseller = loadSelf(req);
  if (!reseller) return res.redirect('/login');
  const stats = quota.getResellerStats(reseller);
  const clients = stats.clients.map((c) => ({
    ...c,
    usageGb: clientsLib.clientUsageGb(c),
    connectionInfo: connectionInfo.buildConnectionInfo(c),
    password: clientsLib.getClientPassword(c),
    onlineCount: c._online
  }));
  const deletedClients = clientsLib.getDeletedClients(reseller.id);
  const activity = audit.recentByActor(reseller.id, 'reseller', 10);
  const allowedProtocols = config.PROTOCOLS.filter((p) => JSON.parse(reseller.protocols || '[]').includes(p.key));

  // Load Surfeo accounts for this reseller
  const surfeoAccounts = db.prepare(`
    SELECT a.*, p.name AS profile_name, p.version AS profile_version,
           k.key_last4, k.status AS key_status
    FROM app_accounts a
    LEFT JOIN connection_profiles p ON a.profile_id = p.id
    LEFT JOIN activation_keys k ON k.app_account_id = a.id AND k.status != 'revoked'
    WHERE a.reseller_id = ?
    ORDER BY a.id DESC
  `).all(reseller.id);

  const surfeoAccountsWithUsage = surfeoAccounts.map((a) => {
    const usedBytes = getUserUsedBytes(a.username);
    const quotaGb = parseFloat(a.quota_gb) || 0;
    const quotaBytes = quotaGb > 0 ? Math.round(quotaGb * 1024 * 1024 * 1024) : 0;
    const percent = quotaBytes > 0 ? Math.min(100, Math.round((usedBytes / quotaBytes) * 100)) : 0;
    const devices = db.prepare('SELECT id, device_id, device_platform, app_version, last_active_at FROM app_account_devices WHERE app_account_id = ?').all(a.id);
    return {
      ...a,
      usedBytes,
      quotaBytes,
      percentUsed: percent,
      devices,
      max_devices: a.max_devices || 2
    };
  });

  const profiles = db.prepare('SELECT * FROM connection_profiles WHERE is_active = 1 ORDER BY name ASC').all();
  const createdKey = req.session.createdKey || null;
  req.session.createdKey = null;

  res.render('reseller/dashboard', {
    reseller, stats, clients, deletedClients, activity, allowedProtocols,
    surfeoAccounts: surfeoAccountsWithUsage, profiles, createdKey,
    error: req.query.error, success: req.query.success
  });
});

router.get('/activity', (req, res) => {
  const reseller = loadSelf(req);
  if (!reseller) return res.redirect('/login');
  const activity = audit.recentByActor(reseller.id, 'reseller', 300);
  res.render('activity', { activity, backUrl: '/reseller' });
});

router.post('/clients', (req, res) => {
  const reseller = loadSelf(req);
  try {
    const result = clientsLib.createClient(reseller.id, req.body, actorFrom(req));
    let msg = 'Compte client créé.';
    if (result.password) msg += ` Identifiants — ${req.body.type === 'ssh' ? 'utilisateur' : 'mot de passe'}: ${result.identifier}${req.body.type === 'ssh' ? ' / mdp: ' + result.password : ''}`;
    res.redirect('/reseller?success=' + encodeURIComponent(msg));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

router.post('/clients/:clientId/edit', (req, res) => {
  const reseller = loadSelf(req);
  const client = db.prepare('SELECT * FROM clients WHERE id = ? AND reseller_id = ?').get(req.params.clientId, reseller.id);
  if (!client) return res.redirect('/reseller?error=Client introuvable');
  try {
    clientsLib.editClient(client.id, req.body, actorFrom(req));
    res.redirect('/reseller?success=' + encodeURIComponent('Client mis à jour.'));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

router.post('/clients/:clientId/delete', (req, res) => {
  const reseller = loadSelf(req);
  const client = db.prepare('SELECT * FROM clients WHERE id = ? AND reseller_id = ?').get(req.params.clientId, reseller.id);
  if (!client) return res.redirect('/reseller?error=Client introuvable');
  try {
    clientsLib.deleteClient(client.id, actorFrom(req));
    res.redirect('/reseller?success=' + encodeURIComponent('Client supprimé.'));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

router.post('/clients/:clientId/reset-usage', (req, res) => {
  const reseller = loadSelf(req);
  const client = db.prepare('SELECT * FROM clients WHERE id = ? AND reseller_id = ?').get(req.params.clientId, reseller.id);
  if (!client) return res.redirect('/reseller?error=Client introuvable');
  try {
    clientsLib.resetClientUsage(client.id, actorFrom(req));
    res.redirect('/reseller?success=' + encodeURIComponent('Consommation du client réinitialisée.'));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

router.post('/clients/:clientId/toggle-lock', (req, res) => {
  const reseller = loadSelf(req);
  const client = db.prepare('SELECT * FROM clients WHERE id = ? AND reseller_id = ?').get(req.params.clientId, reseller.id);
  if (!client) return res.redirect('/reseller?error=Client introuvable');
  try {
    if (client.status === 'locked_manual') clientsLib.unlockClient(client.id, actorFrom(req));
    else clientsLib.lockClient(client.id, actorFrom(req));
    res.redirect('/reseller?success=' + encodeURIComponent('Statut mis à jour.'));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

router.post('/clients/:clientId/password', (req, res) => {
  const reseller = loadSelf(req);
  const client = db.prepare('SELECT * FROM clients WHERE id = ? AND reseller_id = ?').get(req.params.clientId, reseller.id);
  if (!client) return res.redirect('/reseller?error=Client introuvable');
  try {
    const newPass = clientsLib.changeClientPassword(client.id, req.body.new_password, actorFrom(req));
    res.redirect('/reseller?success=' + encodeURIComponent('Mot de passe mis à jour : ' + newPass));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

router.post('/change-password', (req, res) => {
  const reseller = loadSelf(req);
  try {
    const { new_password } = req.body;
    if (!new_password || new_password.length < 6) throw new Error('Le mot de passe doit contenir au moins 6 caractères.');
    const bcrypt = require('bcryptjs');
    const hash = bcrypt.hashSync(new_password, 10);
    db.prepare('UPDATE resellers SET password_hash = ? WHERE id = ?').run(hash, reseller.id);
    audit.log('reseller', req.session.username, 'reseller_change_password', 'Mot de passe changé', reseller.id);
    res.redirect('/reseller?success=' + encodeURIComponent('Mot de passe mis à jour.'));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

// -------------------------------------------------------------
// Reseller Surfeo Account Management
// -------------------------------------------------------------
router.post('/surfeo/create', (req, res) => {
  const reseller = loadSelf(req);
  if (!reseller) return res.redirect('/login');

  try {
    const { username, password, device_id, type, profile_id, expiry_date, quota_gb } = req.body;
    if (!username || !device_id || !profile_id) {
      throw new Error('Nom d\'utilisateur, ID appareil et profil sont requis.');
    }

    // Check reseller allocation limits
    const currentCount = db.prepare('SELECT COUNT(*) AS c FROM app_accounts WHERE reseller_id = ?').get(reseller.id).c;
    const maxSurfeo = reseller.max_surfeo_users != null ? reseller.max_surfeo_users : 5;
    if (currentCount >= maxSurfeo) {
      throw new Error(`Limite atteinte : votre allocation est de ${maxSurfeo} compte(s) Surfeo maximum.`);
    }

    const requestedQuota = parseFloat(quota_gb) || 0;
    if (reseller.surfeo_quota_gb != null && requestedQuota > reseller.surfeo_quota_gb) {
      throw new Error(`Le quota demandé (${requestedQuota} Go) dépasse votre quota alloué (${reseller.surfeo_quota_gb} Go).`);
    }

    let formattedDeviceId = '';
    if (device_id && device_id.trim()) {
      formattedDeviceId = formatDeviceId(device_id.trim());
    }

    const maxDev = Math.max(1, parseInt(req.body.max_devices, 10) || 2);

    const profile = db.prepare('SELECT * FROM connection_profiles WHERE id = ?').get(profile_id);
    if (!profile) throw new Error('Profil de connexion sélectionné introuvable.');

    if (system.sshUserExistsOnSystem(username)) {
      throw new Error(`L'utilisateur système "${username}" existe déjà.`);
    }

    const finalPassword = password && password.trim() ? password.trim() : system.randomPassword(16);
    system.createSshUser({
      username,
      password: finalPassword,
      expiryDate: expiry_date || '',
      maxConnections: maxDev,
      quotaGb: quota_gb === '' ? null : parseFloat(quota_gb)
    });

    const insertAccount = db.prepare(`
      INSERT INTO app_accounts (username, type, profile_id, device_id, state, quota_gb, expiry_date, password, reseller_id, max_devices)
      VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)
    `).run(username, type || 'ssh', profile_id, formattedDeviceId, parseFloat(quota_gb) || 0, expiry_date || '', finalPassword, reseller.id, maxDev);

    const accountId = insertAccount.lastInsertRowid;

    if (formattedDeviceId) {
      db.prepare(`
        INSERT OR IGNORE INTO app_account_devices (app_account_id, device_id, device_platform, activated_at, last_active_at)
        VALUES (?, ?, 'manual', datetime('now'), datetime('now'))
      `).run(accountId, formattedDeviceId);
    }

    const actKey = createActivationKey();
    db.prepare(`
      INSERT INTO activation_keys (app_account_id, key_hash, key_last4, status)
      VALUES (?, ?, ?, 'unused')
    `).run(accountId, actKey.keyHash, actKey.keyLast4);

    audit.log('reseller', reseller.username, 'app_account_create', `Création du compte Surfeo "${username}" (max ${maxDev} appareils)`, accountId);

    req.session.createdKey = {
      username,
      deviceId: formattedDeviceId || 'Auto (à l\'activation)',
      maxDevices: maxDev,
      key: actKey.key,
      serverCode: actKey.serverCode
    };

    res.redirect('/reseller?success=' + encodeURIComponent(`Compte Surfeo ${username} créé avec succès.`));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
});

// Reset devices for reseller app account
function handleResetDevices(req, res) {
  const reseller = req.reseller;
  const id = req.params.id;
  try {
    const acc = db.prepare('SELECT * FROM app_accounts WHERE id = ? AND reseller_id = ?').get(id, reseller.id);
    if (!acc) throw new Error('Compte Surfeo introuvable ou non autorisé.');

    db.prepare('DELETE FROM app_account_devices WHERE app_account_id = ?').run(id);
    db.prepare("UPDATE app_accounts SET device_id = '' WHERE id = ?").run(id);

    audit.log('reseller', reseller.username, 'app_account_reset_devices', `Dissociation des appareils pour "${acc.username}"`, id);

    res.redirect('/reseller?success=' + encodeURIComponent(`Les appareils pour ${acc.username} ont été dissociés.`));
  } catch (e) {
    res.redirect('/reseller?error=' + encodeURIComponent(e.message));
  }
}

router.post('/app-accounts/:id/reset-devices', handleResetDevices);
router.post('/surfeo/:id/reset-devices', handleResetDevices);

router.post('/surfeo/:id/regenerate-key', (req, res) => {
  const reseller = loadSelf(req);
  const id = req.params.id;
  const acc = db.prepare('SELECT * FROM app_accounts WHERE id = ? AND reseller_id = ?').get(id, reseller.id);
  if (!acc) return res.redirect('/reseller?error=Compte Surfeo introuvable');

  db.prepare('UPDATE activation_keys SET status = \'revoked\' WHERE app_account_id = ?').run(id);
  const actKey = createActivationKey();
  db.prepare(`
    INSERT INTO activation_keys (app_account_id, key_hash, key_last4, status)
    VALUES (?, ?, ?, 'unused')
  `).run(id, actKey.keyHash, actKey.keyLast4);

  req.session.createdKey = {
    username: acc.username,
    deviceId: acc.device_id,
    key: actKey.key,
    serverCode: actKey.serverCode
  };
  res.redirect('/reseller?success=' + encodeURIComponent('Nouvelle clé Surfeo générée avec succès.'));
});

router.post('/surfeo/:id/delete', (req, res) => {
  const reseller = loadSelf(req);
  const id = req.params.id;
  const acc = db.prepare('SELECT * FROM app_accounts WHERE id = ? AND reseller_id = ?').get(id, reseller.id);
  if (!acc) return res.redirect('/reseller?error=Compte Surfeo introuvable');

  system.deleteSshUser(acc.username);
  db.prepare('DELETE FROM app_accounts WHERE id = ?').run(id);
  res.redirect('/reseller?success=' + encodeURIComponent(`Compte Surfeo ${acc.username} supprimé.`));
});

module.exports = router;
