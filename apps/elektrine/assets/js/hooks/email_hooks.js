// Email-related LiveView hooks

function isEditableTarget(target) {
  if (!(target instanceof Element)) return false

  if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'SELECT') {
    return true
  }

  if (target.contentEditable === 'true' || target.isContentEditable) {
    return true
  }

  return Boolean(
    target.closest(
      'input, textarea, select, [contenteditable="true"], [contenteditable=""], [role="textbox"], .ProseMirror, .ql-editor'
    )
  )
}

const SHORTCUT_MODAL_SELECTOR = '[data-email-shortcuts-modal], #keyboard-shortcuts-modal'

function closeExistingShortcutModals() {
  document.querySelectorAll(SHORTCUT_MODAL_SELECTOR).forEach((modal) => modal.remove())
}

function registerEmailShortcutHelp(owner, callback) {
  window.activeEmailShortcutHelp = { owner, callback }

  return () => {
    if (window.activeEmailShortcutHelp?.owner === owner) {
      delete window.activeEmailShortcutHelp
    }
  }
}

function isActiveEmailShortcutHelpOwner(owner) {
  return window.activeEmailShortcutHelp?.owner === owner
}

export const KeyboardShortcuts = {
  mounted() {
    this.setupKeyboardShortcuts()
    this.unregisterShortcutHelp = registerEmailShortcutHelp(this, () => this.showShortcutsHelp())

    // Listen for server event to show keyboard shortcuts
    this.handleEvent("show-keyboard-shortcuts", () => {
      if (isActiveEmailShortcutHelpOwner(this)) {
        this.showShortcutsHelp()
      }
    })

    // Listen for scroll-to-top event when navigating between tabs
    this.handleEvent("scroll-to-top", () => {
      window.scrollTo({
        top: 0,
        behavior: 'smooth'
      })
    })

    this.handleEvent("focus-search-input", () => {
      this.focusSearchInput()
    })
  },

  setupKeyboardShortcuts() {
    // Track selected message for keyboard navigation
    this.selectedMessageIndex = -1
    this.messages = []

    // Update message list when DOM changes
    this.updateMessageList()

    // Store the bound handler so we can remove it later
    this.keyHandler = (e) => {
      // Don't interfere when typing in inputs, textareas, or contenteditable elements
      if (isEditableTarget(e.target) || e.target.closest('.dropdown.dropdown-open')) {
        return
      }

      // Handle shortcuts
      this.handleKeyboardShortcut(e)
    }

    document.addEventListener('keydown', this.keyHandler)

    // Update message list when new messages are added
    const observer = new MutationObserver(() => {
      this.updateMessageList()
    })

    // Observe the entire document for changes
    const messageContainer = document.getElementById('message-list') || document.body
    observer.observe(messageContainer, {
      childList: true,
      subtree: true
    })

    this.observer = observer
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
    if (this.keyHandler) {
      document.removeEventListener('keydown', this.keyHandler)
    }
    if (this.gotoMenuCleanup) {
      this.gotoMenuCleanup()
    }
    if (this.unregisterShortcutHelp) {
      this.unregisterShortcutHelp()
    }
  },

  updateMessageList() {
    // Look for messages in the document, not just within this.el
    this.messages = Array.from(document.querySelectorAll('[id^="message-"]'))
    if (this.selectedMessageIndex >= this.messages.length) {
      this.selectedMessageIndex = this.messages.length - 1
    }
  },

  handleKeyboardShortcut(e) {
    const key = e.key.toLowerCase()
    const ctrl = e.ctrlKey || e.metaKey


    // Gmail-style shortcuts
    switch (key) {
      case 'c':
        if (!ctrl) {
          e.preventDefault()
          this.navigateToCompose()
        }
        break

      case 'g':
        if (!ctrl) {
          e.preventDefault()
          this.showGotoMenu()
        }
        break

      case '/':
        e.preventDefault()
        this.focusSearch()
        break

      case '?':
        e.preventDefault()
        this.showShortcutsHelp()
        break

      case 'j':
        if (!ctrl) {
          e.preventDefault()
          this.selectNextMessage()
        }
        break

      case 'k':
        if (!ctrl) {
          e.preventDefault()
          this.selectPrevMessage()
        }
        break

      case 'enter':
        if (this.selectedMessageIndex >= 0) {
          e.preventDefault()
          this.openSelectedMessage()
        }
        break

      case 'e':
        if (!ctrl && this.selectedMessageIndex >= 0) {
          e.preventDefault()
          this.archiveSelectedMessage()
        }
        break

      case 'r':
        if (!ctrl && this.selectedMessageIndex >= 0) {
          e.preventDefault()
          this.replyToSelectedMessage()
        }
        break

      case 'f':
        if (!ctrl && this.selectedMessageIndex >= 0) {
          e.preventDefault()
          this.forwardSelectedMessage()
        }
        break

      case '#':
        if (this.selectedMessageIndex >= 0) {
          e.preventDefault()
          this.deleteSelectedMessage()
        }
        break

      case '!':
        if (this.selectedMessageIndex >= 0) {
          e.preventDefault()
          this.markSpamSelectedMessage()
        }
        break
    }
  },

  showGotoMenu() {
    if (this.gotoMenuCleanup) {
      this.gotoMenuCleanup()
    }

    // Show a temporary goto menu
    const menu = document.createElement('div')
    menu.className = 'shortcut-floating fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 rounded-lg p-6 z-50'
    menu.innerHTML = `
      <h3 class="shortcut-heading text-lg font-bold mb-4">Go to...</h3>
      <div class="space-y-2">
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="inbox">
          <span class="font-mono mr-2">gi</span> Inbox
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="sent">
          <span class="font-mono mr-2">gs</span> Sent
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="search">
          <span class="font-mono mr-2">gt</span> Search
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="archive">
          <span class="font-mono mr-2">ga</span> Archive
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="spam">
          <span class="font-mono mr-2">gp</span> Spam
        </button>
      </div>
      <div class="shortcut-muted text-xs mt-4">Press Escape to close</div>
    `

    document.body.appendChild(menu)

    const handleGotoKey = (e) => {
      const key = e.key.toLowerCase()

      if (['escape', 'i', 's', 't', 'a', 'p'].includes(key)) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }

      if (key === 'escape') {
        cleanup()
      } else if (key === 'i') {
        window.location.href = '/email?tab=inbox'
        cleanup()
      } else if (key === 's') {
        window.location.href = '/email?tab=sent'
        cleanup()
      } else if (key === 't') {
        window.location.href = '/email?tab=search'
        cleanup()
      } else if (key === 'a') {
        window.location.href = '/email?tab=archive'
        cleanup()
      } else if (key === 'p') {
        window.location.href = '/email?tab=spam'
        cleanup()
      }
    }

    let timeoutId = null
    const cleanup = () => {
      if (timeoutId) {
        clearTimeout(timeoutId)
        timeoutId = null
      }
      document.removeEventListener('keydown', handleGotoKey, true)
      if (menu.parentNode) {
        menu.parentNode.removeChild(menu)
      }
      if (this.gotoMenuCleanup === cleanup) {
        this.gotoMenuCleanup = null
      }
    }

    this.gotoMenuCleanup = cleanup

    // Handle goto navigation
    menu.addEventListener('click', (e) => {
      const button = e.target.closest('[data-goto]')
      if (button) {
        const destination = button.dataset.goto
        this.navigateTo(destination)
        cleanup()
      }
    })

    document.addEventListener('keydown', handleGotoKey, true)

    // Auto-close after 5 seconds
    timeoutId = setTimeout(cleanup, 5000)
  },

  navigateTo(destination) {
    // Use LiveView event to navigate to tabs
    const tabMap = {
      inbox: 'inbox',
      sent: 'sent',
      search: 'search',
      archive: 'archive',
      spam: 'spam'
    }

    if (tabMap[destination]) {
      // Send event to LiveView to switch tabs
      this.pushEvent('switch_tab', { tab: tabMap[destination] })
    }
  },

  navigateToCompose() {
    // Use LiveView event to navigate to compose
    this.pushEvent('navigate_to_compose', {})
  },

  focusSearch() {
    // Switch to search tab and focus input
    this.pushEvent('switch_tab', { tab: 'search', focus_search: true })
  },

  focusSearchInput() {
    const focusInput = () => {
      const input =
        document.getElementById('email-search-input') ||
        document.getElementById('email-index-search-input') ||
        document.querySelector('[data-search-input]')

      if (input) {
        input.focus()
        input.select?.()
      }
    }

    requestAnimationFrame(() => {
      focusInput()
      setTimeout(focusInput, 75)
    })
  },

  selectNextMessage() {
    if (this.messages.length === 0) return

    // Clear previous selection
    this.clearMessageSelection()

    this.selectedMessageIndex = Math.min(this.selectedMessageIndex + 1, this.messages.length - 1)
    this.highlightSelectedMessage()
  },

  selectPrevMessage() {
    if (this.messages.length === 0) return

    // Clear previous selection
    this.clearMessageSelection()

    this.selectedMessageIndex = Math.max(this.selectedMessageIndex - 1, 0)
    this.highlightSelectedMessage()
  },

  clearMessageSelection() {
    this.messages.forEach(msg => {
      msg.classList.remove('ring-2', 'ring-primary', 'ring-offset-2')
    })
  },

  highlightSelectedMessage() {
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      selectedMsg.classList.add('ring-2', 'ring-primary', 'ring-offset-2')
      selectedMsg.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }
  },

  openSelectedMessage() {
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      const openLink = selectedMsg.querySelector('.message-open-link')
      if (openLink) {
        openLink.click()
      } else {
        selectedMsg.click()
      }
    }
  },

  archiveSelectedMessage() {
    // Archive functionality - trigger archive event
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      const messageId = selectedMsg.id.replace('message-', '')
      // Trigger archive event on the LiveView component
      this.pushEvent('archive_message', { message_id: messageId })
    }
  },

  replyToSelectedMessage() {
    // Reply functionality - open compose with reply
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      const messageId = selectedMsg.id.replace('message-', '')
      this.pushEvent('open_compose', { mode: 'reply', message_id: messageId })
    }
  },

  forwardSelectedMessage() {
    // Forward functionality - open compose with forward
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      const messageId = selectedMsg.id.replace('message-', '')
      this.pushEvent('open_compose', { mode: 'forward', message_id: messageId })
    }
  },

  deleteSelectedMessage() {
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      const messageId = selectedMsg.id.replace('message-', '')
      this.pushEvent('delete_message', { message_id: messageId })
    }
  },

  markSpamSelectedMessage() {
    // Mark as spam functionality
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      const messageId = selectedMsg.id.replace('message-', '')
      // Trigger spam event on the LiveView component
      this.pushEvent('mark_spam', { message_id: messageId })
    }
  },

  showShortcutsHelp() {
    closeExistingShortcutModals()

    if (window.showKeyboardShortcuts) {
      window.showKeyboardShortcuts()
    }
  }
}

// Hook to automatically resize email content iframe based on content height
export const EmailIframeResize = {
  mounted() {
    this.iframe = this.el
    // Initialize maxHeight from current iframe height to prevent shrinking
    this.maxHeight = this.iframe.offsetHeight || 600
    this.resizeTimers = []
    this.imageListeners = []
    this.mutationObserver = null

    // Resize when iframe loads
    this.loadHandler = () => {
      // Resize immediately
      this.resizeIframe()
      this.bindContentResizeWatchers()

      // Check again after brief delays to catch images loading
      this.scheduleResize(100)
      this.scheduleResize(300)
      this.scheduleResize(600)
      this.scheduleResize(1000)
      this.scheduleResize(2000)
    }

    this.iframe.addEventListener('load', this.loadHandler)
  },

  scheduleResize(delay) {
    const timer = setTimeout(() => this.resizeIframe(), delay)
    this.resizeTimers.push(timer)
  },

  bindContentResizeWatchers() {
    this.cleanupContentResizeWatchers()

    try {
      const iframeDoc = this.iframe.contentDocument || this.iframe.contentWindow.document
      if (!iframeDoc) return

      iframeDoc.querySelectorAll('img').forEach((image) => {
        const listener = () => this.resizeIframe()
        image.addEventListener('load', listener, { once: true })
        image.addEventListener('error', listener, { once: true })
        this.imageListeners.push({ image, listener })
      })

      if (iframeDoc.fonts && typeof iframeDoc.fonts.ready?.then === 'function') {
        iframeDoc.fonts.ready.then(() => this.resizeIframe()).catch(() => {})
      }

      this.mutationObserver = new MutationObserver(() => this.resizeIframe())
      this.mutationObserver.observe(iframeDoc.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        characterData: true,
      })
    } catch (_error) {
      // Cross-origin restrictions - iframe will use scheduled height checks.
    }
  },

  cleanupContentResizeWatchers() {
    this.imageListeners.forEach(({ image, listener }) => {
      image.removeEventListener('load', listener)
      image.removeEventListener('error', listener)
    })
    this.imageListeners = []

    if (this.mutationObserver) {
      this.mutationObserver.disconnect()
      this.mutationObserver = null
    }
  },

  resizeIframe() {
    try {
      const iframeDoc = this.iframe.contentDocument || this.iframe.contentWindow.document

      if (iframeDoc && iframeDoc.body) {
        // Get the full content height including all elements
        const body = iframeDoc.body
        const html = iframeDoc.documentElement

        const contentHeight = Math.max(
          body.scrollHeight,
          body.offsetHeight,
          html.clientHeight,
          html.scrollHeight,
          html.offsetHeight
        )

        // Set a minimum height and add some padding
        const minHeight = 200
        const newHeight = Math.max(contentHeight, minHeight)

        // Only grow, never shrink (prevents resize-on-scroll issues)
        if (newHeight > this.maxHeight) {
          this.maxHeight = newHeight
          this.iframe.style.height = `${newHeight}px`
        }
      }
    } catch (e) {
      // Cross-origin restrictions - iframe will use default height
    }
  },

  updated() {
    // When LiveView updates the element, ensure we maintain the max height
    // Re-apply the height in case LiveView reset it
    if (this.maxHeight > 0) {
      this.iframe.style.height = `${this.maxHeight}px`
    }
  },

  destroyed() {
    if (this.loadHandler) {
      this.iframe.removeEventListener('load', this.loadHandler)
    }

    this.resizeTimers.forEach((timer) => clearTimeout(timer))
    this.resizeTimers = []
    this.cleanupContentResizeWatchers()
  }
}

// Keyboard shortcuts for email show/view page
export const EmailShowKeyboardShortcuts = {
  mounted() {
    this.unregisterShortcutHelp = registerEmailShortcutHelp(this, () => this.showShortcutsHelp())

    this.keyHandler = (e) => {
      // Don't interfere when typing in inputs, textareas, or contenteditable elements
      if (isEditableTarget(e.target) || e.target.closest('.dropdown.dropdown-open')) {
        return
      }

      const key = e.key.toLowerCase()
      const ctrl = e.ctrlKey || e.metaKey

      // Handle shortcuts
      switch (key) {
        case 'c':
          if (!ctrl) {
            e.preventDefault()
            window.location.href = '/email/compose'
          }
          break

        case 'g':
          if (!ctrl) {
            e.preventDefault()
            this.showGotoMenu()
          }
          break

        case 'r':
          if (!ctrl) {
            e.preventDefault()
            const replyBtn = document.querySelector('button[phx-click="reply"]')
            if (replyBtn) replyBtn.click()
          }
          break

        case 'a':
          if (!ctrl) {
            e.preventDefault()
            const replyAllBtn = document.querySelector('button[phx-click="reply_all"]')
            if (replyAllBtn) replyAllBtn.click()
          }
          break

        case 'f':
          if (!ctrl) {
            e.preventDefault()
            const forwardBtn = document.querySelector('button[phx-click="forward"]')
            if (forwardBtn) forwardBtn.click()
          }
          break

        case 'v':
          if (!ctrl) {
            e.preventDefault()
            const rawLink = document.querySelector('a[href*="/raw"]')
            if (rawLink) {
              window.location.href = rawLink.href
            }
          }
          break

        case 'l':
          if (!ctrl) {
            e.preventDefault()
            const replyLaterBtn = document.querySelector('button[phx-click="show_reply_later_modal"]')
            if (replyLaterBtn) replyLaterBtn.click()
          }
          break

        case 'escape':
          e.preventDefault()
          window.location.href = '/email'
          break

        case '?':
          e.preventDefault()
          this.showShortcutsHelp()
          break
      }
    }

    document.addEventListener('keydown', this.keyHandler)

    this.handleEvent("show-keyboard-shortcuts", () => {
      if (isActiveEmailShortcutHelpOwner(this)) {
        this.showShortcutsHelp()
      }
    })

    // Also attach FileDownloader functionality
    this.handleEvent("download-file", ({ url, filename }) => {
      const link = document.createElement('a')
      link.href = url
      link.download = filename
      document.body.appendChild(link)
      link.click()
      document.body.removeChild(link)
    })
  },

  destroyed() {
    if (this.keyHandler) {
      document.removeEventListener('keydown', this.keyHandler)
    }
    if (this.gotoMenuCleanup) {
      this.gotoMenuCleanup()
    }
    if (this.shortcutsModalCleanup) {
      this.shortcutsModalCleanup()
    }
    if (this.unregisterShortcutHelp) {
      this.unregisterShortcutHelp()
    }
  },

  showShortcutsHelp() {
    closeExistingShortcutModals()

    if (this.shortcutsModalCleanup) {
      this.shortcutsModalCleanup()
    }

    const modal = document.createElement('div')
    modal.dataset.emailShortcutsModal = 'true'
    modal.className = 'shortcut-overlay fixed inset-0 z-50 flex items-center justify-center p-4'
    modal.innerHTML = `
      <div class="shortcut-dialog rounded-lg p-6 max-w-2xl w-full max-h-[80vh] overflow-y-auto">
        <div class="flex justify-between items-center mb-6">
          <h3 class="text-2xl font-bold">Keyboard Shortcuts</h3>
          <button class="btn btn-ghost btn-sm btn-circle" data-close>
            <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <h4 class="shortcut-heading font-semibold mb-3">Navigation</h4>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span class="text-sm">Compose new message</span>
                <kbd class="kbd kbd-sm">c</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Go to menu</span>
                <kbd class="kbd kbd-sm">g</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Back to inbox</span>
                <kbd class="kbd kbd-sm">Esc</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">View raw email</span>
                <kbd class="kbd kbd-sm">v</kbd>
              </div>
            </div>
          </div>

          <div>
            <h4 class="shortcut-heading font-semibold mb-3">Actions</h4>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span class="text-sm">Reply</span>
                <kbd class="kbd kbd-sm">r</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Reply all</span>
                <kbd class="kbd kbd-sm">a</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Forward</span>
                <kbd class="kbd kbd-sm">f</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Reply later</span>
                <kbd class="kbd kbd-sm">l</kbd>
              </div>
            </div>
          </div>
        </div>

        <div class="shortcut-divider mt-6 pt-4 border-t">
          <div class="flex justify-between items-center">
            <span class="text-sm">Show this help</span>
            <kbd class="kbd kbd-sm">?</kbd>
          </div>
        </div>
      </div>
    `

    document.body.appendChild(modal)

    const escHandler = (e) => {
      if (e.key === 'Escape') {
        cleanup()
      }
    }

    const cleanup = () => {
      document.removeEventListener('keydown', escHandler)
      if (modal.parentNode) {
        modal.parentNode.removeChild(modal)
      }
      if (this.shortcutsModalCleanup === cleanup) {
        this.shortcutsModalCleanup = null
      }
    }

    this.shortcutsModalCleanup = cleanup

    // Close on click outside or close button
    modal.addEventListener('click', (e) => {
      if (e.target === modal || e.target.closest('[data-close]')) {
        cleanup()
      }
    })

    // Close on Escape key
    document.addEventListener('keydown', escHandler)
  },

  showGotoMenu() {
    if (this.gotoMenuCleanup) {
      this.gotoMenuCleanup()
    }

    // Show a temporary goto menu
    const menu = document.createElement('div')
    menu.className = 'shortcut-floating fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 rounded-lg p-6 z-50'
    menu.innerHTML = `
      <h3 class="shortcut-heading text-lg font-bold mb-4">Go to...</h3>
      <div class="space-y-2">
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="inbox">
          <span class="font-mono mr-2">gi</span> Inbox
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="sent">
          <span class="font-mono mr-2">gs</span> Sent
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="search">
          <span class="font-mono mr-2">gt</span> Search
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="archive">
          <span class="font-mono mr-2">ga</span> Archive
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="spam">
          <span class="font-mono mr-2">gp</span> Spam
        </button>
      </div>
      <div class="shortcut-muted text-xs mt-4">Press Escape to close</div>
    `

    document.body.appendChild(menu)

    const handleGotoKey = (e) => {
      const key = e.key.toLowerCase()

      if (['escape', 'i', 's', 't', 'a', 'p'].includes(key)) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }

      if (key === 'escape') {
        cleanup()
      } else if (key === 'i') {
        window.location.href = '/email?tab=inbox'
        cleanup()
      } else if (key === 's') {
        window.location.href = '/email?tab=sent'
        cleanup()
      } else if (key === 't') {
        window.location.href = '/email?tab=search'
        cleanup()
      } else if (key === 'a') {
        window.location.href = '/email?tab=archive'
        cleanup()
      } else if (key === 'p') {
        window.location.href = '/email?tab=spam'
        cleanup()
      }
    }

    let timeoutId = null
    const cleanup = () => {
      if (timeoutId) {
        clearTimeout(timeoutId)
        timeoutId = null
      }
      document.removeEventListener('keydown', handleGotoKey, true)
      if (menu.parentNode) {
        menu.parentNode.removeChild(menu)
      }
      if (this.gotoMenuCleanup === cleanup) {
        this.gotoMenuCleanup = null
      }
    }

    this.gotoMenuCleanup = cleanup

    // Handle goto navigation
    menu.addEventListener('click', (e) => {
      const button = e.target.closest('[data-goto]')
      if (button) {
        const destination = button.dataset.goto
        window.location.href = '/email?tab=' + destination
        cleanup()
      }
    })

    document.addEventListener('keydown', handleGotoKey, true)

    // Auto-close after 5 seconds
    timeoutId = setTimeout(cleanup, 5000)
  }
}

// Keyboard shortcuts for email compose page
export const EmailComposeKeyboardShortcuts = {
  mounted() {
    this.unregisterShortcutHelp = registerEmailShortcutHelp(this, () => this.showShortcutsHelp())

    this.keyHandler = (e) => {
      const key = e.key.toLowerCase()
      const ctrl = e.ctrlKey || e.metaKey

      // Don't interfere with dropdowns
      if (e.target.closest('.dropdown.dropdown-open')) {
        return
      }

      // Handle shortcuts
      switch (key) {
        case 'enter':
          // Ctrl/Cmd + Enter to send email
          if (ctrl) {
            e.preventDefault()
            const submitBtn = document.querySelector('button[type="submit"]')
            if (submitBtn && !submitBtn.disabled) {
              submitBtn.click()
            }
          }
          break

        case 'escape':
          // Don't trigger if typing in input/textarea
          if (isEditableTarget(e.target)) {
            return
          }
          e.preventDefault()
          // Go back
          const backBtn = document.querySelector('a[href*="/email"]')
          if (backBtn) {
            window.location.href = backBtn.href
          }
          break

        case 'g':
          // Don't trigger if typing
          if (isEditableTarget(e.target)) {
            return
          }
          if (!ctrl) {
            e.preventDefault()
            this.showGotoMenu()
          }
          break

        case '?':
          // Don't trigger if typing
          if (isEditableTarget(e.target)) {
            return
          }
          e.preventDefault()
          this.showShortcutsHelp()
          break
      }
    }

    document.addEventListener('keydown', this.keyHandler)

    this.handleEvent("show-keyboard-shortcuts", () => {
      if (isActiveEmailShortcutHelpOwner(this)) {
        this.showShortcutsHelp()
      }
    })
  },

  destroyed() {
    if (this.keyHandler) {
      document.removeEventListener('keydown', this.keyHandler)
    }
    if (this.gotoMenuCleanup) {
      this.gotoMenuCleanup()
    }
    if (this.shortcutsModalCleanup) {
      this.shortcutsModalCleanup()
    }
    if (this.unregisterShortcutHelp) {
      this.unregisterShortcutHelp()
    }
  },

  showGotoMenu() {
    if (this.gotoMenuCleanup) {
      this.gotoMenuCleanup()
    }

    const menu = document.createElement('div')
    menu.className = 'shortcut-floating fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 rounded-lg p-6 z-50'
    menu.innerHTML = `
      <h3 class="shortcut-heading text-lg font-bold mb-4">Go to...</h3>
      <div class="space-y-2">
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="inbox">
          <span class="font-mono mr-2">gi</span> Inbox
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="sent">
          <span class="font-mono mr-2">gs</span> Sent
        </button>
        <button class="btn btn-ghost btn-sm w-full justify-start" data-goto="search">
          <span class="font-mono mr-2">gt</span> Search
        </button>
      </div>
      <div class="shortcut-muted text-xs mt-4">Press Escape to close</div>
    `

    document.body.appendChild(menu)

    const handleGotoKey = (e) => {
      const key = e.key.toLowerCase()

      if (['escape', 'i', 's', 't'].includes(key)) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }

      if (key === 'escape') {
        cleanup()
      } else if (key === 'i') {
        window.location.href = '/email?tab=inbox'
        cleanup()
      } else if (key === 's') {
        window.location.href = '/email?tab=sent'
        cleanup()
      } else if (key === 't') {
        window.location.href = '/email?tab=search'
        cleanup()
      }
    }

    let timeoutId = null
    const cleanup = () => {
      if (timeoutId) {
        clearTimeout(timeoutId)
        timeoutId = null
      }
      document.removeEventListener('keydown', handleGotoKey, true)
      if (menu.parentNode) {
        menu.parentNode.removeChild(menu)
      }
      if (this.gotoMenuCleanup === cleanup) {
        this.gotoMenuCleanup = null
      }
    }

    this.gotoMenuCleanup = cleanup

    menu.addEventListener('click', (e) => {
      const button = e.target.closest('[data-goto]')
      if (button) {
        const destination = button.dataset.goto
        window.location.href = '/email?tab=' + destination
        cleanup()
      }
    })

    document.addEventListener('keydown', handleGotoKey, true)

    timeoutId = setTimeout(cleanup, 5000)
  },

  showShortcutsHelp() {
    closeExistingShortcutModals()

    if (this.shortcutsModalCleanup) {
      this.shortcutsModalCleanup()
    }

    const modal = document.createElement('div')
    modal.dataset.emailShortcutsModal = 'true'
    modal.className = 'shortcut-overlay fixed inset-0 z-50 flex items-center justify-center p-4'
    modal.innerHTML = `
      <div class="shortcut-dialog rounded-lg p-6 max-w-2xl w-full max-h-[80vh] overflow-y-auto">
        <div class="flex justify-between items-center mb-6">
          <h3 class="text-2xl font-bold">Keyboard Shortcuts</h3>
          <button class="btn btn-ghost btn-sm btn-circle" data-close>
            <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <h4 class="shortcut-heading font-semibold mb-3">Navigation</h4>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span class="text-sm">Go to inbox</span>
                <kbd class="kbd kbd-sm">g</kbd> <kbd class="kbd kbd-sm">i</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Go to sent</span>
                <kbd class="kbd kbd-sm">g</kbd> <kbd class="kbd kbd-sm">s</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Go to search</span>
                <kbd class="kbd kbd-sm">g</kbd> <kbd class="kbd kbd-sm">t</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Cancel/Go back</span>
                <kbd class="kbd kbd-sm">Esc</kbd>
              </div>
            </div>
          </div>

          <div>
            <h4 class="shortcut-heading font-semibold mb-3">Actions</h4>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span class="text-sm">Send email</span>
                <kbd class="kbd kbd-sm">Ctrl</kbd> + <kbd class="kbd kbd-sm">Enter</kbd>
              </div>
            </div>
          </div>
        </div>

        <div class="shortcut-divider mt-6 pt-4 border-t">
          <div class="flex justify-between items-center">
            <span class="text-sm">Show this help</span>
            <kbd class="kbd kbd-sm">?</kbd>
          </div>
        </div>
      </div>
    `

    document.body.appendChild(modal)

    const escHandler = (e) => {
      if (e.key === 'Escape') {
        cleanup()
      }
    }

    const cleanup = () => {
      document.removeEventListener('keydown', escHandler)
      if (modal.parentNode) {
        modal.parentNode.removeChild(modal)
      }
      if (this.shortcutsModalCleanup === cleanup) {
        this.shortcutsModalCleanup = null
      }
    }

    this.shortcutsModalCleanup = cleanup

    modal.addEventListener('click', (e) => {
      if (e.target === modal || e.target.closest('[data-close]')) {
        cleanup()
      }
    })

    document.addEventListener('keydown', escHandler)
  }
}
