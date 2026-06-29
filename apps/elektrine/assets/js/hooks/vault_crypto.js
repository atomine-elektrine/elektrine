/**
 * Vault crypto — shared zero-knowledge primitives for the Elektrine master
 * password. One passphrase unlocks a random Master Data Key (MDK); per-feature
 * keys (Nerve, Kairo, email) are derived from the MDK via HKDF. The server only
 * ever stores wrapped blobs and ciphertext — never the passphrase, recovery
 * code, or MDK.
 *
 * Two payload shapes:
 *  - "wrapped" (server: account_master_keys): a secret-wrapped value carrying
 *    its own KDF params — {version, algorithm, kdf, iterations, salt, iv, ciphertext}.
 *  - "value"   (feature data, keyed by an HKDF subkey): {version, algorithm, iv, ciphertext}.
 */

export const VERSION = 2
export const ALGORITHM = "AES-GCM"
export const KDF = "PBKDF2-SHA256"
export const PBKDF2_ITERATIONS = 600000
export const MIN_PASSPHRASE_LENGTH = 14

const HKDF_PREFIX = "elektrine-vault:"

const encoder = new TextEncoder()
const decoder = new TextDecoder()

export function randomBytes(length) {
  const bytes = new Uint8Array(length)
  crypto.getRandomValues(bytes)
  return bytes
}

export function bytesToBase64(bytes) {
  let binary = ""
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte)
  })
  return btoa(binary)
}

export function base64ToBytes(value) {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes
}

function stableJson(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return JSON.stringify(value)
  return JSON.stringify(
    Object.keys(value)
      .sort()
      .reduce((acc, key) => {
        acc[key] = value[key]
        return acc
      }, {})
  )
}

function aesGcmParams(iv, associatedData) {
  if (!associatedData) return { name: ALGORITHM, iv }
  return { name: ALGORITHM, iv, additionalData: encoder.encode(stableJson(associatedData)) }
}

// --- Secret (passphrase / recovery code) wrapping ------------------------------

async function deriveWrappingKey(secret, salt, iterations) {
  const baseKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "PBKDF2" },
    false,
    ["deriveKey"]
  )

  return crypto.subtle.deriveKey(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
    baseKey,
    { name: ALGORITHM, length: 256 },
    false,
    ["encrypt", "decrypt"]
  )
}

/** Wrap raw bytes (e.g. the MDK) under a key derived from a secret string. */
export async function wrapWithSecret(plaintextBytes, secret) {
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await deriveWrappingKey(secret, salt, PBKDF2_ITERATIONS)
  const ciphertext = await crypto.subtle.encrypt({ name: ALGORITHM, iv }, key, plaintextBytes)

  return {
    version: VERSION,
    algorithm: ALGORITHM,
    kdf: KDF,
    iterations: PBKDF2_ITERATIONS,
    salt: bytesToBase64(salt),
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext))
  }
}

/** Unwrap a secret-wrapped payload back to raw bytes. Throws on wrong secret. */
export async function unwrapWithSecret(payload, secret) {
  const salt = base64ToBytes(payload.salt)
  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const key = await deriveWrappingKey(secret, salt, Number(payload.iterations))
  const plaintext = await crypto.subtle.decrypt({ name: ALGORITHM, iv }, key, ciphertext)
  return new Uint8Array(plaintext)
}

// --- Master Data Key + per-feature subkeys ------------------------------------

export function generateMdk() {
  return randomBytes(32)
}

async function importHkdfBase(mdkBytes) {
  return crypto.subtle.importKey("raw", mdkBytes, { name: "HKDF" }, false, ["deriveKey"])
}

/** Derive a feature's AES-256-GCM key from the MDK. */
export async function deriveFeatureKey(mdkBytes, feature) {
  const base = await importHkdfBase(mdkBytes)
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(HKDF_PREFIX + feature) },
    base,
    { name: ALGORITHM, length: 256 },
    false,
    ["encrypt", "decrypt"]
  )
}

/** Derive a feature's HMAC-SHA256 key from the MDK (e.g. for blind dedup hashes). */
export async function deriveFeatureHmacKey(mdkBytes, feature) {
  const base = await importHkdfBase(mdkBytes)
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(HKDF_PREFIX + feature + ":hmac") },
    base,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign"]
  )
}

// --- Feature value encryption (keyed by a subkey, with optional AAD) ----------

export async function encryptValue(plaintext, key, associatedData = null) {
  const iv = randomBytes(12)
  const ciphertext = await crypto.subtle.encrypt(
    aesGcmParams(iv, associatedData),
    key,
    encoder.encode(plaintext)
  )

  return {
    version: VERSION,
    algorithm: ALGORITHM,
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext))
  }
}

export async function decryptValue(payload, key, associatedData = null) {
  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const plaintext = await crypto.subtle.decrypt(aesGcmParams(iv, associatedData), key, ciphertext)
  return decoder.decode(plaintext)
}

/** Hex HMAC-SHA256 of a message under an HMAC key (for blind content hashes). */
export async function hmacHex(message, hmacKey) {
  const signature = await crypto.subtle.sign("HMAC", hmacKey, encoder.encode(message))
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

// --- Recovery code ------------------------------------------------------------

const RECOVERY_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

/** 256-bit one-time recovery code, grouped for readability (e.g. ABCD-EFGH-...). */
export function generateRecoveryCode() {
  const bytes = randomBytes(32)
  let out = ""
  bytes.forEach((byte) => {
    out += RECOVERY_ALPHABET[byte & 31]
    out += RECOVERY_ALPHABET[(byte >> 3) & 31]
  })
  return out.match(/.{1,4}/g).join("-")
}

/** Normalize a recovery code the user typed back to its canonical form. */
export function normalizeRecoveryCode(value) {
  return (value || "").toUpperCase().replace(/[^A-Z0-9]/g, "")
}
