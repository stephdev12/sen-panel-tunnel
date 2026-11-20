const express = require('express');
const db = require('../db/database');
const { requireAdmin } = require('../middleware/auth');
const audit = require('../lib/audit');

const router = express.Router();
router.use(requireAdmin);

// List profiles
router.get('/', (req, res) => {
  const profiles = db.prepare('SELECT * FROM connection_profiles ORDER BY id DESC').all();
  res.render('admin/profiles', {
    profiles: profiles.map((p) => {
      let params = {};
      try { params = JSON.parse(p.params); } catch {}
      return { ...p, parsedParams: params };
    }),
    error: req.query.error,
    success: req.query.success
  });
});

// Create profile
router.post('/create', (req, res) => {
  try {
    const { name, type, host, port, tls, sni, payload, proxy_enabled, proxy_host, proxy_port, udpgwPort, dns, udp_server, udp_port, window, resolver, boostSlowdns, dnsForward, mode } = req.body;
    if (!name || !type) throw new Error('Nom et type obligatoires.');

    let paramsObj = {};
    if (type === 'ssh') {
      paramsObj = {
        host: host || '',
        port: parseInt(port, 10) || 80,
        tls: tls === 'on' || tls === 'true',
        sni: sni || null,
        payload: payload || '',
        proxy: {
          enabled: proxy_enabled === 'on' || proxy_enabled === 'true',
          host: proxy_host || null,
          port: parseInt(proxy_port, 10) || null
        },
        udpgwPort: parseInt(udpgwPort, 10) || 7300,
        dns: dns ? dns.split(',').map((s) => s.trim()).filter(Boolean) : ['1.1.1.1', '8.8.8.8']
      };
    } else {
      paramsObj = {
        server: udp_server || '',
        port: parseInt(udp_port, 10) || 7300,
        window: parseInt(window, 10) || 2,
        resolver: resolver || '127.0.0.1:7300',
        boostSlowdns: boostSlowdns === 'on' || boostSlowdns === 'true',
        dnsForward: dnsForward === 'on' || dnsForward === 'true',
        mode: mode || 'SlowDNS'
      };
    }

    db.prepare(`
      INSERT INTO connection_profiles (name, type, is_active, params, version)
      VALUES (?, ?, 1, ?, 1)
    `).run(name, type, JSON.stringify(paramsObj));

    audit.log('admin', req.session.username, 'profile_create', `Création du profil "${name}" (${type})`);
    res.redirect('/admin/profiles?success=' + encodeURIComponent('Profil créé avec succès.'));
  } catch (e) {
    res.redirect('/admin/profiles?error=' + encodeURIComponent(e.message));
  }
});

// Edit profile (increments version!)
router.post('/:id/edit', (req, res) => {
  const id = req.params.id;
  try {
    const existing = db.prepare('SELECT * FROM connection_profiles WHERE id = ?').get(id);
    if (!existing) throw new Error('Profil introuvable.');

    const { name, is_active, host, port, tls, sni, payload, proxy_enabled, proxy_host, proxy_port, udpgwPort, dns, udp_server, udp_port, window, resolver, boostSlowdns, dnsForward, mode } = req.body;

    let paramsObj = {};
    if (existing.type === 'ssh') {
      paramsObj = {
        host: host || '',
        port: parseInt(port, 10) || 80,
        tls: tls === 'on' || tls === 'true',
        sni: sni || null,
        payload: payload || '',
        proxy: {
          enabled: proxy_enabled === 'on' || proxy_enabled === 'true',
          host: proxy_host || null,
          port: parseInt(proxy_port, 10) || null
        },
        udpgwPort: parseInt(udpgwPort, 10) || 7300,
        dns: dns ? dns.split(',').map((s) => s.trim()).filter(Boolean) : ['1.1.1.1', '8.8.8.8']
      };
    } else {
      paramsObj = {
        server: udp_server || '',
        port: parseInt(udp_port, 10) || 7300,
        window: parseInt(window, 10) || 2,
        resolver: resolver || '127.0.0.1:7300',
        boostSlowdns: boostSlowdns === 'on' || boostSlowdns === 'true',
        dnsForward: dnsForward === 'on' || dnsForward === 'true',
        mode: mode || 'SlowDNS'
      };
    }

    const nextVersion = existing.version + 1;
    const now = new Date().toISOString();

    db.prepare(`
      UPDATE connection_profiles
      SET name = ?, is_active = ?, params = ?, version = ?, updated_at = ?
      WHERE id = ?
    `).run(
      name || existing.name,
      is_active === 'on' || is_active === '1' ? 1 : 0,
      JSON.stringify(paramsObj),
      nextVersion,
      now,
      id
    );

    audit.log('admin', req.session.username, 'profile_edit', `Mise à jour du profil "${existing.name}" (version ${nextVersion})`);
    res.redirect('/admin/profiles?success=' + encodeURIComponent(`Profil mis à jour (v${nextVersion}).`));
  } catch (e) {
    res.redirect('/admin/profiles?error=' + encodeURIComponent(e.message));
  }
});

// Delete profile (blocked if in use)
router.post('/:id/delete', (req, res) => {
  const id = req.params.id;
  try {
    const inUse = db.prepare('SELECT COUNT(*) as c FROM app_accounts WHERE profile_id = ?').get(id);
    if (inUse.c > 0) {
      throw new Error(`Ce profil est utilisé par ${inUse.c} compte(s) lié(s) à l'application. Suppression impossible.`);
    }

    const existing = db.prepare('SELECT name FROM connection_profiles WHERE id = ?').get(id);
    db.prepare('DELETE FROM connection_profiles WHERE id = ?').run(id);

    audit.log('admin', req.session.username, 'profile_delete', `Suppression du profil "${existing ? existing.name : id}"`);
    res.redirect('/admin/profiles?success=' + encodeURIComponent('Profil supprimé.'));
  } catch (e) {
    res.redirect('/admin/profiles?error=' + encodeURIComponent(e.message));
  }
});

module.exports = router;
