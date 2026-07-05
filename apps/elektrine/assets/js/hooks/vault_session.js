/**
 * Vault session - the unlocked encrypted data key for this browser tab.
 *
 * Holds the Master Data Key (MDK) for this browser tab/session, so unlocking
 * once unlocks Nerve, Kairo, and email private storage together even when
 * navigation crosses LiveView/app boundaries. The MDK is stored in
 * sessionStorage, not localStorage: it clears on tab close and explicit lock.
 * Per-feature keys are derived lazily and cached in memory.
 */

import { base64ToBytes, bytesToBase64, deriveFeatureKey, deriveFeatureHmacKey } from "./vault_crypto"

const SESSION_KEY = "elektrine:vault-session:mdk"

let mdk = readStoredMdk()
const featureKeys = new Map()
const featureHmacKeys = new Map()
const listeners = new Set()

function storage() {
  try {
    return typeof window !== "undefined" ? window.sessionStorage : null
  } catch (_error) {
    return null
  }
}

function readStoredMdk() {
  try {
    const value = storage()?.getItem(SESSION_KEY)
    if (!value) return null

    const bytes = base64ToBytes(value)
    return bytes.length === 32 ? bytes : null
  } catch (_error) {
    clearStoredMdk()
    return null
  }
}

function storeMdk(mdkBytes) {
  try {
    storage()?.setItem(SESSION_KEY, bytesToBase64(mdkBytes))
  } catch (_error) {
    // Session persistence is best-effort; memory unlock still works.
  }
}

function clearStoredMdk() {
  try {
    storage()?.removeItem(SESSION_KEY)
  } catch (_error) {
    // Ignore storage failures.
  }
}

function notify() {
  const unlocked = isUnlocked()
  listeners.forEach((fn) => {
    try {
      fn(unlocked)
    } catch (_error) {
      // a listener throwing must not break the others
    }
  })
}

export function isUnlocked() {
  return mdk !== null
}

/** Store the unlocked MDK (a Uint8Array) for the tab and notify subscribers. */
export function unlock(mdkBytes) {
  mdk = mdkBytes
  storeMdk(mdkBytes)
  featureKeys.clear()
  featureHmacKeys.clear()
  notify()
}

/** Forget the MDK and all derived keys. */
export function lock() {
  mdk = null
  clearStoredMdk()
  featureKeys.clear()
  featureHmacKeys.clear()
  notify()
}

/** AES-GCM key for a feature ("nerve" | "kairo" | "email"). Throws if locked. */
export async function featureKey(feature) {
  if (!mdk) throw new Error("vault-locked")
  if (!featureKeys.has(feature)) {
    featureKeys.set(feature, await deriveFeatureKey(mdk, feature))
  }
  return featureKeys.get(feature)
}

/** HMAC key for a feature (blind dedup hashes). Throws if locked. */
export async function featureHmacKey(feature) {
  if (!mdk) throw new Error("vault-locked")
  if (!featureHmacKeys.has(feature)) {
    featureHmacKeys.set(feature, await deriveFeatureHmacKey(mdk, feature))
  }
  return featureHmacKeys.get(feature)
}

/** Subscribe to lock/unlock changes; returns an unsubscribe function. */
export function subscribe(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}
