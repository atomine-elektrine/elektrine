import { listEntries, loginWithAccount, logoutWithAccount, normalizeServerUrl } from "./lib/api.js"
import { getSettings, saveSettings } from "./lib/storage.js"

const state = {
  settings: { serverUrl: "", apiToken: "" }
}
const MESSAGE_TYPES = {
  CLEAR_SESSION_PASSPHRASE: "vault:clear-session-passphrase"
}

const refs = {}

document.addEventListener("DOMContentLoaded", init)

async function init() {
  captureRefs()
  bindEvents()

  state.settings = await getSettings()
  refs.serverUrl.value = state.settings.serverUrl

  renderConnectionState()
}

function captureRefs() {
  refs.serverUrl = document.querySelector("#serverUrl")
  refs.accountUsername = document.querySelector("#accountUsername")
  refs.accountPassword = document.querySelector("#accountPassword")
  refs.signInButton = document.querySelector("#signInButton")
  refs.testButton = document.querySelector("#testButton")
  refs.signOutButton = document.querySelector("#signOutButton")
  refs.clearPassphraseButton = document.querySelector("#clearPassphraseButton")
  refs.connectionSummary = document.querySelector("#connectionSummary")
  refs.statusMessage = document.querySelector("#statusMessage")
}

function bindEvents() {
  refs.signInButton.addEventListener("click", handleSignIn)
  refs.testButton.addEventListener("click", handleTest)
  refs.signOutButton.addEventListener("click", handleSignOut)
  refs.clearPassphraseButton.addEventListener("click", handleClearPassphrase)
}

function setStatus(message, type = "info") {
  refs.statusMessage.textContent = message
  refs.statusMessage.className = `feedback ${type}`
}

function setBusy(button, busy) {
  button.disabled = busy
}

function currentServerUrl() {
  return refs.serverUrl.value.trim()
}

function hasStoredSession() {
  return Boolean(state.settings.apiToken)
}

function renderConnectionState() {
  const serverUrl = currentServerUrl() || state.settings.serverUrl

  if (hasStoredSession()) {
    refs.connectionSummary.textContent = serverUrl
      ? `Signed in on this browser. Current server: ${serverUrl}`
      : "Signed in on this browser."
  } else {
    refs.connectionSummary.textContent = "Not signed in on this browser yet."
  }

  refs.testButton.disabled = !hasStoredSession()
  refs.signOutButton.disabled = !hasStoredSession()
}

async function handleSignIn() {
  const serverUrl = currentServerUrl()
  const username = refs.accountUsername.value.trim()
  const password = refs.accountPassword.value

  try {
    normalizeServerUrl(serverUrl)

    if (!username || !password) {
      throw new Error("Username and password are required.")
    }

    setBusy(refs.signInButton, true)
    const result = await loginWithAccount(serverUrl, username, password)

    state.settings = {
      serverUrl,
      apiToken: result.token
    }

    await saveSettings(state.settings)

    refs.accountPassword.value = ""
    renderConnectionState()
    setStatus(`Signed in as ${result.user?.username || username}.`, "success")
  } catch (error) {
    setStatus(error.message, "error")
  } finally {
    setBusy(refs.signInButton, false)
  }
}

async function handleTest() {
  const serverUrl = currentServerUrl()

  try {
    normalizeServerUrl(serverUrl)

    if (!hasStoredSession()) {
      throw new Error("Sign in with your account first.")
    }

    setBusy(refs.testButton, true)
    const settings = {
      serverUrl,
      apiToken: state.settings.apiToken
    }
    const data = await listEntries(settings)

    state.settings = settings
    await saveSettings(state.settings)
    renderConnectionState()

    const configured = data.vault_configured ? "configured" : "not configured yet"
    setStatus(`Connected successfully. Vault is ${configured}.`, "success")
  } catch (error) {
    setStatus(error.message, "error")
  } finally {
    setBusy(refs.testButton, false)
  }
}

async function handleSignOut() {
  const serverUrl = currentServerUrl()

  try {
    setBusy(refs.signOutButton, true)
    if (state.settings.apiToken) {
      await logoutWithAccount(state.settings)
    }
    await runtimeMessage({ type: MESSAGE_TYPES.CLEAR_SESSION_PASSPHRASE })

    state.settings = {
      serverUrl,
      apiToken: ""
    }

    await saveSettings(state.settings)
    refs.accountPassword.value = ""
    renderConnectionState()
    setStatus("Signed out successfully.", "success")
  } catch (error) {
    setStatus(error.message, "error")
  } finally {
    setBusy(refs.signOutButton, false)
  }
}

async function handleClearPassphrase() {
  try {
    setBusy(refs.clearPassphraseButton, true)
    await runtimeMessage({ type: MESSAGE_TYPES.CLEAR_SESSION_PASSPHRASE })
    setStatus("Session passphrase cleared.", "success")
  } catch (error) {
    setStatus(error.message, "error")
  } finally {
    setBusy(refs.clearPassphraseButton, false)
  }
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
