const ITERATIONS = 210000
const VERSION = 1
const ALGORITHM = "AES-GCM"
const KDF = "PBKDF2-SHA256"
const PASSWORD_LENGTH = 24
export const VERIFIER_TEXT = "elektrine-vault-verifier-v1"

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

async function deriveAesKey(passphrase, salt, iterations) {
  const passphraseKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(passphrase),
    { name: "PBKDF2" },
    false,
    ["deriveKey"]
  )

  return crypto.subtle.deriveKey(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
    passphraseKey,
    { name: ALGORITHM, length: 256 },
    false,
    ["encrypt", "decrypt"]
  )
}

export function isClientPayload(payload) {
  return (
    payload &&
    payload.algorithm === ALGORITHM &&
    payload.kdf === KDF &&
    typeof payload.iterations === "number" &&
    typeof payload.salt === "string" &&
    typeof payload.iv === "string" &&
    typeof payload.ciphertext === "string"
  )
}

export async function encryptValue(plaintext, passphrase) {
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await deriveAesKey(passphrase, salt, ITERATIONS)
  const ciphertextBuffer = await crypto.subtle.encrypt(
    { name: ALGORITHM, iv },
    key,
    encoder.encode(plaintext)
  )

  return {
    version: VERSION,
    algorithm: ALGORITHM,
    kdf: KDF,
    iterations: ITERATIONS,
    salt: bytesToBase64(salt),
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertextBuffer))
  }
}

export async function decryptValue(payload, passphrase) {
  if (!isClientPayload(payload)) {
    throw new Error("Vault payload is not valid client-side ciphertext.")
  }

  const iv = base64ToBytes(payload.iv)
  const salt = base64ToBytes(payload.salt)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const key = await deriveAesKey(passphrase, salt, payload.iterations)
  const plaintextBuffer = await crypto.subtle.decrypt(
    { name: ALGORITHM, iv },
    key,
    ciphertext
  )

  return decoder.decode(plaintextBuffer)
}

export async function verifyPassphrase(verifierPayload, passphrase) {
  const plaintext = await decryptValue(verifierPayload, passphrase)
  return plaintext === VERIFIER_TEXT
}

export function createPassword() {
  const lowercase = "abcdefghijklmnopqrstuvwxyz"
  const uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  const digits = "0123456789"
  const symbols = "!@#$%^&*()-_=+"
  const all = lowercase + uppercase + digits + symbols
  const cryptoValues = new Uint32Array(PASSWORD_LENGTH * 2)
  crypto.getRandomValues(cryptoValues)
  let randomIndex = 0

  const pick = (characters) => {
    const value = cryptoValues[randomIndex]
    randomIndex += 1
    return characters[value % characters.length]
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
    const swapIndex = cryptoValues[randomIndex] % (i + 1)
    randomIndex += 1
    ;[chars[i], chars[swapIndex]] = [chars[swapIndex], chars[i]]
  }

  return chars.join("")
}
