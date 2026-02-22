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

// Import utilities
import {
  initEmailSelection,
  initDropdownManagement,
  initNavigationHandlers,
  initClipboardHandlers
} from "./utils"

// Import UI modules
import { initModalControls } from "./modal_controls"
import { initMarkdownToolbar } from "./markdown_toolbar"
import { initFormHelpers } from "./form_helpers"
import { initEmailRaw } from "./email_raw"
import { initTabSwitcher } from "./tab_switcher"
import "./hashtag_links" // self-initializes
import { initCursorGlow } from "./cursor_glow"
import { initBlinkenlights, checkBlinkenlights } from "./blinkenlights"
import { initAllGlassCards } from "./glass_card"
import { initMarkdownEditor } from "./markdown_editor"
import { initLiveClock } from "./live_clock"
import { initIpLookup } from "./ip_lookup"
import { initTaglineCycler } from "./tagline_cycler"
import { initProfileStatic } from "./profile_static"

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

topbar.config({ barColors: { 0: "#a855f7" }, shadowColor: "rgba(168, 85, 247, .3)" })

window.addEventListener("phx:page-loading-start", () => topbar.show(300))
window.addEventListener("phx:page-loading-stop", () => {
  topbar.hide()
  checkBlinkenlights()
  initProfileStatic()
  initAutoDismissFlashes()
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

// ============================================================================
// DOM Ready Initialization
// ============================================================================

document.addEventListener('DOMContentLoaded', () => {
  // Initialize utility handlers
  initEmailSelection()
  initDropdownManagement()
  initNavigationHandlers()
  initClipboardHandlers()
  initAutoDismissFlashes()

  // Initialize UI modules
  initCursorGlow()
  initBlinkenlights()
  initAllGlassCards()
  initMarkdownEditor()
  initLiveClock()
  initTaglineCycler()
  initModalControls()
  initMarkdownToolbar()
  initFormHelpers()
  initEmailRaw()
  initTabSwitcher()
  initIpLookup()
  initProfileStatic()

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
})

// Expose for debugging
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
