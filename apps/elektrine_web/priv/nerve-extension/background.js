import {
  createEntry,
  createKairoFileSource,
  createKairoSource,
  getEntry,
  listEntries,
  updateEntry
} from "./lib/api.js"
import {
  deriveFeatureKey,
  decryptValue,
  encryptValue,
  isClientPayload,
  nerveEntryAssociatedData,
  nerveMetadataAssociatedData,
  unwrapWithSecret
} from "./lib/crypto.js"
import {
  clearPendingSave,
  clearSessionPassphrase as clearStoredSessionPassphrase,
  clearStagedFill,
  getPendingSave,
  getStagedFill,
  getSettings,
  setPendingSave,
  setStagedFill
} from "./lib/storage.js"
import { kairoErrorMessage, kairoSourceAttrs } from "./lib/kairo_capture.js"

const PENDING_SAVE_EXPIRY_MS = 5 * 60 * 1000
const STAGED_FILL_EXPIRY_MS = 3 * 60 * 1000
const VAULT_SESSION_IDLE_TIMEOUT_MS = 15 * 60 * 1000
const KAIRO_CAPTURE_MAX_FILE_BYTES = 25 * 1024 * 1024
const FEATURE = "nerve"
const KAIRO_CONTEXT_MENUS = {
  PAGE: "kairo-capture-page",
  SELECTION: "kairo-capture-selection",
  FILE: "kairo-capture-file"
}
const ALLOWED_PAGE_PATTERNS = [
  "https://*/*",
  "http://localhost/*",
  "http://127.0.0.1/*",
  "http://[::1]/*"
]
let sessionPassphrase = ""
let sessionPassphraseExpiresAt = 0
let sessionPassphraseTimer = null

const MESSAGE_TYPES = {
  OPEN_OPTIONS: "ui:open-options",
  OPEN_MANAGER: "ui:open-manager",
  GET_THEME: "nerve:get-theme",
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
  UNLOCK_SESSION: "nerve:unlock-session",
  GET_SESSION_PASSPHRASE: "nerve:get-session-passphrase",
  SET_SESSION_PASSPHRASE: "nerve:set-session-passphrase",
  CLEAR_SESSION_PASSPHRASE: "nerve:clear-session-passphrase",
  SESSION_CHANGED: "nerve:session-changed"
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

if (chrome.runtime?.onInstalled) {
  chrome.runtime.onInstalled.addListener(() => {
    installContextMenus()
  })
}

if (chrome.runtime?.onStartup) {
  chrome.runtime.onStartup.addListener(() => {
    installContextMenus()
  })
}

if (chrome.contextMenus?.onClicked) {
  chrome.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === KAIRO_CONTEXT_MENUS.FILE) {
      void captureFileToKairo(info)
    } else if (Object.values(KAIRO_CONTEXT_MENUS).includes(info.menuItemId)) {
      void captureContextToKairo(info, tab)
    }
  })
}

async function handleMessage(message, sender) {
  switch (message.type) {
    case MESSAGE_TYPES.OPEN_OPTIONS:
      chrome.runtime.openOptionsPage()
      return { opened: true }

    case MESSAGE_TYPES.OPEN_MANAGER:
      assertContentScriptSender(sender)
      openManagerPage(sender.tab?.id)
      return { opened: true }

    case MESSAGE_TYPES.GET_THEME:
      assertContentScriptSender(sender)
      return themeState()

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

    case MESSAGE_TYPES.UNLOCK_SESSION:
      assertContentScriptSender(sender)
      return unlockSession(message.passphrase)

    case MESSAGE_TYPES.GET_SESSION_PASSPHRASE:
      assertExtensionPageSender(sender)
      return { passphrase: await currentSessionPassphrase() }

    case MESSAGE_TYPES.SET_SESSION_PASSPHRASE:
      assertExtensionPageSender(sender)
      sessionPassphrase = typeof message.passphrase === "string" ? message.passphrase : ""
      await clearStoredSessionPassphrase()
      scheduleSessionPassphraseExpiry()
      await broadcastNerveSessionChanged("unlocked")
      return { stored: true }

    case MESSAGE_TYPES.CLEAR_SESSION_PASSPHRASE:
      assertExtensionPageSender(sender)
      await clearRuntimeSessionPassphrase({ broadcast: true })
      return { cleared: true }

    default:
      throw new Error("Unsupported message type.")
  }
}

function installContextMenus() {
  if (!chrome.contextMenus?.removeAll || !chrome.contextMenus?.create) {
    return
  }

  chrome.contextMenus.removeAll(() => {
    contextMenuCreate({
      id: KAIRO_CONTEXT_MENUS.PAGE,
      title: "Capture page to Kairo",
      contexts: ["page"],
      documentUrlPatterns: ALLOWED_PAGE_PATTERNS
    })

    contextMenuCreate({
      id: KAIRO_CONTEXT_MENUS.SELECTION,
      title: "Capture selection to Kairo",
      contexts: ["selection"],
      documentUrlPatterns: ALLOWED_PAGE_PATTERNS
    })

    contextMenuCreate({
      id: KAIRO_CONTEXT_MENUS.FILE,
      title: "Save file to Kairo",
      contexts: ["image", "video", "audio", "link"],
      targetUrlPatterns: ALLOWED_PAGE_PATTERNS
    })
  })
}

function contextMenuCreate(options) {
  chrome.contextMenus.create(options, () => {
    void chrome.runtime.lastError
  })
}

async function captureContextToKairo(info, tab) {
  try {
    const settings = await getSettings()

    if (!settings.serverUrl || !settings.apiToken) {
      throw new Error("Connect your Elektrine account before capturing.")
    }

    const capture = {
      url: info.pageUrl || tab?.url || "",
      title: tab?.title || safeHost(info.pageUrl || tab?.url) || "Captured page",
      selectionText: info.menuItemId === KAIRO_CONTEXT_MENUS.SELECTION ? info.selectionText || "" : ""
    }

    await createKairoSource(settings, kairoSourceAttrs(capture))
    await setActionBadge("OK", "#6f8b74")
  } catch (error) {
    console.warn("Kairo capture failed:", kairoErrorMessage(error))
    await setActionBadge("!", "#a56b68")
  }
}

async function captureFileToKairo(info) {
  try {
    const settings = await getSettings()

    if (!settings.serverUrl || !settings.apiToken) {
      throw new Error("Connect your Elektrine account before capturing.")
    }

    const targetUrl = info.srcUrl || info.linkUrl || ""

    if (!allowedRemoteFileUrl(targetUrl)) {
      throw new Error("Only http and https files can be saved to Kairo.")
    }

    await verifyRemoteFileSize(targetUrl)

    const response = await fetch(targetUrl, { credentials: "omit" })

    if (!response.ok) {
      throw new Error(`Could not download file (${response.status}).`)
    }

    assertContentLengthWithinLimit(response.headers.get("content-length"))

    const contentType = normalizedContentType(response.headers.get("content-type"))
    const blob = await response.blob()

    if (blob.size > KAIRO_CAPTURE_MAX_FILE_BYTES) {
      throw new Error("That file is too large to save to Kairo.")
    }

    const filename = downloadFilename(targetUrl, response, contentType)
    const file = new File([blob], filename, { type: contentType || blob.type })

    await createKairoFileSource(settings, file, {
      title: filename,
      url: targetUrl,
      tags: "capture, browser-extension",
      metadata: {
        capture_type: "file",
        captured_at: new Date().toISOString(),
        source: "nerve-extension"
      }
    })

    await setActionBadge("OK", "#6f8b74")
  } catch (error) {
    console.warn("Kairo file capture failed:", kairoErrorMessage(error))
    await setActionBadge("!", "#a56b68")
  }
}

async function verifyRemoteFileSize(targetUrl) {
  try {
    const response = await fetch(targetUrl, { method: "HEAD", credentials: "omit" })

    if (response.ok) {
      assertContentLengthWithinLimit(response.headers.get("content-length"))
    }
  } catch (_error) {
    // Some servers reject HEAD; the GET response and blob size are checked too.
  }
}

function assertContentLengthWithinLimit(value) {
  const size = Number.parseInt(value || "", 10)

  if (Number.isFinite(size) && size > KAIRO_CAPTURE_MAX_FILE_BYTES) {
    throw new Error("That file is too large to save to Kairo.")
  }
}

function allowedRemoteFileUrl(value) {
  try {
    const url = new URL(value)

    return url.protocol === "https:" || localHttpUrl(url)
  } catch (_error) {
    return false
  }
}

function localHttpUrl(url) {
  return (
    url.protocol === "http:" &&
    ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
  )
}

function normalizedContentType(value) {
  return String(value || "").split(";")[0].trim().toLowerCase()
}

function downloadFilename(url, response, contentType) {
  const disposition = response.headers.get("content-disposition") || ""
  const dispositionName = filenameFromContentDisposition(disposition)
  const urlName = filenameFromUrl(url)
  const filename = sanitizeDownloadFilename(dispositionName || urlName || "kairo-file")

  if (/\.[a-z0-9]{1,8}$/i.test(filename)) {
    return filename
  }

  return `${filename}${extensionForContentType(contentType)}`
}

function filenameFromContentDisposition(disposition) {
  const encoded = disposition.match(/filename\*=UTF-8''([^;]+)/i)

  if (encoded) {
    try {
      return decodeURIComponent(encoded[1].replace(/^"|"$/g, ""))
    } catch (_error) {
      return encoded[1].replace(/^"|"$/g, "")
    }
  }

  const plain = disposition.match(/filename="?([^";]+)"?/i)
  return plain ? plain[1] : ""
}

function filenameFromUrl(value) {
  try {
    const pathname = new URL(value).pathname
    return decodeURIComponent(pathname.split("/").filter(Boolean).pop() || "")
  } catch (_error) {
    return ""
  }
}

function sanitizeDownloadFilename(value) {
  return String(value || "kairo-file")
    .split(/[\\/]/)
    .pop()
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim()
    .slice(0, 120) || "kairo-file"
}

function extensionForContentType(contentType) {
  switch (contentType) {
    case "image/jpeg":
    case "image/jpg":
      return ".jpg"
    case "image/png":
      return ".png"
    case "image/gif":
      return ".gif"
    case "image/webp":
      return ".webp"
    case "image/heic":
      return ".heic"
    case "image/heif":
      return ".heif"
    case "image/avif":
      return ".avif"
    case "application/pdf":
      return ".pdf"
    case "application/json":
      return ".json"
    case "application/markdown":
    case "text/markdown":
      return ".md"
    case "text/plain":
      return ".txt"
    default:
      return ".bin"
  }
}

async function setActionBadge(text, color) {
  if (!chrome.action?.setBadgeText) {
    return
  }

  await chrome.action.setBadgeText({ text })

  if (chrome.action.setBadgeBackgroundColor) {
    await chrome.action.setBadgeBackgroundColor({ color })
  }

  setTimeout(() => {
    chrome.action.setBadgeText({ text: "" })
  }, 1800)
}

function assertContentScriptSender(sender) {
  if (!sender?.tab?.id || !allowedPageUrl(sender.url)) {
    throw new Error("Message is not allowed from this sender.")
  }
}

function assertExtensionPageSender(sender) {
  const extensionOrigin = chrome.runtime.getURL("")

  if (typeof sender?.url !== "string" || !sender.url.startsWith(extensionOrigin)) {
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
    status: session.status,
    theme: session.theme || null
  }
}

async function themeState() {
  const settings = await getSettings()

  return {
    theme: settings.apiToken ? settings.theme || null : null
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
    session.key,
    nerveMetadataAssociatedData()
  )

  attrs.encrypted_password = await encryptValue(
    pending.password,
    session.key,
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
  const entry = await hydrateEntryMetadata(data.entry, session.key)

  return {
    username: entry.login_username || "",
    password: await decryptValue(
      entry.encrypted_password,
      session.key,
      nerveEntryAssociatedData(entry, "password")
    ),
    notes: entry.encrypted_notes
      ? await decryptValue(entry.encrypted_notes, session.key, nerveEntryAssociatedData(entry, "notes"))
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
    return { status: "disconnected", settings, theme: null, entries: [] }
  }

  const data = await listEntries(settings)
  const entries = Array.isArray(data.entries) ? data.entries : []
  const theme = data.theme || settings.theme || null

  if (!data.master_configured) {
    return { status: "unconfigured", settings, theme, entries }
  }

  const passphrase = await currentSessionPassphrase()

  if (!passphrase) {
    return { status: "locked", settings, theme, entries }
  }

  let key

  try {
    const mdk = await unwrapWithSecret(data.master_wrapped_dek, passphrase)
    key = await deriveFeatureKey(mdk, FEATURE)
  } catch (_error) {
    await clearRuntimeSessionPassphrase({ broadcast: true })
    return { status: "locked", settings, theme, entries }
  }

  scheduleSessionPassphraseExpiry()
  const hydratedEntries = await hydrateEntries(entries, key)

  return {
    status: "ready",
    settings,
    theme,
    key,
    entries: hydratedEntries
  }
}

async function unlockSession(passphrase) {
  const settings = await getSettings()

  if (!settings.serverUrl || !settings.apiToken) {
    throw new Error("Connect your Elektrine account first.")
  }

  if (!passphrase) {
    throw new Error("Enter your account password.")
  }

  const data = await listEntries(settings)

  if (!data.master_configured) {
    throw new Error("Set up account-password encryption in Elektrine first.")
  }

  if (!data.master_wrapped_dek) {
    throw new Error("Encrypted data metadata is not available yet.")
  }

  try {
    await unwrapWithSecret(data.master_wrapped_dek, passphrase)
  } catch (_error) {
    throw new Error(
      "Incorrect account password. If you just reset it, recover encrypted data on the website."
    )
  }

  sessionPassphrase = passphrase
  await clearStoredSessionPassphrase()
  scheduleSessionPassphraseExpiry()
  await broadcastNerveSessionChanged("unlocked")

  return { status: "unlocked" }
}

async function hydrateEntries(entries, key) {
  return Promise.all(entries.map((entry) => hydrateEntryMetadata(entry, key)))
}

async function hydrateEntryMetadata(entry, key) {
  if (!entry || !key || !isClientPayload(entry.encrypted_metadata)) {
    return entry
  }

  try {
    const decrypted = await decryptValue(
      entry.encrypted_metadata,
      key,
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
    void clearRuntimeSessionPassphrase()
    return
  }

  sessionPassphraseExpiresAt = Date.now() + VAULT_SESSION_IDLE_TIMEOUT_MS

  if (sessionPassphraseTimer) {
    clearTimeout(sessionPassphraseTimer)
  }

  sessionPassphraseTimer = setTimeout(() => {
    void clearRuntimeSessionPassphrase({ broadcast: true })
  }, VAULT_SESSION_IDLE_TIMEOUT_MS)
}

async function currentSessionPassphrase() {
  if (await expireSessionPassphraseIfNeeded()) {
    return ""
  }

  return sessionPassphrase
}

async function expireSessionPassphraseIfNeeded() {
  if (sessionPassphrase && sessionPassphraseExpiresAt > 0 && Date.now() >= sessionPassphraseExpiresAt) {
    await clearRuntimeSessionPassphrase({ broadcast: true })
    return true
  }

  return false
}

async function clearRuntimeSessionPassphrase({ broadcast = false } = {}) {
  sessionPassphrase = ""
  sessionPassphraseExpiresAt = 0

  if (sessionPassphraseTimer) {
    clearTimeout(sessionPassphraseTimer)
    sessionPassphraseTimer = null
  }

  await clearStoredSessionPassphrase()

  if (broadcast) {
    await broadcastNerveSessionChanged("locked")
  }
}

async function broadcastNerveSessionChanged(status) {
  if (!chrome.tabs?.query || !chrome.tabs?.sendMessage) {
    return
  }

  const tabs = await queryPageTabs()

  await Promise.allSettled(
    tabs
      .filter((tab) => tab.id && allowedPageUrl(tab.url))
      .map((tab) => sendTabMessage(tab.id, {
        type: MESSAGE_TYPES.SESSION_CHANGED,
        status
      }))
  )
}

function queryPageTabs() {
  return new Promise((resolve) => {
    chrome.tabs.query({ url: ALLOWED_PAGE_PATTERNS }, (tabs) => {
      if (chrome.runtime.lastError) {
        resolve([])
        return
      }

      resolve(Array.isArray(tabs) ? tabs : [])
    })
  })
}

function sendTabMessage(tabId, message) {
  return new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, message, () => {
      void chrome.runtime.lastError
      resolve()
    })
  })
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
      return "Set up account-password encryption in Elektrine first."
    case "locked":
      return "Unlock Elektrine in the extension manager first."
    default:
      return "Elektrine access is not available."
  }
}

function openManagerPage(tabId) {
  const params = new URLSearchParams()

  if (tabId) {
    params.set("tabId", String(tabId))
  }

  chrome.tabs.create({ url: chrome.runtime.getURL(`manager.html?${params.toString()}`) })
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
