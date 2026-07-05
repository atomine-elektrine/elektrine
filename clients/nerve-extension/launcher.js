import { createKairoSource, listEntries } from "./lib/api.js"
import { kairoErrorMessage, kairoSourceAttrs } from "./lib/kairo_capture.js"
import { getSettings, saveSettings } from "./lib/storage.js"
import { applyTheme } from "./lib/theme.js"

const state = {
  settings: { serverUrl: "", apiToken: "", theme: null },
  currentTab: null,
  action: "manager"
}

const refs = {}

document.addEventListener("DOMContentLoaded", init)

async function init() {
  captureRefs()
  bindEvents()

  state.currentTab = await getActiveTab()
  state.settings = await getSettings()
  applyTheme(state.settings)
  renderCurrentSite()

  await refreshStatus()
}

function captureRefs() {
  refs.title = document.querySelector("#launcherTitle")
  refs.summary = document.querySelector("#launcherSummary")
  refs.currentSiteLabel = document.querySelector("#currentSiteLabel")
  refs.feedback = document.querySelector("#feedback")
  refs.captureButton = document.querySelector("#captureButton")
  refs.captureSummary = document.querySelector("#captureSummary")
  refs.primaryButton = document.querySelector("#primaryButton")
  refs.openOptionsButton = document.querySelector("#openOptionsButton")
}

function bindEvents() {
  refs.captureButton.addEventListener("click", handleCapture)
  refs.primaryButton.addEventListener("click", handlePrimaryAction)
  refs.openOptionsButton.addEventListener("click", openOptionsPage)
}

async function refreshStatus() {
  if (!state.settings.serverUrl || !state.settings.apiToken) {
    renderState({
      title: "Connect Nerve",
      summary: "Connect your Elektrine account before using passwords in this browser.",
      action: "settings",
      button: "Connect account"
    })
    renderCaptureState(false, "Connect your account to capture into Kairo.")
    return
  }

  try {
    const data = await listEntries(state.settings)

    state.settings = {
      ...state.settings,
      theme: data.theme || state.settings.theme || null
    }
    await saveSettings(state.settings)
    applyTheme(state.settings)

    if (!data.master_configured) {
      renderState({
        title: "Enable Account-Password Encryption",
        summary: "Set up encrypted data on Elektrine so your account password can unlock Nerve.",
        action: "encrypted-data",
        button: "Set up encryption"
      })
      renderCaptureState(true)
      return
    }

    renderState({
      title: "Open Nerve",
      summary: "Open the manager, then unlock Nerve for this session.",
      action: "manager",
      button: "Open Nerve"
    })
    renderCaptureState(true)
  } catch (error) {
    renderState({
      title: "Connection Problem",
      summary: "Open settings to check your server and sign-in session.",
      action: "settings",
      button: "Open Settings"
    })
    renderCaptureState(false, "Fix the extension connection before capturing.")
    setFeedback(error.message, "error")
  }
}

function renderState({ title, summary, action, button }) {
  state.action = action
  refs.title.textContent = title
  refs.summary.textContent = summary
  refs.primaryButton.textContent = button
}

function renderCurrentSite() {
  refs.currentSiteLabel.textContent = safeHost(state.currentTab?.url) || "No fill target"
}

function renderCaptureState(enabled, summary = null) {
  refs.captureButton.disabled = !enabled || !capturableTab(state.currentTab)
  refs.captureSummary.textContent =
    summary ||
    (capturableTab(state.currentTab)
      ? "Selected text is saved as a note. Otherwise the page URL is saved."
      : "Open an http or https page before capturing.")
}

function setFeedback(message, type = "info") {
  refs.feedback.textContent = message
  refs.feedback.className = `feedback launcher-feedback ${type}`
}

async function handleCapture() {
  try {
    if (!state.settings.serverUrl || !state.settings.apiToken) {
      throw new Error("Connect your Elektrine account before capturing.")
    }

    if (!capturableTab(state.currentTab)) {
      throw new Error("Open an http or https page before capturing.")
    }

    setBusy(refs.captureButton, true)
    setFeedback("Capturing to Kairo...", "info")

    const capture = await getPageCapture(state.currentTab)
    const data = await createKairoSource(state.settings, kairoSourceAttrs(capture))
    const mode = capture.selectionText ? "selection" : "page"
    const title = data?.source?.title || capture.title || "Captured page"

    setFeedback(`Saved ${mode} to Kairo: ${title}`, "success")
  } catch (error) {
    setFeedback(kairoErrorMessage(error), "error")
  } finally {
    setBusy(refs.captureButton, false)
  }
}

function setBusy(button, busy) {
  button.disabled = busy
}

async function getPageCapture(tab) {
  const fallback = fallbackCapture(tab)

  try {
    const response = await sendTabMessage(tab.id, { type: "kairo:get-page-capture" })

    if (response?.ok && response.capture) {
      return {
        ...fallback,
        ...response.capture,
        url: response.capture.url || fallback.url,
        title: response.capture.title || fallback.title
      }
    }
  } catch (_error) {
    // Some pages cannot run extension content scripts; saving the URL is still useful.
  }

  return fallback
}

function fallbackCapture(tab) {
  return {
    url: tab?.url || "",
    title: tab?.title || safeHost(tab?.url) || "Captured page",
    selectionText: ""
  }
}

function sendTabMessage(tabId, message) {
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

function handlePrimaryAction() {
  switch (state.action) {
    case "settings":
      openOptionsPage()
      break
    case "encrypted-data":
      openMasterPasswordSettings()
      break
    default:
      openManagerPage()
      break
  }
}

function openManagerPage() {
  const params = new URLSearchParams()

  if (state.currentTab?.id) {
    params.set("tabId", String(state.currentTab.id))
  }

  chrome.tabs.create({ url: chrome.runtime.getURL(`manager.html?${params.toString()}`) })
  window.close()
}

function openOptionsPage() {
  chrome.runtime.openOptionsPage()
  window.close()
}

function openMasterPasswordSettings() {
  if (!state.settings.serverUrl) {
    openOptionsPage()
    return
  }

  chrome.tabs.create({ url: `${state.settings.serverUrl.replace(/\/+$/, "")}/account/encrypted-data` })
  window.close()
}

function getActiveTab() {
  return new Promise((resolve) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      resolve(tabs?.[0] || null)
    })
  })
}

function capturableTab(tab) {
  if (!tab?.id || !tab.url) {
    return false
  }

  try {
    return ["http:", "https:"].includes(new URL(tab.url).protocol)
  } catch (_error) {
    return false
  }
}

function safeHost(value) {
  try {
    const url = new URL(value)
    return ["http:", "https:"].includes(url.protocol) ? url.hostname : ""
  } catch (_error) {
    return ""
  }
}
