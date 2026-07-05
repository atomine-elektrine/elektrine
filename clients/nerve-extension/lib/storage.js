const SETTINGS_KEYS = ["serverUrl"]
const TOKEN_KEY = "apiToken"
const THEME_KEY = "theme"
const PASSPHRASE_KEY = "vaultPassphrase"
const STAGED_FILLS_KEY = "stagedEntryFills"
const PENDING_SAVE_MEMORY_TTL_MS = 5 * 60 * 1000
const pendingLoginSaves = new Map()

function getArea(areaName) {
  const area = chrome?.storage?.[areaName]

  if (!area) {
    throw new Error(`Storage area "${areaName}" is not available in this browser.`)
  }

  return area
}

function storageGet(areaName, keys) {
  const area = getArea(areaName)

  return new Promise((resolve, reject) => {
    area.get(keys, (result) => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message))
        return
      }

      resolve(result)
    })
  })
}

function storageSet(areaName, values) {
  const area = getArea(areaName)

  return new Promise((resolve, reject) => {
    area.set(values, () => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message))
        return
      }

      resolve()
    })
  })
}

function storageRemove(areaName, keys) {
  const area = getArea(areaName)

  return new Promise((resolve, reject) => {
    area.remove(keys, () => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message))
        return
      }

      resolve()
    })
  })
}

export async function getSettings() {
  const values = await storageGet("local", SETTINGS_KEYS)
  const tokenValues = await storageGet("session", [TOKEN_KEY, THEME_KEY])
  const apiToken = tokenValues[TOKEN_KEY] || ""

  return {
    serverUrl: values.serverUrl || "",
    apiToken,
    theme: apiToken ? tokenValues[THEME_KEY] || null : null
  }
}

export async function saveSettings(settings) {
  await storageSet("local", {
    serverUrl: (settings.serverUrl || "").trim()
  })

  const apiToken = (settings.apiToken || "").trim()
  const sessionValues = { [TOKEN_KEY]: apiToken }

  if (Object.prototype.hasOwnProperty.call(settings, "theme")) {
    sessionValues[THEME_KEY] = settings.theme || null
  }

  await storageSet("session", sessionValues)

  if (!apiToken) {
    await storageRemove("session", THEME_KEY)
  }
}

export async function clearSessionPassphrase() {
  await storageRemove("session", PASSPHRASE_KEY)
}

function pendingSaveKey(tabId) {
  return tabId ? String(tabId) : null
}

function pendingSaveExpired(value) {
  return !value?.recordedAt || Date.now() - value.recordedAt > PENDING_SAVE_MEMORY_TTL_MS
}

async function sessionMapValues(storageKey) {
  const values = await storageGet("session", storageKey)
  return values[storageKey] || {}
}

async function getSessionMapEntry(storageKey, entryKey) {
  if (!entryKey) return null

  const values = await sessionMapValues(storageKey)
  return values[String(entryKey)] || null
}

async function setSessionMapEntry(storageKey, entryKey, value) {
  if (!entryKey) return

  const values = await sessionMapValues(storageKey)
  values[String(entryKey)] = value

  await storageSet("session", {
    [storageKey]: values
  })
}

async function clearSessionMapEntry(storageKey, entryKey) {
  if (!entryKey) return

  const values = await sessionMapValues(storageKey)
  delete values[String(entryKey)]

  await storageSet("session", {
    [storageKey]: values
  })
}

export async function getPendingSave(tabId) {
  const key = pendingSaveKey(tabId)
  if (!key) return null

  const value = pendingLoginSaves.get(key) || null

  if (pendingSaveExpired(value)) {
    pendingLoginSaves.delete(key)
    return null
  }

  return value
}

export async function setPendingSave(tabId, value) {
  const key = pendingSaveKey(tabId)
  if (!key) return

  pendingLoginSaves.set(key, value)
}

export async function clearPendingSave(tabId) {
  const key = pendingSaveKey(tabId)
  if (!key) return

  pendingLoginSaves.delete(key)
}

export async function getStagedFill(tabId) {
  return getSessionMapEntry(STAGED_FILLS_KEY, tabId)
}

export async function setStagedFill(tabId, value) {
  await setSessionMapEntry(STAGED_FILLS_KEY, tabId, value)
}

export async function clearStagedFill(tabId) {
  await clearSessionMapEntry(STAGED_FILLS_KEY, tabId)
}
