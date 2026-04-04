const SETTINGS_KEYS = ["serverUrl"]
const TOKEN_KEY = "apiToken"
const PASSPHRASE_KEY = "vaultPassphrase"
const PENDING_SAVES_KEY = "pendingLoginSaves"
const STAGED_FILLS_KEY = "stagedEntryFills"

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
  const tokenValues = await storageGet("session", TOKEN_KEY)

  return {
    serverUrl: values.serverUrl || "",
    apiToken: tokenValues[TOKEN_KEY] || ""
  }
}

export async function saveSettings(settings) {
  await storageSet("local", {
    serverUrl: (settings.serverUrl || "").trim()
  })

  await storageSet("session", {
    [TOKEN_KEY]: (settings.apiToken || "").trim()
  })
}

export async function getSessionPassphrase() {
  const values = await storageGet("session", PASSPHRASE_KEY)
  return values[PASSPHRASE_KEY] || ""
}

export async function setSessionPassphrase(passphrase) {
  await storageSet("session", { [PASSPHRASE_KEY]: passphrase })
}

export async function clearSessionPassphrase() {
  await storageRemove("session", PASSPHRASE_KEY)
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
  return getSessionMapEntry(PENDING_SAVES_KEY, tabId)
}

export async function setPendingSave(tabId, value) {
  await setSessionMapEntry(PENDING_SAVES_KEY, tabId, value)
}

export async function clearPendingSave(tabId) {
  await clearSessionMapEntry(PENDING_SAVES_KEY, tabId)
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
