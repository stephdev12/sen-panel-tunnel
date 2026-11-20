// Crockford Base32 implementation with check symbol for Device ID
// Alphabet excludes I, L, O, U to avoid visual ambiguity.
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const CHECK_SYMBOLS = '*~$=U'; // Symbols for check values 32-36

function encodeCrockford(buffer, length = 12) {
  let bits = '';
  for (const byte of buffer) {
    bits += byte.toString(2).padStart(8, '0');
  }

  let out = '';
  for (let i = 0; i + 5 <= bits.length && out.length < length; i += 5) {
    const chunk = bits.substring(i, i + 5);
    const val = parseInt(chunk, 2);
    out += ALPHABET[val];
  }

  while (out.length < length) {
    out += '0';
  }

  return out;
}

function calculateCheckSymbol(base12) {
  let sum = 0;
  for (let i = 0; i < base12.length; i++) {
    const char = base12[i].toUpperCase();
    const idx = ALPHABET.indexOf(char);
    if (idx === -1) throw new Error(`Invalid Crockford character: ${char}`);
    sum = (sum * 32 + idx) % 37;
  }
  if (sum < 32) return ALPHABET[sum];
  return CHECK_SYMBOLS[sum - 32];
}

function normalizeDeviceId(input) {
  if (!input) return '';
  return input.toUpperCase().replace(/[^0-9A-Z*~$=]/g, '');
}

function formatDeviceId(raw13) {
  const clean = normalizeDeviceId(raw13);
  if (clean.length !== 13) return clean;
  return `${clean.slice(0, 4)}-${clean.slice(4, 8)}-${clean.slice(8, 12)}-${clean.slice(12, 13)}`;
}

function validateDeviceId(input) {
  const clean = normalizeDeviceId(input);
  if (clean.length !== 13) return false;
  const base12 = clean.slice(0, 12);
  const checkChar = clean.slice(12, 13);
  try {
    const expected = calculateCheckSymbol(base12);
    return expected === checkChar;
  } catch {
    return false;
  }
}

function generateDeviceIdFromPublicKey(publicKeyPemOrDer) {
  const crypto = require('crypto');
  const hash = crypto.createHash('sha256').update(publicKeyPemOrDer).digest();
  const base12 = encodeCrockford(hash, 12);
  const check = calculateCheckSymbol(base12);
  return formatDeviceId(base12 + check);
}

module.exports = {
  ALPHABET,
  encodeCrockford,
  calculateCheckSymbol,
  normalizeDeviceId,
  formatDeviceId,
  validateDeviceId,
  generateDeviceIdFromPublicKey
};
