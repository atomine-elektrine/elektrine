import { createEntry, getEntry, listEntries, updateEntry } from "./lib/api.js"
import { decryptValue, encryptValue, verifyPassphrase } from "./lib/crypto.js"
import {
  clearPendingSave,
  clearStagedFill,
  clearSessionPassphrase,
  getPendingSave,
  getStagedFill,
  getSessionPassphrase,
  getSettings,
  setPendingSave,
  setStagedFill
} from "./lib/storage.js"

const PENDING_SAVE_EXPIRY_MS = 5 * 60 * 1000
const STAGED_FILL_EXPIRY_MS = 3 * 60 * 1000

const MESSAGE_TYPES = {
  OPEN_OPTIONS: "ui:open-options",
  GET_INLINE_STATE: "vault:get-inline-state",
  GET_SUGGESTIONS: "vault:get-suggestions",
  FILL_ENTRY: "vault:fill-entry",
  STAGE_ENTRY_FILL: "vault:stage-entry-fill",
  RESOLVE_STAGED_FILL: "vault:resolve-staged-fill",
  CLEAR_STAGED_FILL: "vault:clear-staged-fill",
  RECORD_SUBMISSION: "vault:record-submission",
  RESOLVE_PENDING_SAVE: "vault:resolve-pending-save",
  SAVE_PENDING: "vault:save-pending",
  DISMISS_PENDING_SAVE: "vault:dismiss-pending-save"
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message || {}, sender)
    .then((result) => sendResponse({ ok: true, ...result }))
    .catch((error) => sendResponse({ ok: false, error: error.message }))

  return true
})

if (chrome.tabs?.onRemoved) {
  chrome.tabs.onRemoved.addListener((tabId) => {
    void cleanupTabState(tabId)
  })
}

async function handleMessage(message, sender) {
  switch (message.type) {
    case MESSAGE_TYPES.OPEN_OPTIONS:
      chrome.runtime.openOptionsPage()
      return { opened: true }

    case MESSAGE_TYPES.GET_INLINE_STATE:
      return inlineState()

    case MESSAGE_TYPES.GET_SUGGESTIONS:
      return suggestions(message.pageUrl, message.query)

    case MESSAGE_TYPES.FILL_ENTRY:
      return fillEntry(message.entryId)

    case MESSAGE_TYPES.STAGE_ENTRY_FILL:
      return stageEntryFill(sender.tab?.id, message.payload || {})

    case MESSAGE_TYPES.RESOLVE_STAGED_FILL:
      return resolveStagedFill(sender.tab?.id, message.page)

    case MESSAGE_TYPES.CLEAR_STAGED_FILL:
      await clearStagedFill(sender.tab?.id)
      return { cleared: true }

    case MESSAGE_TYPES.RECORD_SUBMISSION:
      return recordSubmission(sender.tab?.id, message.payload)

    case MESSAGE_TYPES.RESOLVE_PENDING_SAVE:
      return resolvePendingSave(sender.tab?.id, message.page)

    case MESSAGE_TYPES.SAVE_PENDING:
      return savePendingEntry(sender.tab?.id, message.payload || {})

    case MESSAGE_TYPES.DISMISS_PENDING_SAVE:
      await clearPendingSave(sender.tab?.id)
      return { dismissed: true }

    default:
      return { ignored: true }
  }
}

async function inlineState() {
  const session = await getVaultSession()

  return {
    status: session.status
  }
}

async function suggestions(pageUrl, query = "") {
  const session = await getVaultSession()

  if (session.status !== "ready") {
    return { status: session.status }
  }

  const matches = rankEntries(session.entries, pageUrl, query).slice(0, 6)

  return {
    status: "ready",
    entries: matches.map(({ entry, score }) => ({
      id: entry.id,
      title: entry.title,
      login_username: entry.login_username,
      website: entry.website,
      score
    }))
  }
}

async function fillEntry(entryId) {
  const session = await getVaultSession()

  if (session.status !== "ready") {
    throw new Error(fillBlockedMessage(session.status))
  }

  return {
    status: "ready",
    credentials: await loadEntryCredentials(session, entryId)
  }
}

async function recordSubmission(tabId, payload) {
  if (!tabId || !payload?.password || payload.skipSave) {
    return { recorded: false }
  }

  await setPendingSave(tabId, {
    submitUrl: payload.submitUrl,
    website: payload.website,
    username: payload.username || "",
    password: payload.password,
    pageTitle: payload.pageTitle || "",
    recordedAt: Date.now()
  })

  return { recorded: true }
}

async function stageEntryFill(tabId, payload) {
  if (!tabId || !payload?.entryId) {
    return { staged: false }
  }

  await setStagedFill(tabId, {
    entryId: payload.entryId,
    pageUrl: payload.pageUrl || "",
    website: payload.website || "",
    stagedAt: Date.now()
  })

  return { staged: true }
}

async function resolveStagedFill(tabId, page) {
  const staged = await getStagedFill(tabId)

  if (!staged) {
    return { status: "none" }
  }

  if (Date.now() - staged.stagedAt > STAGED_FILL_EXPIRY_MS) {
    await clearStagedFill(tabId)
    return { status: "none" }
  }

  if (!page?.url) {
    return { status: "none" }
  }

  const currentHost = safeHost(page.url)
  const stagedHost = safeHost(staged.website || staged.pageUrl)

  if (currentHost && stagedHost && !hostsRelated(currentHost, stagedHost)) {
    await clearStagedFill(tabId)
    return { status: "none" }
  }

  if (!page.hasVisiblePasswordField) {
    return { status: "waiting" }
  }

  const session = await getVaultSession()

  if (session.status !== "ready") {
    return { status: session.status }
  }

  try {
    const credentials = await loadEntryCredentials(session, staged.entryId)
    await clearStagedFill(tabId)

    return {
      status: "ready",
      entryId: staged.entryId,
      credentials
    }
  } catch (error) {
    await clearStagedFill(tabId)
    throw error
  }
}

async function resolvePendingSave(tabId, page) {
  const pending = await getPendingSave(tabId)

  if (!pending) {
    return { status: "none" }
  }

  if (Date.now() - pending.recordedAt > PENDING_SAVE_EXPIRY_MS) {
    await clearPendingSave(tabId)
    return { status: "none" }
  }

  if (!shouldPromptForPendingSave(pending, page)) {
    return { status: "none" }
  }

  const session = await getVaultSession()
  const existingEntry = findExistingEntry(session.entries, pending)

  return {
    status: "prompt",
    vaultStatus: session.status,
    pending: {
      mode: existingEntry ? "update" : "save",
      entryId: existingEntry?.id || null,
      title: existingEntry?.title || defaultTitle(pending),
      username: pending.username || existingEntry?.login_username || "",
      website: pending.website || existingEntry?.website || originFromUrl(pending.submitUrl)
    }
  }
}

async function savePendingEntry(tabId, payload) {
  const pending = await getPendingSave(tabId)

  if (!pending) {
    throw new Error("There is no pending login to save.")
  }

  const session = await getVaultSession()

  if (session.status !== "ready") {
    throw new Error(fillBlockedMessage(session.status))
  }

  const attrs = {
    title: (payload.title || defaultTitle(pending)).trim(),
    login_username: (payload.username || pending.username || "").trim(),
    website: (payload.website || pending.website || originFromUrl(pending.submitUrl) || "").trim(),
    encrypted_password: await encryptValue(pending.password, session.passphrase)
  }

  const result =
    payload.entryId
      ? await updateEntry(session.settings, payload.entryId, attrs)
      : await createEntry(session.settings, attrs)

  await clearPendingSave(tabId)

  return {
    status: "saved",
    mode: payload.entryId ? "update" : "save",
    entry: result.entry
  }
}

async function loadEntryCredentials(session, entryId) {
  const data = await getEntry(session.settings, entryId)
  const entry = data.entry

  return {
    username: entry.login_username || "",
    password: await decryptValue(entry.encrypted_password, session.passphrase),
    notes: entry.encrypted_notes ? await decryptValue(entry.encrypted_notes, session.passphrase) : ""
  }
}

async function cleanupTabState(tabId) {
  await Promise.allSettled([
    clearPendingSave(tabId),
    clearStagedFill(tabId)
  ])
}

async function getVaultSession() {
  const settings = await getSettings()

  if (!settings.serverUrl || !settings.apiToken) {
    return { status: "disconnected", settings, entries: [] }
  }

  const data = await listEntries(settings)
  const entries = Array.isArray(data.entries) ? data.entries : []

  if (!data.vault_configured) {
    return { status: "unconfigured", settings, entries }
  }

  const passphrase = await getSessionPassphrase()

  if (!passphrase) {
    return { status: "locked", settings, entries }
  }

  if (data.vault_verifier) {
    try {
      const valid = await verifyPassphrase(data.vault_verifier, passphrase)

      if (!valid) {
        await clearSessionPassphrase()
        return { status: "locked", settings, entries }
      }
    } catch (_error) {
      await clearSessionPassphrase()
      return { status: "locked", settings, entries }
    }
  }

  return {
    status: "ready",
    settings,
    passphrase,
    entries
  }
}

function shouldPromptForPendingSave(pending, page) {
  if (!page?.url) {
    return false
  }

  const currentHost = safeHost(page.url)
  const submitHost = safeHost(pending.submitUrl)

  if (currentHost && submitHost && !hostsRelated(currentHost, submitHost)) {
    return false
  }

  if (!page.hasVisiblePasswordField) {
    return true
  }

  return page.url !== pending.submitUrl && !looksLikeLoginUrl(page.url)
}

function findExistingEntry(entries, pending) {
  const pendingHost = safeHost(pending.website || pending.submitUrl)
  const username = (pending.username || "").trim().toLowerCase()

  const ranked = entries
    .map((entry) => {
      const entryHost = safeHost(entry.website)
      let score = 0

      if (pendingHost && entryHost && hostsRelated(pendingHost, entryHost)) {
        score += 50
      }

      if (username && (entry.login_username || "").trim().toLowerCase() === username) {
        score += 40
      }

      if ((entry.title || "").trim().toLowerCase() === defaultTitle(pending).toLowerCase()) {
        score += 10
      }

      return { entry, score }
    })
    .filter(({ score }) => score > 0)
    .sort((left, right) => right.score - left.score)

  return ranked[0]?.entry || null
}

function rankEntries(entries, pageUrl, query) {
  const host = safeHost(pageUrl)
  const queryText = (query || "").trim().toLowerCase()

  return entries
    .map((entry) => {
      const entryHost = safeHost(entry.website)
      let score = 0

      if (host && entryHost) {
        if (host === entryHost) {
          score += 40
        } else if (hostsRelated(host, entryHost)) {
          score += 24
        }
      }

      const haystack = [entry.title, entry.login_username, entry.website]
        .filter(Boolean)
        .join(" ")
        .toLowerCase()

      if (queryText) {
        if (haystack.includes(queryText)) {
          score += 20
        } else {
          score -= 100
        }
      }

      return { entry, score }
    })
    .filter(({ score }) => score >= 0)
    .sort((left, right) => {
      if (left.score !== right.score) {
        return right.score - left.score
      }

      return left.entry.title.localeCompare(right.entry.title)
    })
}

function fillBlockedMessage(status) {
  switch (status) {
    case "disconnected":
      return "Sign in to Elektrine in extension settings first."
    case "unconfigured":
      return "Set up the vault in the extension popup first."
    case "locked":
      return "Unlock the vault in the extension popup first."
    default:
      return "Vault access is not available."
  }
}

function defaultTitle(pending) {
  const host = safeHost(pending.website || pending.submitUrl)

  if (host) {
    return host.replace(/^www\./, "")
  }

  return "Saved Login"
}

function originFromUrl(url) {
  try {
    return new URL(url).origin
  } catch (_error) {
    return ""
  }
}

function safeHost(url) {
  try {
    return new URL(url).hostname
  } catch (_error) {
    return ""
  }
}

function hostsRelated(left, right) {
  return left === right || left.endsWith(`.${right}`) || right.endsWith(`.${left}`)
}

function looksLikeLoginUrl(url) {
  try {
    const value = new URL(url)
    const path = `${value.pathname} ${value.search}`.toLowerCase()
    return /(login|signin|sign-in|auth|password|session)/.test(path)
  } catch (_error) {
    return false
  }
}
