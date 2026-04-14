/**
 * Main Application Entry Point
 * Initializes Phoenix LiveView and all UI modules
 */

// Phoenix and LiveView core
import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Import hooks
import { Hooks } from "./hooks"
import { initTimezoneDetectors } from "./hooks/form_hooks"
import { initBackupCodesPrinters } from "./hooks/ui_hooks"
import { initPrivateMailboxAuthForms } from "./hooks/mailbox_private_storage_hooks"

// Import utilities
import {
  initEmailSelection,
  initDropdownManagement,
  initClipboardHandlers
} from "./utils"
import { submitFormPreservingEvents } from "./utils/form_submission"

// Import UI modules
import { initModalControls } from "./modal_controls"
import { initMarkdownToolbar } from "./markdown_toolbar"
import { initFormHelpers } from "./form_helpers"
import { initEmailRaw } from "./email_raw"
import "./hashtag_links" // self-initializes
import { initCursorGlow, destroyCursorGlow } from "./cursor_glow"
import { initBlinkenlights, checkBlinkenlights } from "./blinkenlights"
import { initMarkdownEditor } from "./markdown_editor"
import { initLiveClock } from "./live_clock"
import { initIpLookup } from "./ip_lookup"
import { initTaglineCycler } from "./tagline_cycler"
import { initProfileStatic } from "./profile_static"
import { initAdminSecurity } from "./admin_security"

// Import shared modules
import { FlashMessageManager } from "./flash_message_manager"
import {
  showNotification,
  showLoadingNotification,
  showUndoNotification,
  showConfirmNotification,
  showKeyboardShortcuts
} from "./notification_system"
import { insertMarkdownFormat, toggleMarkdownPreview, markdownToHtml } from "./markdown_helpers"

// ============================================================================
// Global Exports (for compatibility with inline scripts and non-module code)
// ============================================================================

window.FlashMessageManager = FlashMessageManager
window.showNotification = showNotification
window.showLoadingNotification = showLoadingNotification
window.showUndoNotification = showUndoNotification
window.showConfirmNotification = showConfirmNotification
window.showKeyboardShortcuts = showKeyboardShortcuts
window.insertMarkdownFormat = insertMarkdownFormat
window.toggleMarkdownPreview = toggleMarkdownPreview
window.markdownToHtml = markdownToHtml

// ============================================================================
// LiveSocket Configuration
// ============================================================================

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
  heartbeatIntervalMs: 15000
})

// ============================================================================
// Progress Bar Configuration
// ============================================================================

function currentThemePrimary() {
  const primary = getComputedStyle(document.documentElement)
    .getPropertyValue("--color-primary")
    .trim()

  return primary || "#8a7cc2"
}

function currentThemePrimaryShadow() {
  const primary = currentThemePrimary()

  if (primary.startsWith("#")) {
    let hex = primary.slice(1)

    if (hex.length === 3) {
      hex = hex.split("").map((char) => char + char).join("")
    }

    if (hex.length === 6) {
      const red = parseInt(hex.slice(0, 2), 16)
      const green = parseInt(hex.slice(2, 4), 16)
      const blue = parseInt(hex.slice(4, 6), 16)

      return `rgba(${red}, ${green}, ${blue}, 0.28)`
    }
  }

  return primary
}

function syncTopbarTheme() {
  topbar.config({
    barColors: { 0: currentThemePrimary() },
    shadowColor: currentThemePrimaryShadow()
  })
}

window.addEventListener("phx:page-loading-start", () => {
  syncTopbarTheme()
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", () => {
  topbar.hide()
  checkBlinkenlights()
  initProfileStatic()
  initAutoDismissFlashes()
  initTimezoneDetectors()
  initBackupCodesPrinters()
  initPrivateMailboxAuthForms()
  syncCursorGlowForRoute()
  initAutoSearchClearButtons()
  initAdminSecurity()
})

// ============================================================================
// Global Event Handlers
// ============================================================================

// Keyboard shortcuts modal
window.addEventListener('phx:show-keyboard-shortcuts', showKeyboardShortcuts)

// Scroll to top (used by new posts button)
window.addEventListener("scroll-to-top", () => {
  window.scrollTo({ top: 0, behavior: "instant" })
})

function initAutoDismissFlashes(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === 'function' ? rootCandidate : document

  root.querySelectorAll('[data-flash-auto-dismiss="true"]').forEach((flashEl) => {
    bindFlashDismissButton(flashEl)
    scheduleFlashAutoDismiss(flashEl)
  })
}

const flashAutoDismissTimers = new WeakMap()

function clearFlashAutoDismissTimer(flashEl) {
  const timerId = flashAutoDismissTimers.get(flashEl)
  if (timerId) {
    window.clearTimeout(timerId)
    flashAutoDismissTimers.delete(flashEl)
  }
}

function dismissFlashElement(flashEl) {
  if (!flashEl || flashEl.dataset.flashDismissed === 'true') return

  flashEl.dataset.flashDismissed = 'true'
  clearFlashAutoDismissTimer(flashEl)
  flashEl.classList.add('is-dismissing')

  const exitMsRaw = parseInt(flashEl.dataset.flashExitMs || '260', 10)
  const exitMs = Number.isFinite(exitMsRaw) ? exitMsRaw : 260

  window.setTimeout(() => {
    if (flashEl.parentNode) {
      flashEl.remove()
    }
  }, Math.max(exitMs, 0) + 40)
}

function bindFlashDismissButton(flashEl) {
  if (flashEl.dataset.flashDismissBound === 'true') return

  const dismissBtn = flashEl.querySelector('[data-flash-dismiss="true"]')
  if (!dismissBtn) return

  dismissBtn.addEventListener('click', () => {
    dismissFlashElement(flashEl)
  })

  flashEl.dataset.flashDismissBound = 'true'
}

function scheduleFlashAutoDismiss(flashEl) {
  if (flashEl.dataset.flashTimerInitialized === 'true') return
  flashEl.dataset.flashTimerInitialized = 'true'

  const timeoutMsRaw = parseInt(flashEl.dataset.flashAutoDismissMs || '5000', 10)
  const timeoutMs = Number.isFinite(timeoutMsRaw) ? timeoutMsRaw : 5000

  const timerId = window.setTimeout(() => {
    if (!document.body.contains(flashEl)) {
      clearFlashAutoDismissTimer(flashEl)
      return
    }

    const dismissBtn = flashEl.querySelector('[data-flash-dismiss="true"]')
    if (dismissBtn) {
      dismissBtn.click()
    } else {
      dismissFlashElement(flashEl)
    }
  }, timeoutMs)

  flashAutoDismissTimers.set(flashEl, timerId)
}

window.dismissFlashElement = dismissFlashElement
window.initAutoDismissFlashes = initAutoDismissFlashes

function shouldEnableCursorGlow(pathname = window.location.pathname) {
  return !/^\/chat(?:\/|$)/.test(pathname)
}

function syncCursorGlowForRoute() {
  if (shouldEnableCursorGlow()) {
    initCursorGlow()
  } else {
    destroyCursorGlow()
  }
}

const SEARCH_CLEAR_SELECTOR = '[data-search-clear]'
const SEARCH_INPUT_SELECTOR = [
  '[data-search-input]',
  'input[type="search"]',
  'input[name="q"]',
  'input[name="query"]',
  'input[name$="[query]"]',
  'input[name="search"]'
].join(', ')

let searchClearButtonsInitialized = false
let searchClearInputIdCounter = 0
let searchClearObserverInitialized = false

function isClearableSearchInput(candidate) {
  if (!(candidate instanceof HTMLInputElement)) return false
  if (candidate.disabled || candidate.readOnly) return false

  const inputType = (candidate.getAttribute('type') || 'text').toLowerCase()
  return inputType === 'text' || inputType === 'search'
}

function ensureSearchInputId(input) {
  if (!input.id) {
    searchClearInputIdCounter += 1
    input.id = `search-clear-input-${searchClearInputIdCounter}`
  }

  return input.id
}

function getSearchInputScopes(input) {
  return [
    input.closest('label.input'),
    input.parentElement
  ].filter(Boolean)
}

function hasLocalSearchClearControl(input) {
  const inputId = ensureSearchInputId(input)

  return getSearchInputScopes(input).some((scope) => {
    const controls = scope.querySelectorAll(`${SEARCH_CLEAR_SELECTOR}, .search-clear-auto`)

    return Array.from(controls).some((control) => {
      if (control === input) return false

      const target = control.getAttribute('data-search-clear-target')
      return !target || target === `#${inputId}`
    })
  })
}

function getSearchClearPlacement(input) {
  const labelContainer = input.closest('label.input')
  if (labelContainer && labelContainer.contains(input)) {
    return { mode: 'label', container: labelContainer }
  }

  const parent = input.parentElement
  if (!parent) return null

  if (parent.classList.contains('join')) {
    return { mode: 'join', container: parent }
  }

  if (parent.classList.contains('relative')) {
    return { mode: 'overlay', container: parent }
  }

  if (parent.classList.contains('flex') || parent.tagName === 'FORM') {
    return { mode: 'inline', container: parent }
  }

  return { mode: 'overlay', container: parent }
}

function updateAutoSearchClearButton(input, button) {
  button.hidden = !isClearableSearchInput(input) || input.value === ''
}

function getSearchClearTrailingWidth(input) {
  const parent = input.parentElement
  if (!parent) return 0

  let trailingWidth = 0
  let sibling = input.nextElementSibling

  while (sibling) {
    if (!sibling.hidden) {
      trailingWidth += sibling.getBoundingClientRect().width
    }

    sibling = sibling.nextElementSibling
  }

  return trailingWidth
}

function searchClearIconSize(input) {
  if (input.classList.contains('input-xs')) return '12'
  if (input.classList.contains('input-sm')) return '12'
  if (input.classList.contains('input-lg')) return '20'
  return '16'
}

function createSearchClearIcon(input) {
  const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path')
  const size = searchClearIconSize(input)

  icon.setAttribute('xmlns', 'http://www.w3.org/2000/svg')
  icon.setAttribute('viewBox', '0 0 24 24')
  icon.setAttribute('fill', 'none')
  icon.setAttribute('stroke', 'currentColor')
  icon.setAttribute('stroke-width', '1.8')
  icon.setAttribute('width', size)
  icon.setAttribute('height', size)
  icon.setAttribute('aria-hidden', 'true')

  path.setAttribute('stroke-linecap', 'round')
  path.setAttribute('stroke-linejoin', 'round')
  path.setAttribute('d', 'M6 18 18 6M6 6l12 12')

  icon.appendChild(path)

  return icon
}

function clearSearchInput(clearTrigger) {
  const input = resolveSearchInput(clearTrigger)

  if (!isClearableSearchInput(input) || input.value === '') return input

  input.value = ''
  input.dispatchEvent(new Event('input', { bubbles: true }))
  return input
}

function createAutoSearchClearButton(input) {
  const placement = getSearchClearPlacement(input)
  if (!placement) return null

  const inputId = ensureSearchInputId(input)
  const button = document.createElement('button')
  button.type = 'button'
  button.setAttribute('aria-label', 'Clear search')
  button.setAttribute('title', 'Clear search')
  button.setAttribute('data-search-clear', 'true')
  button.setAttribute('data-search-clear-target', `#${inputId}`)
  button.setAttribute('data-search-clear-mode', 'auto')
  button.appendChild(createSearchClearIcon(input))

  if (placement.mode === 'label') {
    button.className = 'search-clear-auto text-base-content/60 hover:text-base-content shrink-0'
    placement.container.appendChild(button)
  } else if (placement.mode === 'join') {
    placement.container.classList.add('relative')
    input.classList.add('search-clear-input')
    button.className =
      'search-clear-auto search-clear-overlay text-base-content/60 hover:text-base-content'
    button.style.right = `${getSearchClearTrailingWidth(input) + 8}px`
    placement.container.appendChild(button)
  } else if (placement.mode === 'inline') {
    button.className =
      'search-clear-auto search-clear-inline text-base-content/60 hover:text-base-content'
    input.insertAdjacentElement('afterend', button)
  } else {
    placement.container.classList.add('relative')
    input.classList.add('search-clear-input')
    button.className =
      'search-clear-auto search-clear-overlay text-base-content/60 hover:text-base-content'
    placement.container.appendChild(button)
  }

  const syncButton = () => updateAutoSearchClearButton(input, button)
  input.addEventListener('input', syncButton)
  input.addEventListener('change', syncButton)

  updateAutoSearchClearButton(input, button)

  return button
}

function initAutoSearchClearButtons(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === 'function' ? rootCandidate : document

  root.querySelectorAll(SEARCH_INPUT_SELECTOR).forEach((input) => {
    if (!isClearableSearchInput(input)) return
    if (input.dataset.searchClearEnhanced === 'true') return
    if (hasLocalSearchClearControl(input)) return

    const button = createAutoSearchClearButton(input)
    if (!button) return

    input.dataset.searchClearEnhanced = 'true'
  })
}

function initSearchClearObserver() {
  if (searchClearObserverInitialized) return
  if (!document.body) return

  searchClearObserverInitialized = true

  const observer = new MutationObserver(() => initAutoSearchClearButtons(document))
  observer.observe(document.body, { childList: true, subtree: true })
}

function resolveSearchInput(clearTrigger) {
  const explicitSelector = clearTrigger.getAttribute('data-search-clear-target')
  if (explicitSelector) return document.querySelector(explicitSelector)

  const activeElement = document.activeElement
  if (isClearableSearchInput(activeElement)) return activeElement

  const scopes = [
    clearTrigger.closest('label'),
    clearTrigger.parentElement,
    clearTrigger.closest('form')
  ].filter(Boolean)

  for (const scope of scopes) {
    const input = scope.querySelector(SEARCH_INPUT_SELECTOR)
    if (isClearableSearchInput(input)) return input
  }

  return null
}

function initSearchClearButtons() {
  if (searchClearButtonsInitialized) return
  searchClearButtonsInitialized = true

  document.addEventListener('pointerdown', (event) => {
    const clearTrigger = event.target.closest(SEARCH_CLEAR_SELECTOR)
    if (!clearTrigger) return

    clearSearchInput(clearTrigger)
  })

  document.addEventListener('click', (event) => {
    const clearTrigger =
      event.target.closest(`${SEARCH_CLEAR_SELECTOR}[data-search-clear-mode="auto"]`)

    if (!clearTrigger) return

    event.preventDefault()

    const input = clearSearchInput(clearTrigger) || resolveSearchInput(clearTrigger)
    if (!isClearableSearchInput(input)) return

    const form = input.form || clearTrigger.closest('form')

    if (form && !form.hasAttribute('phx-change') && !input.hasAttribute('phx-change')) {
      submitFormPreservingEvents(form)
    }

    input.focus()
  })
}

initSearchClearButtons()
initAutoSearchClearButtons()
initSearchClearObserver()

// ============================================================================
// DOM Ready Initialization
// ============================================================================

document.addEventListener('DOMContentLoaded', () => {
  // Initialize utility handlers
  initEmailSelection()
  initDropdownManagement()
  initClipboardHandlers()
  initAutoDismissFlashes()
  initTimezoneDetectors()
  initBackupCodesPrinters()
  initPrivateMailboxAuthForms()
  syncCursorGlowForRoute()
  initAutoSearchClearButtons()
  initSearchClearObserver()

  // Initialize UI modules
  initBlinkenlights()
  initMarkdownEditor()
  initLiveClock()
  initTaglineCycler()
  initModalControls()
  initMarkdownToolbar()
  initFormHelpers()
  initEmailRaw()
  initIpLookup()
  initProfileStatic()
  initAdminSecurity()

  // Auto-print functionality
  const body = document.querySelector('body[data-auto-print="true"]')
  if (body) {
    window.print()
  }

  // Error page actions
  const goBackBtn = document.querySelector('[data-action="go-back"]')
  if (goBackBtn) {
    goBackBtn.addEventListener('click', () => window.history.back())
  }

  const reloadBtn = document.querySelector('[data-action="reload-page"]')
  if (reloadBtn) {
    reloadBtn.addEventListener('click', () => window.location.reload())
  }
})

// ============================================================================
// Connect LiveSocket
// ============================================================================

liveSocket.connect()

// Ensure LiveSocket reconnects when returning from static pages (e.g., profile subdomains)
// The socket may disconnect when on non-LiveView pages, so we reconnect on visibility change
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !liveSocket.isConnected()) {
    liveSocket.connect()
  }
})

// Also attempt reconnection on page focus (backup for browsers that don't fire visibilitychange)
window.addEventListener("focus", () => {
  if (!liveSocket.isConnected()) {
    liveSocket.connect()
  }
  syncCursorGlowForRoute()
})

window.addEventListener("popstate", syncCursorGlowForRoute)

// Expose for debugging
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
