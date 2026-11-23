const db = require('../db/database');
const clientsLib = require('../lib/clients');
const audit = require('../lib/audit');
const quota = require('../lib/quota');

const SYSTEM_ACTOR = { type: 'system', name: 'système (expiration)' };
const QUOTA_ACTOR = { type: 'system', name: 'système (quota)' };

function today() {
  return new Date().toISOString().slice(0, 10);
}

function runEnforcement() {
  const t = today();

  // --- 1. Reseller-level expiry and real quota cascade ---
  const resellers = db.prepare('SELECT * FROM resellers').all();
  for (const reseller of resellers) {
    const isExpired = reseller.expiry_date && reseller.expiry_date < t;
    let isQuotaExhausted = false;
    let stats = null;

    if (reseller.data_quota_gb != null) {
      try {
        stats = quota.getResellerStats(reseller);
        isQuotaExhausted = stats.consumedTotalGb >= reseller.data_quota_gb;
      } catch {}
    }

    const shouldLock = isExpired || isQuotaExhausted;

    if (shouldLock && reseller.status === 'active') {
      const reason = isExpired 
        ? `compte expiré le ${reseller.expiry_date}` 
        : `quota de données atteint (${stats.consumedTotalGb.toFixed(2)} / ${reseller.data_quota_gb} Go)`;

      db.prepare(`UPDATE resellers SET status = 'locked_expired' WHERE id = ?`).run(reseller.id);
      audit.log('system', 'système (enforcement)', 'reseller_lock_expired',
        `Reseller "${reseller.username}" verrouillé automatiquement (${reason})`, reseller.id);

      const active = db.prepare(`SELECT * FROM clients WHERE reseller_id = ? AND deleted = 0 AND status = 'active'`).all(reseller.id);
      for (const c of active) {
        try {
          clientsLib.lockClient(c.id, SYSTEM_ACTOR);
          db.prepare(`UPDATE clients SET status = 'locked_reseller' WHERE id = ?`).run(c.id);
        } catch (e) { console.error('Erreur verrouillage client', c.id, e.message); }
      }
    }

    if (!shouldLock && reseller.status === 'locked_expired') {
      db.prepare(`UPDATE resellers SET status = 'active' WHERE id = ?`).run(reseller.id);
      audit.log('system', 'système (renouvellement)', 'reseller_unlock',
        `Reseller "${reseller.username}" réactivé automatiquement (quota ou validité renouvelé)`, reseller.id);

      const locked = db.prepare(`SELECT * FROM clients WHERE reseller_id = ? AND deleted = 0 AND status = 'locked_reseller'`).all(reseller.id);
      for (const c of locked) {
        try {
          clientsLib.unlockClient(c.id, SYSTEM_ACTOR);
        } catch (e) { console.error('Erreur déverrouillage client', c.id, e.message); }
      }
    }
  }

  // --- 2. Client-level individual expiry (independent of reseller status) ---
  const activeClients = db.prepare(`SELECT * FROM clients WHERE deleted = 0 AND status = 'active'`).all();
  for (const c of activeClients) {
    if (c.expiry_date && c.expiry_date < t) {
      try {
        clientsLib.lockClient(c.id, SYSTEM_ACTOR);
        db.prepare(`UPDATE clients SET status = 'locked_expired' WHERE id = ?`).run(c.id);
        audit.log('system', 'système (expiration)', 'client_lock_expired',
          `Compte ${c.type.toUpperCase()} "${c.identifier}" verrouillé automatiquement (date d'expiration dépassée le ${c.expiry_date})`, c.reseller_id);
      } catch (e) { console.error('Erreur verrouillage (expiration) client', c.id, e.message); }
    }
  }

  // --- 3. Client-level quota expiry: same "locked_expired" status/counter as date expiry
  // (see quota.js's expiredCount and the "Expired" label in the UI) - a client that has
  // consumed its data quota is just as "expired" from the reseller/admin's point of view as
  // one whose date passed, and should show up the same way instead of silently staying
  // "active" with 100%+ usage and no explanation on the dashboard.
  const activeClientsForQuota = db.prepare(`SELECT * FROM clients WHERE deleted = 0 AND status = 'active' AND quota_gb IS NOT NULL`).all();
  for (const c of activeClientsForQuota) {
    const usageGb = clientsLib.clientUsageGb(c);
    if (usageGb != null && usageGb >= c.quota_gb) {
      try {
        clientsLib.lockClient(c.id, QUOTA_ACTOR);
        db.prepare(`UPDATE clients SET status = 'locked_expired' WHERE id = ?`).run(c.id);
        audit.log('system', 'système (quota)', 'client_lock_quota',
          `Compte ${c.type.toUpperCase()} "${c.identifier}" verrouillé automatiquement (quota de données atteint : ${usageGb.toFixed(2)} / ${c.quota_gb} Go)`, c.reseller_id);
      } catch (e) { console.error('Erreur verrouillage (quota) client', c.id, e.message); }
    }
  }
}

module.exports = { runEnforcement };
