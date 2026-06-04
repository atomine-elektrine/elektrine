import { createEntry, getEntry, listEntries, updateEntry } from "./lib/api.js"
import {
  decryptValue,
  encryptValue,
  isClientPayload,
  nerveEntryAssociatedData,
  nerveMetadataAssociatedData,
  verifyPassphrase
} from "./lib/crypto.js"
import {
  clearPendingSave,
  clearStagedFill,
  getPendingSave,
  getStagedFill,
  getSettings,
  setPendingSave,
  setStagedFill
} from "./lib/storage.js"

const PENDING_SAVE_EXPIRY_MS = 5 * 60 * 1000
const STAGED_FILL_EXPIRY_MS = 3 * 60 * 1000
const VAULT_SESSION_IDLE_TIMEOUT_MS = 15 * 60 * 1000
let sessionPassphrase = ""
let sessionPassphraseExpiresAt = 0
let sessionPassphraseTimer = null

const MESSAGE_TYPES = {
  OPEN_OPTIONS: "ui:open-options",
  GET_INLINE_STATE: "nerve:get-inline-state",
  GET_SUGGESTIONS: "nerve:get-suggestions",
  FILL_ENTRY: "nerve:fill-entry",
  STAGE_ENTRY_FILL: "nerve:stage-entry-fill",
  RESOLVE_STAGED_FILL: "nerve:resolve-staged-fill",
  CLEAR_STAGED_FILL: "nerve:clear-staged-fill",
  RECORD_SUBMISSION: "nerve:record-submission",
  RESOLVE_PENDING_SAVE: "nerve:resolve-pending-save",
  SAVE_PENDING: "nerve:save-pending",
  DISMISS_PENDING_SAVE: "nerve:dismiss-pending-save",
  GET_SESSION_PASSPHRASE: "nerve:get-session-passphrase",
  SET_SESSION_PASSPHRASE: "nerve:set-session-passphrase",
  CLEAR_SESSION_PASSPHRASE: "nerve:clear-session-passphrase"
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
      assertContentScriptSender(sender)
      return inlineState()

    case MESSAGE_TYPES.GET_SUGGESTIONS:
      assertContentScriptSender(sender)
      return suggestions(message.pageUrl, message.query)

    case MESSAGE_TYPES.FILL_ENTRY:
      assertContentScriptSender(sender)
      return fillEntry(message.entryId, message.pageUrl)

    case MESSAGE_TYPES.STAGE_ENTRY_FILL:
      assertContentScriptSender(sender)
      return stageEntryFill(sender.tab?.id, message.payload || {})

    case MESSAGE_TYPES.RESOLVE_STAGED_FILL:
      assertContentScriptSender(sender)
      return resolveStagedFill(sender.tab?.id, message.page)

    case MESSAGE_TYPES.CLEAR_STAGED_FILL:
      assertContentScriptSender(sender)
      await clearStagedFill(sender.tab?.id)
      return { cleared: true }

    case MESSAGE_TYPES.RECORD_SUBMISSION:
      assertContentScriptSender(sender)
      return recordSubmission(sender.tab?.id, message.payload)

    case MESSAGE_TYPES.RESOLVE_PENDING_SAVE:
      assertContentScriptSender(sender)
      return resolvePendingSave(sender.tab?.id, message.page)

    case MESSAGE_TYPES.SAVE_PENDING:
      assertContentScriptSender(sender)
      return savePendingEntry(sender.tab?.id, message.payload || {})

    case MESSAGE_TYPES.DISMISS_PENDING_SAVE:
      assertContentScriptSender(sender)
      await clearPendingSave(sender.tab?.id)
      return { dismissed: true }

    case MESSAGE_TYPES.GET_SESSION_PASSPHRASE:
      assertExtensionPageSender(sender)
      expireSessionPassphraseIfNeeded()
      return { passphrase: sessionPassphrase }

    case MESSAGE_TYPES.SET_SESSION_PASSPHRASE:
      assertExtensionPageSender(sender)
      sessionPassphrase = typeof message.passphrase === "string" ? message.passphrase : ""
      scheduleSessionPassphraseExpiry()
      return { stored: true }

    case MESSAGE_TYPES.CLEAR_SESSION_PASSPHRASE:
      assertExtensionPageSender(sender)
      clearSessionPassphrase()
      return { cleared: true }

    default:
      throw new Error("Unsupported message type.")
  }
}

function assertContentScriptSender(sender) {
  if (!sender?.tab?.id || !allowedPageUrl(sender.url)) {
    throw new Error("Message is not allowed from this sender.")
  }
}

function assertExtensionPageSender(sender) {
  const extensionOrigin = chrome.runtime.getURL("")

  if (sender?.tab || typeof sender?.url !== "string" || !sender.url.startsWith(extensionOrigin)) {
    throw new Error("Message is not allowed from this sender.")
  }
}

function allowedPageUrl(url) {
  try {
    const parsed = new URL(url || "")
    return ["https:", "http:"].includes(parsed.protocol) && (
      parsed.protocol === "https:" ||
      parsed.hostname === "localhost" ||
      parsed.hostname === "127.0.0.1" ||
      parsed.hostname === "::1"
    )
  } catch (_error) {
    return false
  }
}

async function inlineState() {
  const session = await getNerveSession()

  return {
    status: session.status
  }
}

async function suggestions(pageUrl, query = "") {
  const session = await getNerveSession()

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

async function fillEntry(entryId, pageUrl = "") {
  const session = await getNerveSession()

  if (session.status !== "ready") {
    throw new Error(fillBlockedMessage(session.status))
  }

  const entry = session.entries.find((candidate) => candidate.id === entryId)

  if (!entry) {
    throw new Error("The selected entry is not available.")
  }

  if (!entryAllowedForPage(entry, pageUrl)) {
    throw new Error("This nerve entry is not saved for the current site.")
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

  const session = await getNerveSession()

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

  const session = await getNerveSession()
  const existingEntry = findExistingEntry(session.entries, pending)

  return {
    status: "prompt",
    nerveStatus: session.status,
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

  const session = await getNerveSession()

  if (session.status !== "ready") {
    throw new Error(fillBlockedMessage(session.status))
  }

  const attrs = {
    title: (payload.title || defaultTitle(pending)).trim(),
    login_username: (payload.username || pending.username || "").trim(),
    website: (payload.website || pending.website || originFromUrl(pending.submitUrl) || "").trim()
  }

  const metadata = { ...attrs }

  attrs.title = "Encrypted entry"
  attrs.login_username = ""
  attrs.website = ""
  attrs.encrypted_metadata = await encryptValue(
    JSON.stringify(metadata),
    session.passphrase,
    nerveMetadataAssociatedData()
  )

  attrs.encrypted_password = await encryptValue(
    pending.password,
    session.passphrase,
    nerveEntryAssociatedData(metadata, "password")
  )

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
  const entry = await hydrateEntryMetadata(data.entry, session.passphrase)

  return {
    username: entry.login_username || "",
    password: await decryptValue(
      entry.encrypted_password,
      session.passphrase,
      nerveEntryAssociatedData(entry, "password")
    ),
    notes: entry.encrypted_notes
      ? await decryptValue(entry.encrypted_notes, session.passphrase, nerveEntryAssociatedData(entry, "notes"))
      : ""
  }
}

async function cleanupTabState(tabId) {
  await Promise.allSettled([
    clearPendingSave(tabId),
    clearStagedFill(tabId)
  ])
}

async function getNerveSession() {
  const settings = await getSettings()

  if (!settings.serverUrl || !settings.apiToken) {
    return { status: "disconnected", settings, entries: [] }
  }

  const data = await listEntries(settings)
  const entries = Array.isArray(data.entries) ? data.entries : []

  if (!data.nerve_configured) {
    return { status: "unconfigured", settings, entries }
  }

  expireSessionPassphraseIfNeeded()
  const passphrase = sessionPassphrase

  if (!passphrase) {
    return { status: "locked", settings, entries }
  }

  if (data.nerve_verifier) {
    try {
      const valid = await verifyPassphrase(data.nerve_verifier, passphrase)

      if (!valid) {
        sessionPassphrase = ""
        return { status: "locked", settings, entries }
      }
    } catch (_error) {
      sessionPassphrase = ""
      return { status: "locked", settings, entries }
    }
  }

  scheduleSessionPassphraseExpiry()
  const hydratedEntries = await hydrateEntries(entries, passphrase)

  return {
    status: "ready",
    settings,
    passphrase,
    entries: hydratedEntries
  }
}

async function hydrateEntries(entries, passphrase) {
  return Promise.all(entries.map((entry) => hydrateEntryMetadata(entry, passphrase)))
}

async function hydrateEntryMetadata(entry, passphrase) {
  if (!entry || !passphrase || !isClientPayload(entry.encrypted_metadata)) {
    return entry
  }

  try {
    const decrypted = await decryptValue(
      entry.encrypted_metadata,
      passphrase,
      nerveMetadataAssociatedData()
    )
    const metadata = JSON.parse(decrypted)

    return {
      ...entry,
      title: metadata.title || entry.title || "Encrypted entry",
      login_username: metadata.login_username || "",
      website: metadata.website || ""
    }
  } catch (_error) {
    return entry
  }
}

function scheduleSessionPassphraseExpiry() {
  if (!sessionPassphrase) {
    clearSessionPassphrase()
    return
  }

  sessionPassphraseExpiresAt = Date.now() + VAULT_SESSION_IDLE_TIMEOUT_MS

  if (sessionPassphraseTimer) {
    clearTimeout(sessionPassphraseTimer)
  }

  sessionPassphraseTimer = setTimeout(clearSessionPassphrase, VAULT_SESSION_IDLE_TIMEOUT_MS)
}

function expireSessionPassphraseIfNeeded() {
  if (sessionPassphrase && sessionPassphraseExpiresAt > 0 && Date.now() >= sessionPassphraseExpiresAt) {
    clearSessionPassphrase()
  }
}

function clearSessionPassphrase() {
  sessionPassphrase = ""
  sessionPassphraseExpiresAt = 0

  if (sessionPassphraseTimer) {
    clearTimeout(sessionPassphraseTimer)
    sessionPassphraseTimer = null
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

function entryAllowedForPage(entry, pageUrl) {
  const pageHost = safeHost(pageUrl)
  const entryHost = safeHost(entry.website)

  return Boolean(pageHost && entryHost && hostsRelated(pageHost, entryHost))
}

function fillBlockedMessage(status) {
  switch (status) {
    case "disconnected":
      return "Sign in to Elektrine in extension settings first."
    case "unconfigured":
      return "Set up the nerve in the extension popup first."
    case "locked":
      return "Unlock the nerve in the extension popup first."
    default:
      return "Nerve access is not available."
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
  return left === right
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
