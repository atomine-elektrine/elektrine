import { listEntries, logoutWithAccount, normalizeServerUrl } from "./lib/api.js"
import { getSettings, saveSettings } from "./lib/storage.js"
import { applyTheme } from "./lib/theme.js"

const state = {
  settings: { serverUrl: "", apiToken: "" }
}
const MESSAGE_TYPES = {
  CLEAR_SESSION_PASSPHRASE: "nerve:clear-session-passphrase"
}

const refs = {}

document.addEventListener("DOMContentLoaded", init)

async function init() {
  captureRefs()
  bindEvents()

  state.settings = await getSettings()

  const callback = parseConnectCallback(window.location.href)
  if (callback) {
    state.settings = {
      serverUrl: state.settings.serverUrl,
      apiToken: callback.token,
      theme: callback.theme
    }
    await saveSettings(state.settings)
    window.history.replaceState(null, "", window.location.pathname)
    setStatus(`Connected as ${callback.username || "your account"}.`, "success")
  }

  applyTheme(state.settings)
  refs.serverUrl.value = state.settings.serverUrl

  renderConnectionState()
}

function captureRefs() {
  refs.serverUrl = document.querySelector("#serverUrl")
  refs.connectButton = document.querySelector("#connectButton")
  refs.testButton = document.querySelector("#testButton")
  refs.signOutButton = document.querySelector("#signOutButton")
  refs.clearPassphraseButton = document.querySelector("#clearPassphraseButton")
  refs.connectionSummary = document.querySelector("#connectionSummary")
  refs.statusMessage = document.querySelector("#statusMessage")
}

function bindEvents() {
  refs.connectButton.addEventListener("click", handleConnect)
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

async function handleConnect() {
  const serverUrl = currentServerUrl()

  try {
    const normalizedServerUrl = normalizeServerUrl(serverUrl)
    const flowState = randomState()
    const returnTo = identityRedirectUrl() || chrome.runtime.getURL("options.html")
    const connectUrl = websiteConnectUrl(normalizedServerUrl, returnTo, flowState)

    state.settings = {
      serverUrl: normalizedServerUrl,
      apiToken: "",
      theme: null
    }
    await saveSettings(state.settings)
    applyTheme(state.settings)
    refs.serverUrl.value = normalizedServerUrl

    setBusy(refs.connectButton, true)
    setStatus("Continue in the website window to approve the extension.", "info")

    const callback = await connectViaWebsite(normalizedServerUrl, connectUrl, flowState)

    state.settings = {
      serverUrl: normalizedServerUrl,
      apiToken: callback.token,
      theme: callback.theme
    }
    await saveSettings(state.settings)
    applyTheme(state.settings)

    renderConnectionState()
    setStatus(`Connected as ${callback.username || "your account"}.`, "success")
  } catch (error) {
    setStatus(error.message, "error")
  } finally {
    setBusy(refs.connectButton, false)
  }
}

async function handleTest() {
  const serverUrl = currentServerUrl()

  try {
    const normalizedServerUrl = normalizeServerUrl(serverUrl)

    if (!hasStoredSession()) {
      throw new Error("Sign in with your account first.")
    }

    setBusy(refs.testButton, true)
    const settings = {
      serverUrl: normalizedServerUrl,
      apiToken: state.settings.apiToken
    }
    const data = await listEntries(settings)

    state.settings = {
      ...settings,
      theme: data.theme || state.settings.theme || null
    }
    await saveSettings(state.settings)
    applyTheme(state.settings)
    refs.serverUrl.value = normalizedServerUrl
    renderConnectionState()

    const configured = data.master_configured
      ? "encrypted data enabled"
      : "encrypted data not enabled yet"
    setStatus(`Connected successfully. ${configured}.`, "success")
  } catch (error) {
    setStatus(error.message, "error")
  } finally {
    setBusy(refs.testButton, false)
  }
}

async function handleSignOut() {
  const serverUrl = currentServerUrl()

  try {
    const normalizedServerUrl = serverUrl ? normalizeServerUrl(serverUrl) : state.settings.serverUrl
    setBusy(refs.signOutButton, true)
    if (state.settings.apiToken) {
      await logoutWithAccount(state.settings)
    }
    await runtimeMessage({ type: MESSAGE_TYPES.CLEAR_SESSION_PASSPHRASE })

    state.settings = {
      serverUrl: normalizedServerUrl,
      apiToken: "",
      theme: null
    }

    await saveSettings(state.settings)
    applyTheme(state.settings)
    refs.serverUrl.value = normalizedServerUrl
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
    setStatus("Account-password session cleared.", "success")
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

function websiteConnectUrl(serverUrl, returnTo, stateValue) {
  const url = new URL("/account/nerve/extension/connect", serverUrl)
  url.searchParams.set("return_to", returnTo)
  url.searchParams.set("state", stateValue)
  return url.toString()
}

function identityRedirectUrl() {
  return chrome.identity?.getRedirectURL ? chrome.identity.getRedirectURL("nerve") : null
}

function launchConnectFlow(url) {
  if (chrome.identity?.launchWebAuthFlow) {
    return new Promise((resolve, reject) => {
      chrome.identity.launchWebAuthFlow({ url, interactive: true }, (responseUrl) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message))
          return
        }

        if (!responseUrl) {
          reject(new Error("Website connection was cancelled."))
          return
        }

        resolve(responseUrl)
      })
    })
  }

  chrome.tabs.create({ url })
  throw new Error("Finish the website approval, then return to this settings page.")
}

async function connectViaWebsite(serverUrl, connectUrl, flowState) {
  if (usesLocalHttp(serverUrl)) {
    return launchPairingFlow(serverUrl, flowState)
  }

  try {
    const callbackUrl = await launchConnectFlow(connectUrl)
    const callback = parseConnectCallback(callbackUrl, flowState)

    if (!callback) {
      throw new Error("Website did not return an extension token.")
    }

    return callback
  } catch (error) {
    if (shouldUsePairingFallback(error)) {
      setStatus("Opening the website in a normal tab to finish connecting.", "info")
      return launchPairingFlow(serverUrl, flowState)
    }

    throw error
  }
}

async function launchPairingFlow(serverUrl, flowState) {
  const pairingId = randomHex(16)
  const pairingSecret = randomHex(32)
  const connectUrl = websitePairingUrl(serverUrl, pairingId, pairingSecret, flowState)

  chrome.tabs.create({ url: connectUrl })
  return pollPairingStatus(serverUrl, pairingId, pairingSecret)
}

async function pollPairingStatus(serverUrl, pairingId, pairingSecret) {
  const deadline = Date.now() + 5 * 60 * 1000
  const statusUrl = new URL(`/api/ext/v1/nerve/extension/connect/${pairingId}`, serverUrl)
  statusUrl.searchParams.set("secret", pairingSecret)

  while (Date.now() < deadline) {
    await delay(1500)

    const response = await fetch(statusUrl.toString(), {
      headers: { Accept: "application/json" }
    })

    if (response.status === 202) {
      continue
    }

    const payload = await response.json().catch(() => null)

    if (!response.ok) {
      throw new Error(payload?.error || `Connection failed (${response.status}).`)
    }

    if (payload?.status === "connected" && payload.token) {
      return {
        token: payload.token,
        username: payload.user?.username || "",
        theme: payload.user?.theme || null
      }
    }
  }

  throw new Error("Website connection timed out. Try connecting again.")
}

function websitePairingUrl(serverUrl, pairingId, pairingSecret, stateValue) {
  const url = new URL("/account/nerve/extension/connect", serverUrl)
  url.searchParams.set("pairing_id", pairingId)
  url.searchParams.set("pairing_secret", pairingSecret)
  url.searchParams.set("state", stateValue)
  return url.toString()
}

function shouldUsePairingFallback(error) {
  const message = String(error?.message || "")
  return /authorization page could not be loaded|could not be loaded|failed to fetch|network/i.test(message)
}

function usesLocalHttp(serverUrl) {
  try {
    const url = new URL(serverUrl)
    return url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
  } catch (_error) {
    return false
  }
}

function parseConnectCallback(url, expectedState = null) {
  let parsedUrl

  try {
    parsedUrl = new URL(url)
  } catch (_error) {
    return null
  }

  const params = new URLSearchParams(parsedUrl.hash.replace(/^#/, ""))
  const token = params.get("token")

  if (!token) {
    return null
  }

  if (expectedState && params.get("state") !== expectedState) {
    throw new Error("Website connection state did not match. Try connecting again.")
  }

  let theme = null

  try {
    theme = JSON.parse(params.get("theme") || "null")
  } catch (_error) {
    theme = null
  }

  return {
    token,
    username: params.get("username") || "",
    theme
  }
}

function randomState() {
  return randomHex(16)
}

function randomHex(byteCount) {
  const bytes = new Uint8Array(byteCount)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
