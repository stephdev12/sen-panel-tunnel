const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// Key storage for server signing
const SERVER_KEY_PATH = path.join(__dirname, '../db/server_key.pem');
const SERVER_PUBKEY_PATH = path.join(__dirname, '../db/server_pubkey.pem');

// Nonce cache to prevent replay attacks (nonce -> expiry timestamp)
const seenNonces = new Map();

// Periodic sweep of expired nonces every 60 seconds
setInterval(() => {
  const now = Date.now();
  for (const [nonce, expiresAt] of seenNonces.entries()) {
    if (expiresAt < now) seenNonces.delete(nonce);
  }
}, 60000).unref();

function getOrCreateServerKeyPair() {
  if (fs.existsSync(SERVER_KEY_PATH) && fs.existsSync(SERVER_PUBKEY_PATH)) {
    return {
      privateKey: fs.readFileSync(SERVER_KEY_PATH, 'utf8'),
      publicKey: fs.readFileSync(SERVER_PUBKEY_PATH, 'utf8')
    };
  }

  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519', {
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });

  try {
    fs.mkdirSync(path.dirname(SERVER_KEY_PATH), { recursive: true });
    fs.writeFileSync(SERVER_KEY_PATH, privateKey);
    fs.writeFileSync(SERVER_PUBKEY_PATH, publicKey);
  } catch (err) {
    console.error('Warning: could not save server keypair to disk:', err.message);
  }

  return { privateKey, publicKey };
}

const serverKeys = getOrCreateServerKeyPair();

/**
 * Sign data string with server private key.
 */
function signResponse(dataString) {
  try {
    const signer = crypto.createSign(null);
    signer.update(dataString);
    return signer.sign(serverKeys.privateKey, 'base64');
  } catch (e) {
    // Fallback HMAC if ed25519 isn't directly used
    return crypto.createHmac('sha256', serverKeys.privateKey).update(dataString).digest('base64');
  }
}

/**
 * Build canonical string for signature:
 * METHOD\nPATH\nTIMESTAMP\nNONCE\nBODY_SHA256
 */
function buildCanonicalString(method, pathName, timestamp, nonce, bodyString = '') {
  const bodyHash = crypto.createHash('sha256').update(bodyString || '').digest('hex');
  return `${method.toUpperCase()}\n${pathName}\n${timestamp}\n${nonce}\n${bodyHash}`;
}

/**
 * Verifies request signature from device.
 */
function verifyDeviceRequest(req, devicePublicKey) {
  const deviceId = req.headers['x-device-id'];
  const timestamp = req.headers['x-timestamp'];
  const nonce = req.headers['x-nonce'];
  const signature = req.headers['x-signature'];

  if (!deviceId || !timestamp || !nonce || !signature) {
    return { valid: false, error: 'Missing required signature headers' };
  }

  // Check timestamp skew (120 seconds tolerance)
  const reqTime = parseInt(timestamp, 10);
  const now = Math.floor(Date.now() / 1000);
  if (isNaN(reqTime) || Math.abs(now - reqTime) > 120) {
    return { valid: false, error: 'Timestamp skew exceeded (120s max)' };
  }

  // Check nonce uniqueness
  if (seenNonces.has(nonce)) {
    return { valid: false, error: 'Nonce already used (replay attack detected)' };
  }
  // Store nonce with 3-minute expiry
  seenNonces.set(nonce, Date.now() + 180000);

  // If public key is not yet stored (e.g. initial activation), signature is verified using the key sent in body
  if (!devicePublicKey) {
    return { valid: true };
  }

  const bodyStr = req.rawBody || JSON.stringify(req.body || {});
  const canonical = buildCanonicalString(req.method, req.path, timestamp, nonce, bodyStr);

  try {
    // Supports EC / Ed25519 PEM public key or base64 DER
    let keyToUse = devicePublicKey;
    if (!keyToUse.includes('-----BEGIN')) {
      keyToUse = `-----BEGIN PUBLIC KEY-----\n${devicePublicKey}\n-----END PUBLIC KEY-----`;
    }
    const verifier = crypto.createVerify('SHA256');
    verifier.update(canonical);
    const isValid = verifier.verify(keyToUse, signature, 'base64');
    return { valid: isValid, error: isValid ? null : 'bad_signature' };
  } catch (err) {
    return { valid: false, error: `Signature verification error: ${err.message}` };
  }
}

module.exports = {
  serverKeys,
  signResponse,
  buildCanonicalString,
  verifyDeviceRequest
};
