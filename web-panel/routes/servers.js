const express = require('express');
const fs = require('fs');
const path = require('path');
const db = require('../db/database');
const { requireAdmin } = require('../middleware/auth');
const audit = require('../lib/audit');

const router = express.Router();
router.use(requireAdmin);

const SERVERS_JSON_PATH = path.join(__dirname, '../../servers.json');

/**
 * Helper to sync the servers table to servers.json
 */
function syncServersJson() {
  try {
    const allServers = db.prepare('SELECT * FROM servers WHERE is_active = 1 ORDER BY is_master DESC, id ASC').all();
    const serverMap = {};
    for (const s of allServers) {
      serverMap[s.code.toUpperCase()] = {
        name: s.name,
        api: [s.api_url],
        isMaster: Boolean(s.is_master)
      };
    }
    const payload = {
      version: 1,
      servers: serverMap
    };
    fs.writeFileSync(SERVERS_JSON_PATH, JSON.stringify(payload, null, 2), 'utf8');
  } catch (err) {
    console.warn('[Servers] Could not sync servers.json:', err.message);
  }
}

// List all servers
router.get('/', (req, res) => {
  const servers = db.prepare('SELECT * FROM servers ORDER BY is_master DESC, id ASC').all();
  res.render('admin/servers', {
    servers,
    error: req.query.error,
    success: req.query.success
  });
});

// Add a new server
router.post('/create', (req, res) => {
  try {
    const { code, name, api_url } = req.body;
    if (!code || !name || !api_url) {
      throw new Error('Code serveur, nom et URL de l\'API sont obligatoires.');
    }

    const cleanCode = code.trim().toUpperCase().replace(/[^A-Z0-9_-]/g, '');
    if (cleanCode.length < 2) {
      throw new Error('Le code serveur doit comporter au moins 2 caractères alphanumériques.');
    }

    let cleanUrl = api_url.trim();
    if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      cleanUrl = 'https://' + cleanUrl;
    }
    // Remove trailing slash
    cleanUrl = cleanUrl.replace(/\/+$/, '');

    // Check code uniqueness
    const existing = db.prepare('SELECT * FROM servers WHERE code = ?').get(cleanCode);
    if (existing) {
      throw new Error(`Un serveur avec le code "${cleanCode}" existe déjà.`);
    }

    db.prepare(`
      INSERT INTO servers (code, name, api_url, is_master, is_active)
      VALUES (?, ?, ?, 0, 1)
    `).run(cleanCode, name.trim(), cleanUrl);

    syncServersJson();
    audit.log('admin', req.session.username, 'server_create', `Ajout du serveur ${cleanCode} (${name.trim()} - ${cleanUrl})`);

    res.redirect('/admin/servers?success=' + encodeURIComponent(`Serveur "${name}" (${cleanCode}) ajouté avec succès.`));
  } catch (err) {
    res.redirect('/admin/servers?error=' + encodeURIComponent(err.message));
  }
});

// Toggle server active state
router.post('/:id/toggle', (req, res) => {
  try {
    const id = req.params.id;
    const srv = db.prepare('SELECT * FROM servers WHERE id = ?').get(id);
    if (!srv) throw new Error('Serveur introuvable.');

    const newActive = srv.is_active === 1 ? 0 : 1;
    db.prepare('UPDATE servers SET is_active = ? WHERE id = ?').run(newActive, id);

    syncServersJson();
    audit.log('admin', req.session.username, 'server_toggle', `Basculement statut serveur ${srv.code} vers ${newActive ? 'actif' : 'inactif'}`);

    res.redirect('/admin/servers?success=' + encodeURIComponent(`Statut du serveur ${srv.code} mis à jour.`));
  } catch (err) {
    res.redirect('/admin/servers?error=' + encodeURIComponent(err.message));
  }
});

// Delete server (forbidden for master)
router.post('/:id/delete', (req, res) => {
  try {
    const id = req.params.id;
    const srv = db.prepare('SELECT * FROM servers WHERE id = ?').get(id);
    if (!srv) throw new Error('Serveur introuvable.');

    if (srv.is_master === 1) {
      throw new Error('Impossible de supprimer le serveur maître.');
    }

    db.prepare('DELETE FROM servers WHERE id = ?').run(id);

    syncServersJson();
    audit.log('admin', req.session.username, 'server_delete', `Suppression du serveur ${srv.code} (${srv.name})`);

    res.redirect('/admin/servers?success=' + encodeURIComponent(`Serveur ${srv.code} supprimé avec succès.`));
  } catch (err) {
    res.redirect('/admin/servers?error=' + encodeURIComponent(err.message));
  }
});

module.exports = router;
