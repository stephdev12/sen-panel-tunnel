const crypto = require('crypto');
const { ALPHABET } = require('./crockford');
const config = require('../config');

// Default server code from config or env (e.g. SEN)
const SERVER_CODE = process.env.SERVER_CODE || 'SEN';
const KEY_SECRET = process.env.ACTIVATION_KEY_SECRET || config.SESSION_SECRET || 'sen-panel-secret-key-salt';

/**
 * Generate 25 characters of Crockford base32 (125 bits of random entropy).
 */
function generateRandomBase32(length = 25) {
  const bytes = crypto.randomBytes(length);
  let result = '';
  for (let i = 0; i < length; i++) {
    result += ALPHABET[bytes[i] % ALPHABET.length];
  }
  return result;
}

/**
 * Creates a formatted activation key:
 * NVX1-<CODE>-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
 */
function createActivationKey(serverCode = SERVER_CODE) {
  const raw25 = generateRandomBase32(25);
  const groups = [
    raw25.slice(0, 5),
    raw25.slice(5, 10),
    raw25.slice(10, 15),
    raw25.slice(15, 20),
    raw25.slice(20, 25)
  ];
  const key = `NVX1-${serverCode.toUpperCase()}-${groups.join('-')}`;
  const keyHash = hashActivationKey(key);
  const keyLast4 = raw25.slice(-4);

  return {
    key,
    keyHash,
    keyLast4,
    serverCode: serverCode.toUpperCase()
  };
}

/**
 * Normalizes an activation key string (removes spaces, uppercase).
 */
function normalizeKey(keyString) {
  if (!keyString) return '';
  return keyString.trim().toUpperCase();
}

/**
 * Hashes an activation key with server secret for secure storage.
 */
function hashActivationKey(keyString) {
  const normalized = normalizeKey(keyString);
  return crypto.createHmac('sha256', KEY_SECRET).update(normalized).digest('hex');
}

/**
 * Parses key components.
 */
function parseKey(keyString) {
  const norm = normalizeKey(keyString);
  const parts = norm.split('-');
  if (parts.length < 3) return null;
  const prefix = parts[0]; // e.g. NVX1
  const serverCode = parts[1]; // e.g. SEN
  const rest = parts.slice(2).join('');
  if (rest.length !== 25) return null;
  return { prefix, serverCode, rawPayload: rest };
}

module.exports = {
  createActivationKey,
  hashActivationKey,
  normalizeKey,
  parseKey,
  SERVER_CODE
};
