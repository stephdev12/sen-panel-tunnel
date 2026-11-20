const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');
const config = require('../config');

const db = new Database(config.PANEL_DB_FILE);
db.pragma('journal_mode = WAL');

db.exec(`
CREATE TABLE IF NOT EXISTS admins (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS resellers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  data_quota_gb REAL,               -- NULL = unlimited
  max_users INTEGER NOT NULL DEFAULT 10,
  protocols TEXT NOT NULL DEFAULT '[]', -- JSON array of allowed protocol keys
  expiry_date TEXT,                 -- NULL = never expires
  status TEXT NOT NULL DEFAULT 'active', -- active | locked_manual | locked_expired
  consumed_quota_gb REAL NOT NULL DEFAULT 0, -- permanently-counted quota from deleted clients
  created_at TEXT DEFAULT (datetime('now')),
  notes TEXT
);

CREATE TABLE IF NOT EXISTS clients (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  reseller_id INTEGER NOT NULL REFERENCES resellers(id) ON DELETE CASCADE,
  type TEXT NOT NULL,               -- 'ssh' | 'zivpn'
  identifier TEXT NOT NULL,         -- username for ssh, password for zivpn
  protocols TEXT NOT NULL DEFAULT '[]', -- JSON array subset of reseller.protocols (which tunnel types this client may use)
  max_connections INTEGER DEFAULT 1,
  quota_gb REAL,                    -- NULL = unlimited
  expiry_date TEXT,                 -- NULL = never
  status TEXT NOT NULL DEFAULT 'active', -- active | locked_manual | locked_expired | locked_reseller
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_clients_reseller ON clients(reseller_id);
`);

// Migration: older databases were created before this column existed. SQLite has no
// "ADD COLUMN IF NOT EXISTS", so we just try and ignore the error when it's already there.
try {
  db.exec('ALTER TABLE clients ADD COLUMN usage_at_deletion_gb REAL');
} catch (e) {
  if (!/duplicate column/i.test(e.message)) throw e;
}

// quota_reset_offset_gb lets an admin "reset the reseller's displayed consumed total to 0"
// as a pure display action (like zeroing an odometer trip counter) WITHOUT touching any
// client's own live usage or the historical consumed_quota_gb banked from deleted/reset
// clients. See lib/quota.js getResellerStats() for how it's subtracted back out.
try {
  db.exec('ALTER TABLE resellers ADD COLUMN quota_reset_offset_gb REAL DEFAULT 0');
} catch (e) {
  if (!/duplicate column/i.test(e.message)) throw e;
}

db.exec(`

CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor_type TEXT NOT NULL,     -- 'admin' | 'reseller' | 'system'
  actor_name TEXT NOT NULL,
  action TEXT NOT NULL,         -- short machine-friendly code
  message TEXT NOT NULL,        -- human-readable description
  reseller_id INTEGER,          -- for scoping "my activity" views, NULL for admin-only actions
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_audit_reseller ON audit_log(reseller_id);

-- PRD Extension: Connection Profiles
CREATE TABLE IF NOT EXISTS connection_profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  type TEXT NOT NULL,               -- 'ssh' | 'udp'
  is_active INTEGER NOT NULL DEFAULT 1,
  params TEXT NOT NULL DEFAULT '{}', -- JSON object with profile details
  version INTEGER NOT NULL DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- PRD Extension: App-linked Accounts
CREATE TABLE IF NOT EXISTS app_accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL,
  type TEXT NOT NULL,               -- 'ssh' | 'udp'
  profile_id INTEGER NOT NULL REFERENCES connection_profiles(id),
  device_id TEXT NOT NULL,          -- Crockford Base32 13-char ID (XXXX-XXXX-XXXX-X)
  public_key TEXT,                  -- Base64 device public key, stored upon activation
  state TEXT NOT NULL DEFAULT 'pending', -- pending | active | expired | quota_exhausted | locked_temporarily | revoked | deleted
  created_at TEXT DEFAULT (datetime('now')),
  activated_at TEXT,
  last_active_at TEXT,
  app_version TEXT,
  quota_gb REAL DEFAULT 0,
  expiry_date TEXT,
  password TEXT
);

CREATE INDEX IF NOT EXISTS idx_app_accounts_dev ON app_accounts(device_id);
CREATE INDEX IF NOT EXISTS idx_app_accounts_user ON app_accounts(username);

`);

// Seamless migrations for existing tables
try { db.exec('ALTER TABLE app_accounts ADD COLUMN quota_gb REAL DEFAULT 0'); } catch {}
try { db.exec('ALTER TABLE app_accounts ADD COLUMN expiry_date TEXT'); } catch {}
try { db.exec('ALTER TABLE app_accounts ADD COLUMN password TEXT'); } catch {}
try { db.exec('ALTER TABLE resellers ADD COLUMN max_surfeo_users INTEGER DEFAULT 5'); } catch {}
try { db.exec('ALTER TABLE resellers ADD COLUMN surfeo_quota_gb REAL'); } catch {}
try { db.exec('ALTER TABLE app_accounts ADD COLUMN reseller_id INTEGER REFERENCES resellers(id) ON DELETE CASCADE'); } catch {}

db.exec(`

-- PRD Extension: Activation Keys
CREATE TABLE IF NOT EXISTS activation_keys (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  app_account_id INTEGER NOT NULL REFERENCES app_accounts(id) ON DELETE CASCADE,
  key_hash TEXT UNIQUE NOT NULL,    -- SHA-256 hash of activation key
  key_last4 TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'unused', -- unused | used | revoked
  failed_attempts INTEGER NOT NULL DEFAULT 0,
  locked_until TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_act_keys_hash ON activation_keys(key_hash);

-- PRD Extension: Servers Management (Master & Nodes)
CREATE TABLE IF NOT EXISTS servers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  api_url TEXT NOT NULL,
  is_master INTEGER DEFAULT 0,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_servers_code ON servers(code);

`);

// Seed default master server if none exist
const serverCount = db.prepare('SELECT COUNT(*) AS c FROM servers').get().c;
if (serverCount === 0) {
  db.prepare(`
    INSERT INTO servers (code, name, api_url, is_master, is_active)
    VALUES ('SEN', 'Serveur Principal SEN', 'https://panel.senstudio.space:2045', 1, 1)
  `).run();
}

// Bootstrap a default admin account on first run only.
const adminCount = db.prepare('SELECT COUNT(*) AS c FROM admins').get().c;
if (adminCount === 0) {
  const defaultUser = process.env.DEFAULT_ADMIN_USER || 'admin';
  const defaultPass = process.env.DEFAULT_ADMIN_PASS || 'ChangeMe123!';
  const hash = bcrypt.hashSync(defaultPass, 10);
  db.prepare('INSERT INTO admins (username, password_hash) VALUES (?, ?)').run(defaultUser, hash);
  console.log('======================================================');
  console.log(' SEN PANEL TUNNEL - default admin account created:');
  console.log('   username:', defaultUser);
  console.log('   password:', defaultPass);
  console.log(' CHANGE THIS PASSWORD IMMEDIATELY AFTER FIRST LOGIN.');
  console.log('======================================================');
}

// Seed initial default connection profiles if none exist
const profileCount = db.prepare('SELECT COUNT(*) AS c FROM connection_profiles').get().c;
if (profileCount === 0) {
  const defaultSshParams = {
    host: 'd1url4lvz5mor6.cloudfront.net',
    port: 80,
    tls: false,
    sni: null,
    payload: 'GET /sen HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]',
    proxy: { enabled: false, host: null, port: null },
    udpgwPort: 7300,
    dns: ['1.1.1.1', '8.8.8.8']
  };

  const defaultUdpParams = {
    server: '185.183.52.40',
    port: 7300,
    auth: '',
    window: 2,
    resolver: '127.0.0.1:7300',
    boostSlowdns: false,
    dnsForward: false,
    mode: 'SlowDNS'
  };

  db.prepare(`
    INSERT INTO connection_profiles (name, type, is_active, params, version)
    VALUES (?, ?, 1, ?, 1)
  `).run('CloudFront WebSocket Standard', 'ssh', JSON.stringify(defaultSshParams));

  db.prepare(`
    INSERT INTO connection_profiles (name, type, is_active, params, version)
    VALUES (?, ?, 1, ?, 1)
  `).run('UDP Custom Direct', 'udp', JSON.stringify(defaultUdpParams));
}

module.exports = db;
