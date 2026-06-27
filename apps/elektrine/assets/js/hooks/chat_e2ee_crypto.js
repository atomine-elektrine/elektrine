export const CHAT_E2EE_STORAGE_PREFIX = 'elektrine:chat-e2ee:v1'
export const CHAT_E2EE_MAX_DEVICES = 64
export const textEncoder = new TextEncoder()
export const textDecoder = new TextDecoder()

const CHAT_E2EE_DB_NAME = 'elektrine-chat-e2ee'
const CHAT_E2EE_DB_VERSION = 1
const CHAT_E2EE_STORE_NAME = 'secrets'
let chatE2EEDatabasePromise = null

export function cryptoAvailable() {
  return Boolean(window.crypto?.subtle && window.crypto?.getRandomValues)
}

export function parseJson(value, fallback) {
  if (!value) return fallback

  try {
    return JSON.parse(value)
  } catch (_err) {
    return fallback
  }
}

export function stableJson(value) {
  if (Array.isArray(value)) return JSON.stringify(value.map(item => stableJsonValue(item)))
  if (!value || typeof value !== 'object') return JSON.stringify(value)

  return JSON.stringify(stableJsonValue(value))
}

function stableJsonValue(value) {
  if (Array.isArray(value)) return value.map(item => stableJsonValue(item))
  if (!value || typeof value !== 'object') return value

  return Object.keys(value)
    .sort()
    .reduce((acc, key) => {
      acc[key] = stableJsonValue(value[key])
      return acc
    }, {})
}

function openChatE2EEDatabase() {
  if (chatE2EEDatabasePromise) return chatE2EEDatabasePromise

  chatE2EEDatabasePromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(CHAT_E2EE_DB_NAME, CHAT_E2EE_DB_VERSION)

    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(CHAT_E2EE_STORE_NAME)) {
        db.createObjectStore(CHAT_E2EE_STORE_NAME)
      }
    }

    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error || new Error('Could not open chat key storage'))
  })

  return chatE2EEDatabasePromise
}

export async function secureStorageGet(key) {
  const db = await openChatE2EEDatabase()

  return new Promise((resolve, reject) => {
    const transaction = db.transaction(CHAT_E2EE_STORE_NAME, 'readonly')
    const request = transaction.objectStore(CHAT_E2EE_STORE_NAME).get(key)
    request.onsuccess = () => resolve(request.result ?? null)
    request.onerror = () => reject(request.error || new Error('Could not read chat key storage'))
  })
}

export async function secureStorageSet(key, value) {
  const db = await openChatE2EEDatabase()

  return new Promise((resolve, reject) => {
    const transaction = db.transaction(CHAT_E2EE_STORE_NAME, 'readwrite')
    const request = transaction.objectStore(CHAT_E2EE_STORE_NAME).put(value, key)
    request.onsuccess = () => resolve()
    request.onerror = () => reject(request.error || new Error('Could not write chat key storage'))
  })
}

export async function secureStorageDelete(key) {
  const db = await openChatE2EEDatabase()

  return new Promise((resolve, reject) => {
    const transaction = db.transaction(CHAT_E2EE_STORE_NAME, 'readwrite')
    const request = transaction.objectStore(CHAT_E2EE_STORE_NAME).delete(key)
    request.onsuccess = () => resolve()
    request.onerror = () => reject(request.error || new Error('Could not delete chat key storage'))
  })
}

export function bytesToBase64(bytes) {
  const array = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let binary = ''

  for (let offset = 0; offset < array.length; offset += 0x8000) {
    binary += String.fromCharCode(...array.subarray(offset, offset + 0x8000))
  }

  return btoa(binary)
}

export function base64ToBytes(value) {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)

  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index)
  }

  return bytes
}

function bytesToBase64Url(bytes) {
  return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

export function randomBytes(length) {
  const bytes = new Uint8Array(length)
  window.crypto.getRandomValues(bytes)
  return bytes
}

export function randomId(prefix) {
  if (window.crypto?.randomUUID) {
    return `${prefix}${window.crypto.randomUUID()}`
  }

  return `${prefix}${bytesToBase64Url(randomBytes(18))}`
}

export function arrayBufferFromBytes(bytes) {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

export async function sha256Base64Url(value) {
  const digest = await window.crypto.subtle.digest('SHA-256', textEncoder.encode(value))
  return bytesToBase64Url(digest)
}

export function extractSearchKeywords(text) {
  const stopWords = new Set([
    'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'can', 'had', 'her', 'was',
    'one', 'our', 'out', 'day', 'get', 'has', 'him', 'his', 'how', 'man', 'new', 'now',
    'old', 'see', 'two', 'way', 'who', 'boy', 'did', 'its', 'let', 'put', 'say', 'she',
    'too', 'use'
  ])

  const lower = text.toLowerCase()
  const hashtags = lower.match(/#[a-z0-9_]+/g) || []
  const words = lower
    .replace(/[^a-z0-9_\s#]/g, ' ')
    .split(/\s+/)
    .filter(word => word.length >= 3 && !stopWords.has(word))

  return Array.from(new Set([...hashtags, ...words]))
}

export function stableDevices(devices) {
  return [...devices]
    .map(device => ({
      user_id: Number.isInteger(Number(device.user_id)) ? Number(device.user_id) : null,
      recipient_handle: device.recipient_handle || null,
      origin_domain: device.origin_domain || null,
      device_id: String(device.device_id || ''),
      public_key: device.public_key || {},
      fingerprint: device.fingerprint || null,
      signing_public_key: device.signing_public_key || null,
      device_signature: device.device_signature || null
    }))
    .sort((left, right) => {
      const leftOwner = left.recipient_handle || String(left.user_id)
      const rightOwner = right.recipient_handle || String(right.user_id)
      if (leftOwner !== rightOwner) return leftOwner.localeCompare(rightOwner)
      return left.device_id.localeCompare(right.device_id)
    })
}

export async function devicesHash(devices) {
  return sha256Base64Url(JSON.stringify(stableDevices(devices)))
}

export async function importRsaPublicKey(publicKeyPayload) {
  const key = publicKeyPayload?.key

  if (!key || publicKeyPayload.algorithm !== 'RSA-OAEP-SHA256') {
    throw new Error('Invalid chat public key')
  }

  return window.crypto.subtle.importKey(
    'spki',
    arrayBufferFromBytes(base64ToBytes(key)),
    { name: 'RSA-OAEP', hash: 'SHA-256' },
    false,
    ['encrypt']
  )
}

export async function importRsaPrivateKey(privateKeyBase64) {
  return window.crypto.subtle.importKey(
    'pkcs8',
    arrayBufferFromBytes(base64ToBytes(privateKeyBase64)),
    { name: 'RSA-OAEP', hash: 'SHA-256' },
    false,
    ['decrypt']
  )
}

export async function importStoredRsaPrivateKey(privateKeyBase64) {
  return window.crypto.subtle.importKey(
    'pkcs8',
    arrayBufferFromBytes(base64ToBytes(privateKeyBase64)),
    { name: 'RSA-OAEP', hash: 'SHA-256' },
    false,
    ['decrypt']
  )
}

export async function importEcdsaPublicKey(publicKeyPayload) {
  const key = publicKeyPayload?.key

  if (!key || publicKeyPayload.algorithm !== 'ECDSA-P256-SHA256') {
    throw new Error('Invalid chat signing key')
  }

  return window.crypto.subtle.importKey(
    'spki',
    arrayBufferFromBytes(base64ToBytes(key)),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify']
  )
}

export async function importEcdsaPrivateKey(privateKeyBase64) {
  return window.crypto.subtle.importKey(
    'pkcs8',
    arrayBufferFromBytes(base64ToBytes(privateKeyBase64)),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  )
}

export async function importStoredEcdsaPrivateKey(privateKeyBase64) {
  return window.crypto.subtle.importKey(
    'pkcs8',
    arrayBufferFromBytes(base64ToBytes(privateKeyBase64)),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  )
}

export async function importAesKey(rawKeyBytes, usages) {
  return window.crypto.subtle.importKey(
    'raw',
    arrayBufferFromBytes(rawKeyBytes),
    { name: 'AES-GCM' },
    false,
    usages
  )
}

export async function importHmacKey(rawKeyBytes) {
  return window.crypto.subtle.importKey(
    'raw',
    arrayBufferFromBytes(rawKeyBytes),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  )
}

export function signingPublicKeyPayload(device) {
  if (device.signing_public_key?.key) return device.signing_public_key
  if (device.signing_public_key) {
    return { version: 1, algorithm: 'ECDSA-P256-SHA256', key: device.signing_public_key }
  }
  return null
}

function devicePublicKeyPayload(device) {
  if (device.public_key?.key) return device.public_key
  if (device.public_key) {
    return { version: 1, algorithm: 'RSA-OAEP-SHA256', key: device.public_key }
  }
  return null
}

export function deviceFingerprintPayload(device) {
  return {
    purpose: 'elektrine-chat-e2ee-device',
    version: 1,
    device_id: String(device.device_id || ''),
    key_algorithm: device.key_algorithm || 'RSA-OAEP-SHA256',
    public_key: devicePublicKeyPayload(device),
    signing_public_key: signingPublicKeyPayload(device)
  }
}

export function deviceSignaturePayload(device, fingerprint) {
  return {
    ...deviceFingerprintPayload(device),
    fingerprint
  }
}
