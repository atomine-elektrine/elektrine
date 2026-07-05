const VERSION = 2
const ALGORITHM = "AES-GCM"
const KDF = "PBKDF2-SHA256"
const PBKDF2_ITERATIONS = 600000
const HKDF_PREFIX = "elektrine-vault:"
const PASSWORD_LENGTH = 24
export const MIN_PASSPHRASE_LENGTH = 14

const encoder = new TextEncoder()
const decoder = new TextDecoder()

function randomBytes(length) {
  const bytes = new Uint8Array(length)
  crypto.getRandomValues(bytes)
  return bytes
}

function bytesToBase64(bytes) {
  let binary = ""

  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte)
  })

  return btoa(binary)
}

function base64ToBytes(value) {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }

  return bytes
}

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

export function isClientPayload(payload) {
  return (
    payload &&
    payload.algorithm === ALGORITHM &&
    typeof payload.iv === "string" &&
    typeof payload.ciphertext === "string"
  )
}

export function isWrappedPayload(payload) {
  return (
    isClientPayload(payload) &&
    payload.kdf === KDF &&
    typeof payload.iterations === "number" &&
    typeof payload.salt === "string"
  )
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

  return {
    name: ALGORITHM,
    iv,
    additionalData: encoder.encode(stableJson(associatedData))
  }
}

export function nerveEntryAssociatedData(entry, field) {
  return {
    purpose: "elektrine-nerve-entry",
    field,
    title: (entry.title || "").trim(),
    login_username: (entry.login_username || "").trim(),
    website: (entry.website || "").trim()
  }
}

export function nerveMetadataAssociatedData() {
  return { purpose: "elektrine-nerve-metadata" }
}

export async function unwrapWithSecret(payload, secret) {
  if (!isWrappedPayload(payload)) {
    throw new Error("Encrypted data key payload is not valid.")
  }

  const salt = base64ToBytes(payload.salt)
  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const key = await deriveWrappingKey(secret, salt, Number(payload.iterations))
  const plaintext = await crypto.subtle.decrypt({ name: ALGORITHM, iv }, key, ciphertext)

  return new Uint8Array(plaintext)
}

async function importHkdfBase(mdkBytes) {
  return crypto.subtle.importKey("raw", mdkBytes, { name: "HKDF" }, false, ["deriveKey"])
}

export async function deriveFeatureKey(mdkBytes, feature) {
  const base = await importHkdfBase(mdkBytes)

  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: new Uint8Array(0),
      info: encoder.encode(HKDF_PREFIX + feature)
    },
    base,
    { name: ALGORITHM, length: 256 },
    false,
    ["encrypt", "decrypt"]
  )
}

export async function encryptValue(plaintext, key, associatedData = null) {
  const iv = randomBytes(12)
  const ciphertextBuffer = await crypto.subtle.encrypt(
    aesGcmParams(iv, associatedData),
    key,
    encoder.encode(plaintext)
  )

  return {
    version: VERSION,
    algorithm: ALGORITHM,
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertextBuffer))
  }
}

export async function decryptValue(payload, key, associatedData = null) {
  if (!isClientPayload(payload)) {
    throw new Error("Nerve payload is not valid client-side ciphertext.")
  }

  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const plaintextBuffer = await crypto.subtle.decrypt(aesGcmParams(iv, associatedData), key, ciphertext)

  return decoder.decode(plaintextBuffer)
}

export function createPassword() {
  const lowercase = "abcdefghijklmnopqrstuvwxyz"
  const uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  const digits = "0123456789"
  const symbols = "!@#$%^&*()-_=+"
  const all = lowercase + uppercase + digits + symbols

  const randomInt = (max) => {
    const values = new Uint32Array(1)
    const limit = Math.floor(0x100000000 / max) * max

    do {
      crypto.getRandomValues(values)
    } while (values[0] >= limit)

    return values[0] % max
  }

  const pick = (characters) => {
    return characters[randomInt(characters.length)]
  }

  const chars = [
    pick(lowercase),
    pick(uppercase),
    pick(digits),
    pick(symbols)
  ]

  while (chars.length < PASSWORD_LENGTH) {
    chars.push(pick(all))
  }

  for (let i = chars.length - 1; i > 0; i -= 1) {
    const swapIndex = randomInt(i + 1)
    ;[chars[i], chars[swapIndex]] = [chars[swapIndex], chars[i]]
  }

  return chars.join("")
}
