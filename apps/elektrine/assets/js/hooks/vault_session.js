/**
 * Vault session - the unlocked master key for this browser tab.
 *
 * Holds the Master Data Key (MDK) in memory only (never persisted to
 * localStorage/sessionStorage), so unlocking once unlocks Nerve, Kairo, and
 * email private storage together, and a tab reload re-locks (matching Nerve's
 * existing behavior). Per-feature keys are derived lazily and cached for the
 * session. This is a module singleton shared by every hook that imports it.
 */

import { deriveFeatureKey, deriveFeatureHmacKey } from "./vault_crypto"

let mdk = null
const featureKeys = new Map()
const featureHmacKeys = new Map()
const listeners = new Set()

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
  featureKeys.clear()
  featureHmacKeys.clear()
  notify()
}

/** Forget the MDK and all derived keys. */
export function lock() {
  mdk = null
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
