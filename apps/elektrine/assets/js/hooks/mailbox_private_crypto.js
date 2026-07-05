/**
 * Crypto, encoding, and key-management helpers for the private mailbox.
 *
 * Extracted from mailbox_private_storage_hooks.js to keep that file within its
 * maintainability budget. This module owns the low-level primitives (base64,
 * scrypt key wrapping, RSA envelope decryption, master-key wrapping) and the
 * in-memory imported-key cache; the hook in mailbox_private_storage_hooks.js
 * drives them. Public names are re-exported from that module so existing
 * importers keep working unchanged.
 */

import { scryptAsync } from "@noble/hashes/scrypt.js"
import * as vaultSession from "./vault_session"

export const MASTER_MODE = "master"
const MASTER_FEATURE = "email"
const WRAP_ALGORITHM = "AES-GCM"
export const VERIFY_TEXT = "elektrine-private-mailbox-v1"
const MESSAGE_AAD = new TextEncoder().encode("ElektrineMailboxStorageV1")
const ATTACHMENT_AAD = new TextEncoder().encode("ElektrineMailboxAttachmentV1")
const DEFAULT_SCRYPT = { n: 16384, r: 8, p: 1 }
export const encoder = new TextEncoder()
const decoder = new TextDecoder()
const importedPrivateKeys = new Map()

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

function encodedStableJson(value) {
  return encoder.encode(stableJson(value))
}

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

function concatBytes(first, second) {
  const combined = new Uint8Array(first.length + second.length)
  combined.set(first, 0)
  combined.set(second, first.length)
  return combined
}

export function parsePayload(raw) {
  if (!raw) return null

  try {
    return JSON.parse(raw)
  } catch (_error) {
    return null
  }
}

function isValidUnlockMode(value) {
  return value === "account_password" || value === "separate_passphrase"
}

export function isKnownUnlockMode(value) {
  return isValidUnlockMode(value) || value === MASTER_MODE
}

export function unlockModeFromPayload(...payloads) {
  for (const payload of payloads) {
    if (!payload || typeof payload !== "object") continue

    const unlockMode = payload.unlock_mode || payload.unlockMode
    if (isKnownUnlockMode(unlockMode)) {
      return unlockMode
    }
  }

  return null
}

export function notify(message, type = "error", title = "Mailbox") {
  if (typeof window.showNotification === "function") {
    window.showNotification(message, type, title)
  } else {
    console.error(`[Mailbox] ${message}`)
  }
}

export function cacheLoginPassword(password) {
  void password
}

export function clearCachedLoginPassword() {
  return null
}

export function getCachedLoginPassword() {
  return null
}

export function getStoredPrivateKey(mailboxId) {
  if (!mailboxId) return null
  return importedPrivateKeys.get(mailboxId) || null
}

function storePrivateKey(mailboxId, privateKey) {
  if (!mailboxId) return
  importedPrivateKeys.set(mailboxId, privateKey)
}

export function clearPrivateKey(mailboxId) {
  if (!mailboxId) return
  importedPrivateKeys.delete(mailboxId)
}

export function dispatchMailboxEvent(name, mailboxId) {
  window.dispatchEvent(
    new CustomEvent(name, {
      detail: { mailboxId }
    })
  )
}

function chunkString(value, size) {
  const parts = []

  for (let index = 0; index < value.length; index += size) {
    parts.push(value.slice(index, index + size))
  }

  return parts.join("\n")
}

function bytesToPem(bytes, label) {
  const body = chunkString(bytesToBase64(bytes), 64)
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----`
}

async function deriveWrappingKey(passphrase, salt, params) {
  const keyBytes = await scryptAsync(encoder.encode(passphrase), salt, {
    N: params.n,
    r: params.r,
    p: params.p,
    dkLen: 32
  })

  return crypto.subtle.importKey("raw", keyBytes, { name: WRAP_ALGORITHM }, false, [
    "encrypt",
    "decrypt"
  ])
}

function keyWrapAADContext(unlockMode, kind) {
  return {
    purpose: "elektrine-private-mailbox-key-wrap",
    version: 2,
    kind,
    algorithm: WRAP_ALGORITHM,
    kdf: "scrypt",
    unlock_mode: unlockMode
  }
}

function wrapParams(payload, iv) {
  if (Number(payload.version) >= 2) {
    return { name: WRAP_ALGORITHM, iv, additionalData: encodedStableJson(payload.aad_context) }
  }

  return { name: WRAP_ALGORITHM, iv }
}

export async function wrapBytes(bytes, passphrase, unlockMode = null, kind = "private_key") {
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await deriveWrappingKey(passphrase, salt, DEFAULT_SCRYPT)
  const aadContext = keyWrapAADContext(unlockMode, kind)
  const ciphertext = await crypto.subtle.encrypt(
    { name: WRAP_ALGORITHM, iv, additionalData: encodedStableJson(aadContext) },
    key,
    bytes
  )

  const payload = {
    version: 2,
    algorithm: WRAP_ALGORITHM,
    kdf: "scrypt",
    aad_context: aadContext,
    n: DEFAULT_SCRYPT.n,
    r: DEFAULT_SCRYPT.r,
    p: DEFAULT_SCRYPT.p,
    salt: bytesToBase64(salt),
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext))
  }

  if (isValidUnlockMode(unlockMode)) {
    payload.unlock_mode = unlockMode
  }

  return payload
}

async function unwrapBytes(payload, passphrase) {
  const salt = base64ToBytes(payload.salt)
  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const key = await deriveWrappingKey(passphrase, salt, payload)
  const plaintext = await crypto.subtle.decrypt(wrapParams(payload, iv), key, ciphertext)
  return new Uint8Array(plaintext)
}

// --- shared account-password vault mode ------------------------------------
// Instead of deriving a wrapping key directly from the account password, shared
// vault mode wraps the mailbox key with the email subkey of the encrypted data
// key held in the shared vault session. One account-password unlock therefore
// unlocks this mailbox too.

async function masterEmailKey() {
  return vaultSession.featureKey(MASTER_FEATURE)
}

function masterAADContext(kind) {
  return {
    purpose: "elektrine-private-mailbox-key-wrap",
    version: 2,
    kind,
    algorithm: WRAP_ALGORITHM,
    kdf: MASTER_MODE,
    unlock_mode: MASTER_MODE
  }
}

export async function wrapBytesWithMasterKey(bytes, kind = "private_key") {
  const key = await masterEmailKey()
  const iv = randomBytes(12)
  const aadContext = masterAADContext(kind)
  const ciphertext = await crypto.subtle.encrypt(
    { name: WRAP_ALGORITHM, iv, additionalData: encodedStableJson(aadContext) },
    key,
    bytes
  )

  return {
    version: 2,
    algorithm: WRAP_ALGORITHM,
    kdf: MASTER_MODE,
    unlock_mode: MASTER_MODE,
    aad_context: aadContext,
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext))
  }
}

async function unwrapBytesWithMasterKey(payload) {
  const key = await masterEmailKey()
  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const plaintext = await crypto.subtle.decrypt(wrapParams(payload, iv), key, ciphertext)
  return new Uint8Array(plaintext)
}

export async function generateMailboxKeypair() {
  const keypair = await crypto.subtle.generateKey(
    {
      name: "RSA-OAEP",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256"
    },
    true,
    ["encrypt", "decrypt"]
  )

  const publicKey = new Uint8Array(await crypto.subtle.exportKey("spki", keypair.publicKey))
  const privateKey = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keypair.privateKey))

  return {
    publicKeyPem: bytesToPem(publicKey, "PUBLIC KEY"),
    privateKey
  }
}

async function importStoredPrivateKey(mailboxId) {
  return getStoredPrivateKey(mailboxId)
}

async function decryptEnvelope(envelope, mailboxId, aad) {
  const privateKey = await importStoredPrivateKey(mailboxId)
  if (!privateKey) return null

  const wrappedKey = base64ToBytes(envelope.encrypted_key)
  const contentKeyBytes = await crypto.subtle.decrypt({ name: "RSA-OAEP" }, privateKey, wrappedKey)
  const contentKey = await crypto.subtle.importKey(
    "raw",
    contentKeyBytes,
    { name: "AES-GCM" },
    false,
    ["decrypt"]
  )

  const ciphertext = base64ToBytes(envelope.ciphertext)
  const tag = base64ToBytes(envelope.tag)
  const iv = base64ToBytes(envelope.iv)

  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv, additionalData: envelopeAAD(envelope, aad) },
    contentKey,
    concatBytes(ciphertext, tag)
  )

  return JSON.parse(new TextDecoder().decode(plaintext))
}

function envelopeAAD(envelope, legacyAAD) {
  if (Number(envelope.version) >= 2 && envelope.aad_context) {
    return encodedStableJson(envelope.aad_context)
  }

  return legacyAAD
}

export async function decryptMessagePayload(envelope, mailboxId) {
  return decryptEnvelope(envelope, mailboxId, MESSAGE_AAD)
}

export async function decryptAttachmentPayload(envelope, mailboxId) {
  return decryptEnvelope(envelope, mailboxId, ATTACHMENT_AAD)
}

export async function unwrapMailboxPrivateKey(wrappedKeyPayload, verifierPayload, passphrase) {
  const verifierBytes = await unwrapBytes(verifierPayload, passphrase)
  const verifierText = decoder.decode(verifierBytes)

  if (verifierText !== VERIFY_TEXT) {
    throw new Error("invalid-passphrase")
  }

  return unwrapBytes(wrappedKeyPayload, passphrase)
}

async function importAndStorePrivateKey(mailboxId, privateKeyBytes) {
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    privateKeyBytes,
    { name: "RSA-OAEP", hash: "SHA-256" },
    false,
    ["decrypt"]
  )
  storePrivateKey(mailboxId, privateKey)
  dispatchMailboxEvent("elektrine:private-mailbox-unlocked", mailboxId)
}

export async function unlockMailbox(mailboxId, wrappedKeyPayload, verifierPayload, passphrase) {
  const privateKeyBytes = await unwrapMailboxPrivateKey(
    wrappedKeyPayload,
    verifierPayload,
    passphrase
  )
  await importAndStorePrivateKey(mailboxId, privateKeyBytes)
}

export async function unlockMailboxWithMaster(mailboxId, wrappedKeyPayload, verifierPayload) {
  const verifierBytes = await unwrapBytesWithMasterKey(verifierPayload)

  if (decoder.decode(verifierBytes) !== VERIFY_TEXT) {
    throw new Error("invalid-master-key")
  }

  const privateKeyBytes = await unwrapBytesWithMasterKey(wrappedKeyPayload)
  await importAndStorePrivateKey(mailboxId, privateKeyBytes)
}

export function lockedStatusText(unlockMode) {
  if (unlockMode === MASTER_MODE) {
    return "Mailbox locked. Enter your account password to continue."
  }

  if (unlockMode === "account_password") {
    return "Mailbox locked. Enter your account password to continue."
  }

  return "Mailbox locked."
}

export function unlockSecretLabel(unlockMode) {
  if (unlockMode === MASTER_MODE) return "account password"
  return unlockMode === "account_password" ? "account password" : "mailbox passphrase"
}

export function unlockSecretPlaceholder(unlockMode) {
  if (unlockMode === MASTER_MODE) return "Account password"
  return unlockMode === "account_password" ? "Account password" : "Mailbox passphrase"
}

export function maybeSetValue(field, nextValue, matcher) {
  if (!field) return

  const currentValue = field.value || ""
  const shouldReplace =
    currentValue.trim() === "" ||
    currentValue === field.dataset.privateMailboxLastApplied ||
    (typeof matcher === "function" && matcher(currentValue))

  if (!shouldReplace) return

  field.value = nextValue
  field.dataset.privateMailboxLastApplied = nextValue
}
