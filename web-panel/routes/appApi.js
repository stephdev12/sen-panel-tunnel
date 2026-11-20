const express = require('express');
const fs = require('fs');
const path = require('path');
const db = require('../db/database');
const config = require('../config');
const system = require('../lib/system');
const { validateDeviceId, formatDeviceId } = require('../lib/crockford');
const { hashActivationKey, normalizeKey } = require('../lib/activationKey');
const { signResponse, verifyDeviceRequest } = require('../lib/appSecurity');

const router = express.Router();

// Rate limiting state for activation attempts (IP and DeviceId -> { count, resetAt })
const rateLimitMap = new Map();

function checkRateLimit(key, maxAttempts = 10, windowMs = 10 * 60 * 1000) {
  const now = Date.now();
  let entry = rateLimitMap.get(key);
  if (!entry || entry.resetAt < now) {
    entry = { count: 1, resetAt: now + windowMs };
    rateLimitMap.set(key, entry);
    return { limited: false };
  }
  entry.count++;
  if (entry.count > maxAttempts) {
    const retryAfter = Math.ceil((entry.resetAt - now) / 1000);
    return { limited: true, retryAfter };
  }
  return { limited: false };
}

/**
 * Helper to read live bandwidth used in bytes for a user.
 */
function getUserUsedBytes(username) {
  const usageFile = path.join(config.BANDWIDTH_DIR, `${username}.usage`);
  try {
    if (fs.existsSync(usageFile)) {
      const content = fs.readFileSync(usageFile, 'utf8').trim();
      const bytes = parseInt(content, 10);
      return isNaN(bytes) ? 0 : bytes;
    }
  } catch {
    // Ignore read errors
  }
  return 0;
}

/**
 * Helper to get subscription status and details safely.
 */
function buildSubscriptionInfo(appAccount) {
  try {
    let userEntry = {};
    try {
      const usersDb = system.readUsersDb();
      userEntry = usersDb.find((u) => u.username === appAccount.username) || {};
    } catch (dbErr) {
      console.warn('[AppApi] Could not read users.db:', dbErr.message);
    }

    const usedBytes = getUserUsedBytes(appAccount.username);
    const quotaGb = parseFloat(userEntry.bandwidthGb) || 0;
    const quotaBytes = quotaGb > 0 ? Math.round(quotaGb * 1024 * 1024 * 1024) : 0; // 0 = unlimited

    const expireDate = userEntry.expireDate || null;
    const now = new Date();
    let isExpired = false;
    if (expireDate) {
      const exp = new Date(expireDate);
      if (exp < now) isExpired = true;
    }

    let isQuotaExhausted = false;
    if (quotaBytes > 0 && usedBytes >= quotaBytes) {
      isQuotaExhausted = true;
    }

    let state = appAccount.state || 'active';
    if (state === 'active') {
      if (isExpired) state = 'expired';
      else if (isQuotaExhausted) state = 'quota_exhausted';
    }

    // Count active sessions safely
    let activeSessions = 0;
    try {
      const managedUsers = new Set([appAccount.username]);
      const pids = system.mapSshdPidsToUsers(managedUsers);
      for (const [, user] of pids.entries()) {
        if (user === appAccount.username) activeSessions++;
      }
    } catch {
      activeSessions = 0;
    }

    return {
      state,
      quotaBytes,
      usedBytes,
      expiresAt: expireDate ? `${expireDate}T23:59:59Z` : null,
      activeSessions,
      serverTime: now.toISOString()
    };
  } catch (err) {
    console.error('[AppApi] buildSubscriptionInfo error:', err);
    return {
      state: appAccount.state || 'active',
      quotaBytes: 0,
      usedBytes: 0,
      expiresAt: null,
      activeSessions: 0,
      serverTime: new Date().toISOString()
    };
  }
}

/**
 * Helper to build config payload for the app safely.
 */
function buildConfigPayload(profile, appAccount) {
  let userEntry = {};
  try {
    const usersDb = system.readUsersDb();
    userEntry = usersDb.find((u) => u.username === appAccount.username) || {};
  } catch (dbErr) {
    console.warn('[AppApi] Could not read users.db for config:', dbErr.message);
  }

  let parsedParams = {};
  try {
    parsedParams = JSON.parse(profile.params || '{}');
  } catch {
    parsedParams = {};
  }

  if (profile.type === 'ssh') {
    return {
      type: 'ssh',
      configVersion: profile.version || 1,
      ssh: {
        host: parsedParams.host || '127.0.0.1',
        port: parseInt(parsedParams.port, 10) || 80,
        tls: Boolean(parsedParams.tls),
        sni: parsedParams.sni || null,
        username: appAccount.username,
        password: userEntry.password || '',
        payload: parsedParams.payload || 'GET /sen HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]',
        proxy: parsedParams.proxy || { enabled: false, host: null, port: null },
        udpgwPort: parseInt(parsedParams.udpgwPort, 10) || 7300,
        dns: Array.isArray(parsedParams.dns) ? parsedParams.dns : ['1.1.1.1', '8.8.8.8']
      }
    };
  } else {
    return {
      type: 'udp',
      configVersion: profile.version || 1,
      udp: {
        server: parsedParams.server || '127.0.0.1',
        port: parseInt(parsedParams.port, 10) || 7300,
        auth: userEntry.password || parsedParams.auth || '',
        window: parseInt(parsedParams.window, 10) || 2,
        resolver: parsedParams.resolver || '127.0.0.1:7300',
        boostSlowdns: Boolean(parsedParams.boostSlowdns),
        dnsForward: Boolean(parsedParams.dnsForward)
      }
    };
  }
}

// -------------------------------------------------------------
// GET /api/app/v1/meta
// Public: returns server metadata and min app version
// -------------------------------------------------------------
router.get('/meta', (req, res) => {
  try {
    const meta = {
      minAppVersion: '1.0.0',
      latestAppVersion: '1.0.0',
      maintenance: false,
      message: '',
      serverTime: new Date().toISOString()
    };
    const jsonStr = JSON.stringify(meta);
    try {
      res.setHeader('X-Server-Signature', signResponse(jsonStr));
    } catch {}
    return res.json(meta);
  } catch (err) {
    return res.status(500).json({ error: 'server_error', message: err.message });
  }
});

// -------------------------------------------------------------
// POST /api/app/v1/activate
// Activates key and binds device public key
// -------------------------------------------------------------
router.post('/activate', express.json(), (req, res) => {
  try {
    const ip = req.ip || req.connection.remoteAddress || 'unknown';
    const { key, deviceId, publicKey, appVersion, lang } = req.body;

    if (!key || !deviceId) {
      return res.status(400).json({ error: 'invalid_key', message: 'Clé ou ID appareil manquant.' });
    }

    // Rate limit check
    const ipLimit = checkRateLimit(`ip:${ip}`);
    const devLimit = checkRateLimit(`dev:${deviceId}`);
    if (ipLimit.limited || devLimit.limited) {
      const retryAfter = Math.max(ipLimit.retryAfter || 0, devLimit.retryAfter || 0);
      res.setHeader('Retry-After', retryAfter);
      return res.status(429).json({ error: 'rate_limited', message: `Trop d'essais. Réessayez dans ${retryAfter}s.` });
    }

    // Validate Device ID format
    const formattedDeviceId = formatDeviceId(deviceId);
    if (!validateDeviceId(formattedDeviceId)) {
      return res.status(400).json({ error: 'invalid_device_id', message: 'Format d\'ID appareil invalide.' });
    }

    // Find key by hash
    const keyHash = hashActivationKey(key);
    const keyRecord = db.prepare('SELECT * FROM activation_keys WHERE key_hash = ?').get(keyHash);
    if (!keyRecord) {
      return res.status(400).json({ error: 'invalid_key', message: 'Clé d\'activation inconnue ou incorrecte.' });
    }

    if (keyRecord.status === 'revoked') {
      return res.status(410).json({ error: 'expired_or_revoked', message: 'Cette clé a été révoquée.' });
    }

    // Fetch target app_account
    const appAccount = db.prepare('SELECT * FROM app_accounts WHERE id = ?').get(keyRecord.app_account_id);
    if (!appAccount) {
      return res.status(404).json({ error: 'account_not_found', message: 'Compte associé introuvable.' });
    }

    if (keyRecord.status === 'used') {
      // If already used, check if it's the exact same device re-requesting
      if (appAccount.device_id !== formattedDeviceId) {
        return res.status(403).json({ error: 'device_mismatch', message: 'Cette clé est liée à un autre appareil.' });
      }
    }

    // Device binding check
    if (appAccount.device_id !== formattedDeviceId) {
      return res.status(403).json({ error: 'device_mismatch', message: 'La clé ne correspond pas à cet appareil.' });
    }

    if (appAccount.state === 'revoked' || appAccount.state === 'deleted') {
      return res.status(410).json({ error: 'expired_or_revoked', message: 'Compte révoqué ou supprimé.' });
    }

    // Update account with public key and activate
    const now = new Date().toISOString();
    db.prepare(`
      UPDATE app_accounts
      SET public_key = ?, state = 'active', activated_at = COALESCE(activated_at, ?), last_active_at = ?, app_version = ?
      WHERE id = ?
    `).run(publicKey || '', now, now, appVersion || '1.0.0', appAccount.id);

    db.prepare(`
      UPDATE activation_keys
      SET status = 'used'
      WHERE id = ?
    `).run(keyRecord.id);

    // Fetch connection profile
    let profile = null;
    if (appAccount.profile_id) {
      profile = db.prepare('SELECT * FROM connection_profiles WHERE id = ?').get(appAccount.profile_id);
    }
    if (!profile) {
      profile = db.prepare('SELECT * FROM connection_profiles WHERE is_active = 1 ORDER BY id ASC LIMIT 1').get();
    }
    if (!profile) {
      return res.status(500).json({ error: 'profile_missing', message: 'Aucun profil de connexion actif configuré sur le serveur.' });
    }

    const subscription = buildSubscriptionInfo(appAccount);
    const configObj = buildConfigPayload(profile, appAccount);

    const responsePayload = {
      subscription,
      config: configObj,
      configVersion: profile.version || 1
    };

    const jsonStr = JSON.stringify(responsePayload);
    try {
      res.setHeader('X-Server-Signature', signResponse(jsonStr));
    } catch {}
    return res.json(responsePayload);
  } catch (err) {
    console.error('[AppApi] /activate unexpected error:', err);
    return res.status(500).json({
      error: 'server_error',
      message: `Erreur interne serveur: ${err.message}`
    });
  }
});

// -------------------------------------------------------------
// Middleware: Authenticate active device request
// -------------------------------------------------------------
function requireDeviceAuth(req, res, next) {
  try {
    const deviceIdHeader = req.headers['x-device-id'];
    if (!deviceIdHeader) {
      return res.status(401).json({ error: 'missing_device_id', message: 'En-tête X-Device-Id manquant.' });
    }

    const formattedId = formatDeviceId(deviceIdHeader);
    const appAccount = db.prepare('SELECT * FROM app_accounts WHERE device_id = ?').get(formattedId);
    if (!appAccount) {
      return res.status(404).json({ error: 'account_not_found', message: 'Appareil non enregistré.' });
    }

    if (appAccount.state === 'revoked' || appAccount.state === 'deleted') {
      return res.status(410).json({ error: 'expired_or_revoked', message: 'Ce forfait a été révoqué ou supprimé.' });
    }

    // Check signature if public key is present
    if (appAccount.public_key) {
      const auth = verifyDeviceRequest(req, appAccount.public_key);
      if (!auth.valid) {
        return res.status(401).json({ error: 'bad_signature', message: auth.error || 'Signature invalide.' });
      }
    }

    req.appAccount = appAccount;
    next();
  } catch (err) {
    console.error('[AppApi] requireDeviceAuth error:', err);
    return res.status(500).json({ error: 'server_error', message: err.message });
  }
}

// -------------------------------------------------------------
// GET /api/app/v1/status
// Polled every 15 seconds during active VPN session
// -------------------------------------------------------------
router.get('/status', requireDeviceAuth, (req, res) => {
  try {
    const appAccount = req.appAccount;
    const now = new Date().toISOString();

    // Update last active timestamp
    db.prepare('UPDATE app_accounts SET last_active_at = ? WHERE id = ?').run(now, appAccount.id);

    let profile = null;
    if (appAccount.profile_id) {
      profile = db.prepare('SELECT * FROM connection_profiles WHERE id = ?').get(appAccount.profile_id);
    }
    const subscription = buildSubscriptionInfo(appAccount);

    const responsePayload = {
      ...subscription,
      configVersion: profile ? profile.version : 1,
      minAppVersion: '1.0.0'
    };

    const jsonStr = JSON.stringify(responsePayload);
    try {
      res.setHeader('X-Server-Signature', signResponse(jsonStr));
    } catch {}
    return res.json(responsePayload);
  } catch (err) {
    console.error('[AppApi] /status error:', err);
    return res.status(500).json({ error: 'server_error', message: err.message });
  }
});

// -------------------------------------------------------------
// GET /api/app/v1/config?since=<version>
// Returns 304 if unchanged, otherwise full new config
// -------------------------------------------------------------
router.get('/config', requireDeviceAuth, (req, res) => {
  try {
    const appAccount = req.appAccount;
    let profile = null;
    if (appAccount.profile_id) {
      profile = db.prepare('SELECT * FROM connection_profiles WHERE id = ?').get(appAccount.profile_id);
    }
    if (!profile) {
      profile = db.prepare('SELECT * FROM connection_profiles WHERE is_active = 1 ORDER BY id ASC LIMIT 1').get();
    }
    if (!profile) {
      return res.status(404).json({ error: 'profile_not_found', message: 'Profil introuvable.' });
    }

    const since = parseInt(req.query.since, 10);
    if (!isNaN(since) && since >= profile.version) {
      return res.status(304).end();
    }

    const configObj = buildConfigPayload(profile, appAccount);
    const jsonStr = JSON.stringify(configObj);
    try {
      res.setHeader('X-Server-Signature', signResponse(jsonStr));
    } catch {}
    return res.json(configObj);
  } catch (err) {
    console.error('[AppApi] /config error:', err);
    return res.status(500).json({ error: 'server_error', message: err.message });
  }
});

module.exports = router;
