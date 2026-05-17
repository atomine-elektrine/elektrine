import { createEntry, deleteNerve, getEntry, listEntries, setupNerve } from "./lib/api.js"
import { getSettings } from "./lib/storage.js"
import {
  VERIFIER_TEXT,
  MIN_PASSPHRASE_LENGTH,
  createPassword,
  decryptValue,
  encryptValue,
  isClientPayload,
  nerveEntryAssociatedData,
  nerveMetadataAssociatedData,
  verifyPassphrase
} from "./lib/crypto.js"

const state = {
  settings: { serverUrl: "", apiToken: "" },
  currentTab: null,
  entries: [],
  nerveConfigured: false,
  nerveVerifier: null,
  passphrase: ""
}

const refs = {}
const MESSAGE_TYPES = {
  GET_SESSION_PASSPHRASE: "nerve:get-session-passphrase",
  SET_SESSION_PASSPHRASE: "nerve:set-session-passphrase",
  CLEAR_SESSION_PASSPHRASE: "nerve:clear-session-passphrase"
}

document.addEventListener("DOMContentLoaded", init)

async function init() {
  captureRefs()
  bindEvents()

  state.currentTab = await getActiveTab()
  renderCurrentSite()

  state.settings = await getSettings()
  state.passphrase = await getRuntimePassphrase()

  render()

  if (isConfigured()) {
    await refreshNerveIndex()
  } else {
    setFeedback("Add your server URL and sign in in Settings before using the extension.", "info")
  }
}

function captureRefs() {
  refs.feedback = document.querySelector("#feedback")
  refs.currentSiteLabel = document.querySelector("#currentSiteLabel")
  refs.openOptionsButton = document.querySelector("#openOptionsButton")
  refs.configureButton = document.querySelector("#configureButton")
  refs.configSection = document.querySelector("#configSection")
  refs.setupSection = document.querySelector("#setupSection")
  refs.unlockSection = document.querySelector("#unlockSection")
  refs.nerveSection = document.querySelector("#nerveSection")
  refs.resetSection = document.querySelector("#resetSection")
  refs.setupForm = document.querySelector("#setupForm")
  refs.setupPassphrase = document.querySelector("#setupPassphrase")
  refs.setupPassphraseConfirm = document.querySelector("#setupPassphraseConfirm")
  refs.setupSubmitButton = document.querySelector("#setupSubmitButton")
  refs.unlockForm = document.querySelector("#unlockForm")
  refs.unlockPassphrase = document.querySelector("#unlockPassphrase")
  refs.unlockSubmitButton = document.querySelector("#unlockSubmitButton")
  refs.lockButton = document.querySelector("#lockButton")
  refs.resetNerveButton = document.querySelector("#resetNerveButton")
  refs.searchInput = document.querySelector("#searchInput")
  refs.createEntryForm = document.querySelector("#createEntryForm")
  refs.entryTitle = document.querySelector("#entryTitle")
  refs.entryUsername = document.querySelector("#entryUsername")
  refs.entryWebsite = document.querySelector("#entryWebsite")
  refs.entryPassword = document.querySelector("#entryPassword")
  refs.entryNotes = document.querySelector("#entryNotes")
  refs.generatePasswordButton = document.querySelector("#generatePasswordButton")
  refs.createEntrySubmitButton = document.querySelector("#createEntrySubmitButton")
  refs.entriesList = document.querySelector("#entriesList")
}

function bindEvents() {
  refs.openOptionsButton.addEventListener("click", openOptionsPage)
  refs.configureButton.addEventListener("click", openOptionsPage)
  refs.setupForm.addEventListener("submit", handleSetupSubmit)
  refs.unlockForm.addEventListener("submit", handleUnlockSubmit)
  refs.lockButton.addEventListener("click", handleLock)
  refs.resetNerveButton.addEventListener("click", handleDeleteNerve)
  refs.searchInput.addEventListener("input", renderEntries)
  refs.generatePasswordButton.addEventListener("click", handleGeneratePassword)
  refs.createEntryForm.addEventListener("submit", handleCreateEntrySubmit)
  refs.entriesList.addEventListener("click", handleEntryAction)
}

function isConfigured() {
  return Boolean(state.settings.serverUrl && state.settings.apiToken)
}

function isUnlocked() {
  return Boolean(state.passphrase)
}

function setBusy(button, busy) {
  if (!button) return
  button.disabled = busy
}

function setFeedback(message, type = "info") {
  refs.feedback.textContent = message
  refs.feedback.className = `feedback ${type}`
}

function clearFeedback() {
  refs.feedback.textContent = ""
  refs.feedback.className = "feedback hidden"
}

function renderCurrentSite() {
  const host = safeHost(state.currentTab?.url)
  refs.currentSiteLabel.textContent = host || "No supported page selected"
}

function render() {
  refs.configSection.classList.toggle("hidden", isConfigured())
  refs.setupSection.classList.toggle("hidden", !isConfigured() || state.nerveConfigured)
  refs.unlockSection.classList.toggle("hidden", !isConfigured() || !state.nerveConfigured || isUnlocked())
  refs.nerveSection.classList.toggle("hidden", !isConfigured() || !state.nerveConfigured || !isUnlocked())
  refs.resetSection.classList.toggle("hidden", !isConfigured() || !state.nerveConfigured)

  if (!isConfigured()) {
    refs.entriesList.innerHTML = ""
    return
  }

  prefillSuggestedWebsite()
  renderEntries()
}

function prefillSuggestedWebsite() {
  if (refs.entryWebsite.value.trim()) {
    return
  }

  const suggestedWebsite = suggestedWebsiteUrl()

  if (suggestedWebsite) {
    refs.entryWebsite.value = suggestedWebsite
  }
}

async function refreshNerveIndex() {
  try {
    setFeedback("Loading nerve...", "info")
    const data = await listEntries(state.settings)
    let entries = Array.isArray(data.entries) ? data.entries : []
    state.nerveConfigured = Boolean(data.nerve_configured)
    state.nerveVerifier = data.nerve_verifier || null

    if (state.nerveConfigured && state.passphrase) {
      await validateSavedPassphrase()
    }

    if (state.nerveConfigured && isUnlocked()) {
      entries = await hydrateEntryMetadata(entries)
    }

    state.entries = entries

    render()

    if (state.nerveConfigured && isUnlocked()) {
      setFeedback("Nerve unlocked for this browser session.", "success")
    } else {
      clearFeedback()
    }
  } catch (error) {
    render()
    setFeedback(error.message, "error")
  }
}

async function validateSavedPassphrase() {
  if (!state.nerveVerifier) {
    await clearStoredPassphrase()
    throw new Error("This server does not expose nerve verification metadata yet.")
  }

  try {
    const valid = await verifyPassphrase(state.nerveVerifier, state.passphrase)

    if (!valid) {
      throw new Error("Stored nerve passphrase is no longer valid.")
    }
  } catch (_error) {
    await clearStoredPassphrase()
    state.passphrase = ""
  }
}

async function clearStoredPassphrase() {
  await runtimeMessage({ type: MESSAGE_TYPES.CLEAR_SESSION_PASSPHRASE })
}

async function handleSetupSubmit(event) {
  event.preventDefault()

  const passphrase = refs.setupPassphrase.value.trim()
  const confirmation = refs.setupPassphraseConfirm.value.trim()

  try {
    if (passphrase.length < MIN_PASSPHRASE_LENGTH) {
      throw new Error(`Use a nerve passphrase with at least ${MIN_PASSPHRASE_LENGTH} characters.`)
    }

    if (passphrase !== confirmation) {
      throw new Error("Passphrase confirmation does not match.")
    }

    setBusy(refs.setupSubmitButton, true)
    const encryptedVerifier = await encryptValue(VERIFIER_TEXT, passphrase)
    await setupNerve(state.settings, encryptedVerifier)
    await runtimeMessage({ type: MESSAGE_TYPES.SET_SESSION_PASSPHRASE, passphrase })
    state.passphrase = passphrase
    refs.setupForm.reset()
    await refreshNerveIndex()
    setFeedback("Nerve configured and unlocked.", "success")
  } catch (error) {
    setFeedback(error.message, "error")
  } finally {
    setBusy(refs.setupSubmitButton, false)
  }
}

async function handleUnlockSubmit(event) {
  event.preventDefault()

  const passphrase = refs.unlockPassphrase.value.trim()

  try {
    if (!state.nerveVerifier) {
      throw new Error("Nerve verifier metadata is not available from the server.")
    }

    setBusy(refs.unlockSubmitButton, true)
    const valid = await verifyPassphrase(state.nerveVerifier, passphrase)

    if (!valid) {
      throw new Error("Incorrect nerve passphrase.")
    }

    await runtimeMessage({ type: MESSAGE_TYPES.SET_SESSION_PASSPHRASE, passphrase })
    state.passphrase = passphrase
    refs.unlockForm.reset()
    render()
    setFeedback("Nerve unlocked for this browser session.", "success")
  } catch (error) {
    setFeedback(error.message, "error")
  } finally {
    setBusy(refs.unlockSubmitButton, false)
  }
}

async function handleLock() {
  await clearStoredPassphrase()
  state.passphrase = ""
  render()
  setFeedback("Nerve locked.", "info")
}

async function handleDeleteNerve() {
  try {
    if (!state.nerveConfigured) {
      throw new Error("This nerve is not configured yet.")
    }

    const confirmed = window.confirm(
      "Delete your nerve and all saved entries? This cannot be undone."
    )

    if (!confirmed) {
      return
    }

    setBusy(refs.resetNerveButton, true)
    await deleteNerve(state.settings)
    await clearStoredPassphrase()

    state.passphrase = ""
    state.entries = []
    state.nerveConfigured = false
    state.nerveVerifier = null

    refs.unlockForm.reset()
    refs.createEntryForm.reset()
    refs.searchInput.value = ""

    render()
    setFeedback("Nerve deleted. Create a new passphrase to start again.", "success")
  } catch (error) {
    setFeedback(error.message, "error")
  } finally {
    setBusy(refs.resetNerveButton, false)
  }
}

function handleGeneratePassword() {
  refs.entryPassword.value = createPassword()
}

async function handleCreateEntrySubmit(event) {
  event.preventDefault()

  try {
    ensureUnlocked()

    const title = refs.entryTitle.value.trim()
    const loginUsername = refs.entryUsername.value.trim()
    const website = (refs.entryWebsite.value.trim() || suggestedWebsiteUrl() || "").trim()
    const password = refs.entryPassword.value
    const notes = refs.entryNotes.value.trim()

    if (!title) {
      throw new Error("Title is required.")
    }

    if (!password) {
      throw new Error("Password is required.")
    }

    setBusy(refs.createEntrySubmitButton, true)

    const metadata = { title, login_username: loginUsername, website }
    const encryptedMetadata = await encryptValue(
      JSON.stringify(metadata),
      state.passphrase,
      nerveMetadataAssociatedData()
    )
    const encryptedPassword = await encryptValue(
      password,
      state.passphrase,
      nerveEntryAssociatedData(metadata, "password")
    )
    const encryptedNotes = notes
      ? await encryptValue(notes, state.passphrase, nerveEntryAssociatedData(metadata, "notes"))
      : null

    await createEntry(state.settings, {
      title: "Encrypted entry",
      login_username: "",
      website: "",
      encrypted_metadata: encryptedMetadata,
      encrypted_password: encryptedPassword,
      encrypted_notes: encryptedNotes
    })

    refs.createEntryForm.reset()
    prefillSuggestedWebsite()
    await refreshNerveIndex()
    setFeedback("Nerve entry saved.", "success")
  } catch (error) {
    setFeedback(error.message, "error")
  } finally {
    setBusy(refs.createEntrySubmitButton, false)
  }
}

async function handleEntryAction(event) {
  const button = event.target.closest("[data-action]")

  if (!button) {
    return
  }

  const entryId = Number.parseInt(button.dataset.entryId || "", 10)
  const action = button.dataset.action
  const entry = state.entries.find((item) => item.id === entryId)

  if (!entry || Number.isNaN(entryId)) {
    return
  }

  try {
    setBusy(button, true)

    switch (action) {
      case "fill":
        await fillEntry(entry)
        break
      case "copy-password":
        await copyEntryPassword(entry)
        break
      case "copy-username":
        await copyUsername(entry)
        break
      default:
        break
    }
  } catch (error) {
    setFeedback(error.message, "error")
  } finally {
    setBusy(button, false)
  }
}

async function fillEntry(entry) {
  ensureUnlocked()

  if (!canFillCurrentTab()) {
    throw new Error("Open a normal website tab before autofill.")
  }

  confirmEntryOrigin(entry)

  const { password } = await loadDecryptedEntry(entry.id)
  const response = await sendMessageToTab(state.currentTab.id, {
    type: "fill_credentials",
    payload: {
      entryId: entry.id,
      username: entry.login_username || "",
      password
    }
  })

  if (!response?.ok) {
    throw new Error(response?.error || "Autofill failed on this page.")
  }

  const filledUsername = Boolean(response.result?.filled?.username)
  const filledPassword = Boolean(response.result?.filled?.password)
  let message = "Autofill completed."

  if (filledUsername && filledPassword) {
    message = "Username and password filled."
  } else if (filledPassword) {
    message = "Password filled."
  } else if (response.staged) {
    message = filledUsername
      ? "Username filled. Continue to the password step."
      : "Continue to the password step and Elektrine will fill it there."
  } else if (filledUsername) {
    message = "Username filled. Continue to the password step."
  }

  setFeedback(message, "success")
}

function confirmEntryOrigin(entry) {
  const currentHost = safeHost(state.currentTab?.url)
  const entryHost = safeHost(entry.website)

  if (!currentHost || !entryHost) {
    throw new Error("This entry does not have a website that can be matched to the current tab.")
  }

  if (currentHost === entryHost) {
    return
  }

  const related = currentHost.endsWith(`.${entryHost}`) || entryHost.endsWith(`.${currentHost}`)

  if (!related || !window.confirm(`Fill ${entryHost} credentials on ${currentHost}?`)) {
    throw new Error("Autofill cancelled for this site.")
  }
}

async function copyEntryPassword(entry) {
  ensureUnlocked()
  const { password } = await loadDecryptedEntry(entry.id)
  await navigator.clipboard.writeText(password)
  setFeedback("Password copied to clipboard.", "success")
}

async function copyUsername(entry) {
  if (!entry.login_username) {
    throw new Error("This entry does not have a username.")
  }

  await navigator.clipboard.writeText(entry.login_username)
  setFeedback("Username copied to clipboard.", "success")
}

async function loadDecryptedEntry(entryId) {
  const data = await getEntry(state.settings, entryId)
  const entry = await hydrateEntryMetadataValue(data.entry)

  if (!isClientPayload(entry?.encrypted_password)) {
    throw new Error("This entry is not stored in the current client-encrypted format.")
  }

  return {
    entry,
    password: await decryptValue(
      entry.encrypted_password,
      state.passphrase,
      nerveEntryAssociatedData(entry, "password")
    ),
    notes:
      entry.encrypted_notes && isClientPayload(entry.encrypted_notes)
        ? await decryptValue(
            entry.encrypted_notes,
            state.passphrase,
            nerveEntryAssociatedData(entry, "notes")
          )
        : ""
  }
}

async function hydrateEntryMetadata(entries) {
  return Promise.all(entries.map((entry) => hydrateEntryMetadataValue(entry)))
}

async function hydrateEntryMetadataValue(entry) {
  if (!entry || !isUnlocked() || !isClientPayload(entry.encrypted_metadata)) {
    return entry
  }

  try {
    const decrypted = await decryptValue(
      entry.encrypted_metadata,
      state.passphrase,
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

function ensureUnlocked() {
  if (!isUnlocked()) {
    throw new Error("Unlock your nerve first.")
  }
}

function renderEntries() {
  if (!isConfigured() || !state.nerveConfigured || !isUnlocked()) {
    refs.entriesList.innerHTML = ""
    return
  }

  const currentHost = safeHost(state.currentTab?.url)
  const query = refs.searchInput.value.trim().toLowerCase()

  const filteredEntries = state.entries
    .map((entry) => ({
      entry,
      matchScore: matchScore(entry, currentHost)
    }))
    .filter(({ entry }) => matchesQuery(entry, query))
    .sort((left, right) => {
      if (left.matchScore !== right.matchScore) {
        return right.matchScore - left.matchScore
      }

      return new Date(right.entry.inserted_at).getTime() - new Date(left.entry.inserted_at).getTime()
    })

  if (filteredEntries.length === 0) {
    const message = query
      ? "No nerve entries matched your search."
      : "No entries yet. Save one above to start autofilling."

    refs.entriesList.innerHTML = `<div class="empty-state"><p>${escapeHtml(message)}</p></div>`
    return
  }

  refs.entriesList.innerHTML = filteredEntries.map(renderEntryCard).join("")
}

function renderEntryCard({ entry, matchScore: entryMatchScore }) {
  const websiteHost = safeHost(entry.website)
  const fillDisabled = canFillCurrentTab() ? "" : "disabled"
  const badge = entryMatchScore > 0 ? '<span class="badge">Suggested</span>' : ""
  const websiteUrl = safeWebsiteUrl(entry.website)
  const website = websiteUrl
    ? `<a class="subtle" href="${escapeAttribute(websiteUrl)}" target="_blank" rel="noreferrer">${escapeHtml(websiteHost || websiteUrl)}</a>`
    : '<span class="subtle">No website saved</span>'
  const username = entry.login_username
    ? `<p class="entry-meta">${escapeHtml(entry.login_username)}</p>`
    : '<p class="entry-meta">No username saved</p>'

  return `
    <article class="entry-card">
      <div class="entry-top">
        <div>
          <h3 class="entry-title">${escapeHtml(entry.title)}</h3>
          ${username}
        </div>
        ${badge}
      </div>
      <div class="entry-top">
        ${website}
      </div>
      <div class="entry-actions">
        <button class="button" type="button" data-action="fill" data-entry-id="${entry.id}" ${fillDisabled}>Fill</button>
        <button class="button secondary" type="button" data-action="copy-password" data-entry-id="${entry.id}">Copy password</button>
        <button class="button secondary" type="button" data-action="copy-username" data-entry-id="${entry.id}">Copy username</button>
      </div>
    </article>
  `
}

function matchesQuery(entry, query) {
  if (!query) {
    return true
  }

  const haystack = [entry.title, entry.login_username, entry.website]
    .filter(Boolean)
    .join(" ")
    .toLowerCase()

  return haystack.includes(query)
}

function matchScore(entry, currentHost) {
  const entryHost = safeHost(entry.website)

  if (!currentHost || !entryHost) {
    return 0
  }

  if (currentHost === entryHost) {
    return 3
  }

  if (currentHost.endsWith(`.${entryHost}`) || entryHost.endsWith(`.${currentHost}`)) {
    return 2
  }

  if (currentHost.includes(entryHost) || entryHost.includes(currentHost)) {
    return 1
  }

  return 0
}

function suggestedWebsiteUrl() {
  try {
    const url = new URL(state.currentTab?.url || "")

    if (!["http:", "https:"].includes(url.protocol)) {
      return ""
    }

    return url.origin
  } catch (_error) {
    return ""
  }
}

function safeHost(value) {
  try {
    const url = new URL(value)
    return url.hostname
  } catch (_error) {
    return ""
  }
}

function safeWebsiteUrl(value) {
  try {
    const url = new URL(value)
    return ["http:", "https:"].includes(url.protocol) ? url.toString() : ""
  } catch (_error) {
    return ""
  }
}

function canFillCurrentTab() {
  return Boolean(state.currentTab?.id) && /^https?:\/\//.test(state.currentTab?.url || "")
}

function getActiveTab() {
  return new Promise((resolve) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      resolve(tabs?.[0] || null)
    })
  })
}

async function getRuntimePassphrase() {
  const response = await runtimeMessage({ type: MESSAGE_TYPES.GET_SESSION_PASSPHRASE })
  return response.passphrase || ""
}

function runtimeMessage(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(message, (response) => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message))
        return
      }

      if (!response?.ok) {
        reject(new Error(response?.error || "Extension request failed."))
        return
      }

      resolve(response)
    })
  })
}

function sendMessageToTab(tabId, message) {
  return new Promise((resolve, reject) => {
    chrome.tabs.sendMessage(tabId, message, (response) => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message))
        return
      }

      resolve(response)
    })
  })
}

function openOptionsPage() {
  chrome.runtime.openOptionsPage()
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

function escapeAttribute(value) {
  return escapeHtml(value)
}
