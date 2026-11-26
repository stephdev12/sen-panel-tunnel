const express = require('express');
const db = require('../db/database');
const { requireAdmin } = require('../middleware/auth');
const audit = require('../lib/audit');

const router = express.Router();
router.use(requireAdmin);

// List profiles
router.get('/', (req, res) => {
  const profiles = db.prepare(`
    SELECT p.*,
      (SELECT COUNT(*) FROM app_accounts WHERE profile_id = p.id) as user_count
    FROM connection_profiles p
    ORDER BY p.id DESC
  `).all();
  const totalUsers = db.prepare('SELECT COUNT(*) AS c FROM app_accounts').get().c;
  const currentWsPath = process.env.WS_PATH || '/sen';

  res.render('admin/profiles', {
    profiles: profiles.map((p) => {
      let params = {};
      try { params = JSON.parse(p.params); } catch {}
      return { ...p, parsedParams: params };
    }),
    totalUsers,
    currentWsPath,
    error: req.query.error,
    success: req.query.success
  });
});

// Quick batch update for WebSocket host, path, port & payload
router.post('/quick-update-payload', (req, res) => {
  try {
    const { host, wspath, sni, port, apply_to_all } = req.body;
    if (!host && !wspath) throw new Error('Spécifiez au moins un hôte ou un chemin WebSocket.');

    const cleanWsPath = wspath ? (wspath.startsWith('/') ? wspath : '/' + wspath) : null;
    if (cleanWsPath) {
      try {
        const fs = require('fs');
        const path = require('path');
        const envPath = path.join(__dirname, '..', '.env');
        if (fs.existsSync(envPath)) {
          let envContent = fs.readFileSync(envPath, 'utf8');
          if (envContent.match(/^WS_PATH=/m)) {
            envContent = envContent.replace(/^WS_PATH=.*$/m, `WS_PATH=${cleanWsPath}`);
          } else {
            envContent += `\nWS_PATH=${cleanWsPath}\n`;
          }
          fs.writeFileSync(envPath, envContent, 'utf8');
        }
        process.env.WS_PATH = cleanWsPath;
        fs.mkdirSync('/etc/novaxtunnel', { recursive: true });
        fs.writeFileSync('/etc/novaxtunnel/wspath', cleanWsPath + '\n', 'utf8');
      } catch {}
    }

    const profiles = db.prepare("SELECT * FROM connection_profiles WHERE type = 'ssh'").all();
    let updatedCount = 0;
    const now = new Date().toISOString();

    for (const p of profiles) {
      let params = {};
      try { params = JSON.parse(p.params); } catch {}
      if (host) params.host = host.trim();
      if (port) params.port = parseInt(port, 10) || params.port;
      if (sni !== undefined && sni !== '') params.sni = sni.trim();

      const currentPath = cleanWsPath || process.env.WS_PATH || '/sen';
      params.payload = `GET ${currentPath} HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]`;

      const nextVersion = (p.version || 1) + 1;
      db.prepare(`
        UPDATE connection_profiles
        SET params = ?, version = ?, updated_at = ?
        WHERE id = ?
      `).run(JSON.stringify(params), nextVersion, now, p.id);
      updatedCount++;
    }

    const totalUsers = db.prepare('SELECT COUNT(*) AS c FROM app_accounts').get().c;
    audit.log('admin', req.session.username, 'profile_quick_update', `Mise à jour rapide des tunnels SSH (${updatedCount} profil(s) synchronisés avec ${totalUsers} utilisateurs)`);

    res.redirect('/admin/profiles?success=' + encodeURIComponent(`Mise à jour globale réussie ! ${updatedCount} profil(s) mis à jour. Les ${totalUsers} utilisateur(s) Surfeo recevront la nouvelle configuration automatiquement.`));
  } catch (e) {
    res.redirect('/admin/profiles?error=' + encodeURIComponent(e.message));
  }
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

    const {
      name, is_active, host, port, tls, sni, payload, wspath,
      proxy_enabled, proxy_host, proxy_port, udpgwPort, dns,
      udp_server, udp_port, window, resolver, boostSlowdns, dnsForward, mode,
      apply_to_all
    } = req.body;

    let paramsObj = {};
    if (existing.type === 'ssh') {
      let finalPayload = payload || '';
      if (!finalPayload && wspath) {
        const cleanPath = wspath.startsWith('/') ? wspath : '/' + wspath;
        finalPayload = `GET ${cleanPath} HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]`;
      }
      paramsObj = {
        host: host || '',
        port: parseInt(port, 10) || 80,
        tls: tls === 'on' || tls === 'true',
        sni: sni || null,
        payload: finalPayload,
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

    const nextVersion = (existing.version || 1) + 1;
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

    let extraMsg = '';
    if (apply_to_all === 'on' || apply_to_all === 'true' || apply_to_all === '1') {
      const updateResult = db.prepare('UPDATE app_accounts SET profile_id = ?').run(id);
      extraMsg = ` et propagé à tous les ${updateResult.changes} compte(s) Surfeo`;
      audit.log('admin', req.session.username, 'profile_broadcast', `Profil "${name || existing.name}" propagé à ${updateResult.changes} comptes Surfeo`);
    }

    audit.log('admin', req.session.username, 'profile_edit', `Mise à jour du profil "${existing.name}" (version v${nextVersion})${extraMsg}`);
    res.redirect('/admin/profiles?success=' + encodeURIComponent(`Tunnel "${name || existing.name}" mis à jour avec succès (v${nextVersion})${extraMsg} !`));
  } catch (e) {
    res.redirect('/admin/profiles?error=' + encodeURIComponent(e.message));
  }
});

// Broadcast profile to all Surfeo user accounts in 1 click
router.post('/:id/broadcast', (req, res) => {
  const id = req.params.id;
  try {
    const existing = db.prepare('SELECT * FROM connection_profiles WHERE id = ?').get(id);
    if (!existing) throw new Error('Profil introuvable.');

    const nextVersion = (existing.version || 1) + 1;
    const now = new Date().toISOString();

    db.prepare(`
      UPDATE connection_profiles
      SET version = ?, updated_at = ?
      WHERE id = ?
    `).run(nextVersion, now, id);

    const accountsResult = db.prepare(`
      UPDATE app_accounts
      SET profile_id = ?
    `).run(id);

    audit.log('admin', req.session.username, 'profile_broadcast', `Diffusion du tunnel "${existing.name}" à tous les comptes (${accountsResult.changes} utilisateurs synchronisés sur la version v${nextVersion})`);

    res.redirect('/admin/profiles?success=' + encodeURIComponent(`Tunnel "${existing.name}" diffusé à tous les utilisateurs ! ${accountsResult.changes} compte(s) Surfeo synchronisé(s) sur la version v${nextVersion}.`));
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
