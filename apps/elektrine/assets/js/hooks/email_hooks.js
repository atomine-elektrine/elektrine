// Email-related LiveView hooks

export const KeyboardShortcuts = {
  mounted() {
    this.setupKeyboardShortcuts()

    // Listen for server event to show keyboard shortcuts
    this.handleEvent("show-keyboard-shortcuts", () => {
      if (window.showKeyboardShortcuts) {
        window.showKeyboardShortcuts()
      } else {
      }
    })

    // Listen for scroll-to-top event when navigating between tabs
    this.handleEvent("scroll-to-top", () => {
      window.scrollTo({
        top: 0,
        behavior: 'smooth'
      })
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
      if (e.target.tagName === 'INPUT' ||
          e.target.tagName === 'TEXTAREA' ||
          e.target.contentEditable === 'true' ||
          e.target.closest('.dropdown.dropdown-open')) {
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
    menu.className = 'fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 bg-base-100 border border-base-300 rounded-lg shadow-xl p-6 z-50'
    menu.innerHTML = `
      <h3 class="text-lg font-bold mb-4">Go to...</h3>
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
      <div class="text-xs text-base-content/60 mt-4">Press Escape to close</div>
    `

    document.body.appendChild(menu)

    const handleGotoKey = (e) => {
      if (e.key === 'Escape') {
        cleanup()
      } else if (e.key === 'i') {
        this.navigateTo('inbox')
        cleanup()
      } else if (e.key === 's') {
        this.navigateTo('sent')
        cleanup()
      } else if (e.key === 't') {
        this.navigateTo('search')
        cleanup()
      } else if (e.key === 'a') {
        this.navigateTo('archive')
        cleanup()
      } else if (e.key === 'p') {
        this.navigateTo('spam')
        cleanup()
      }
    }

    let timeoutId = null
    const cleanup = () => {
      if (timeoutId) {
        clearTimeout(timeoutId)
        timeoutId = null
      }
      document.removeEventListener('keydown', handleGotoKey)
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

    document.addEventListener('keydown', handleGotoKey)

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
    // Delete functionality - move to trash/delete
    if (this.selectedMessageIndex >= 0 && this.selectedMessageIndex < this.messages.length) {
      const selectedMsg = this.messages[this.selectedMessageIndex]
      // Look for delete action in dropdown
      const dropdownBtn = selectedMsg.querySelector('.dropdown button')
      if (dropdownBtn) {
        dropdownBtn.click()
        setTimeout(() => {
          const deleteOption = document.querySelector('.dropdown-content [phx-click*="delete"]')
          if (deleteOption) {
            deleteOption.click()
          }
        }, 100)
      }
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
    // Trigger the LiveView event instead of calling directly
    // This ensures the modal is only shown once through the proper event flow
    this.pushEvent('show_keyboard_shortcuts', {})
  }
}

// Hook to make email links open in new tabs
export const EmailContentLinks = {
  mounted() {
    this.setupLinks()
  },

  updated() {
    this.setupLinks()
  },

  setupLinks() {
    // Find all links within the email content
    const links = this.el.querySelectorAll('a')

    links.forEach(link => {
      // Only modify external links (not anchor links)
      if (link.href && !link.href.startsWith('#')) {
        // Add target="_blank" to open in new tab
        link.setAttribute('target', '_blank')
        // Add rel="noopener noreferrer" for security
        // noopener: prevents window.opener access
        // noreferrer: doesn't send referrer information
        link.setAttribute('rel', 'noopener noreferrer')

        // Add visual indication that link opens in new tab
        link.classList.add('text-primary', 'hover:underline')
      }
    })
  }
}

// Hook to automatically resize email content iframe based on content height
export const EmailIframeResize = {
  mounted() {
    this.iframe = this.el
    // Initialize maxHeight from current iframe height to prevent shrinking
    this.maxHeight = this.iframe.offsetHeight || 600

    // Resize when iframe loads
    this.loadHandler = () => {
      // Resize immediately
      this.resizeIframe()

      // Check again after brief delays to catch images loading
      setTimeout(() => this.resizeIframe(), 100)
      setTimeout(() => this.resizeIframe(), 300)
      setTimeout(() => this.resizeIframe(), 600)
      setTimeout(() => this.resizeIframe(), 1000)
    }

    this.iframe.addEventListener('load', this.loadHandler)
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
  }
}

// Keyboard shortcuts for email show/view page
export const EmailShowKeyboardShortcuts = {
  mounted() {
    this.keyHandler = (e) => {
      // Don't interfere when typing in inputs, textareas, or contenteditable elements
      if (e.target.tagName === 'INPUT' ||
          e.target.tagName === 'TEXTAREA' ||
          e.target.contentEditable === 'true' ||
          e.target.closest('.dropdown.dropdown-open')) {
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
  },

  showShortcutsHelp() {
    if (this.shortcutsModalCleanup) {
      this.shortcutsModalCleanup()
    }

    const modal = document.createElement('div')
    modal.className = 'fixed inset-0 bg-base-300/50 backdrop-blur-sm z-50 flex items-center justify-center p-4'
    modal.innerHTML = `
      <div class="bg-base-100 rounded-lg shadow-xl p-6 max-w-2xl w-full max-h-[80vh] overflow-y-auto border border-base-300">
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
            <h4 class="font-semibold mb-3 text-primary">Navigation</h4>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span class="text-sm">Compose new message</span>
                <kbd class="kbd kbd-sm">c</kbd>
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
            <h4 class="font-semibold mb-3 text-primary">Actions</h4>
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

        <div class="mt-6 pt-4 border-t border-base-300">
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
    menu.className = 'fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 bg-base-100 border border-base-300 rounded-lg shadow-xl p-6 z-50'
    menu.innerHTML = `
      <h3 class="text-lg font-bold mb-4">Go to...</h3>
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
      <div class="text-xs text-base-content/60 mt-4">Press Escape to close</div>
    `

    document.body.appendChild(menu)

    const handleGotoKey = (e) => {
      if (e.key === 'Escape') {
        cleanup()
      } else if (e.key === 'i') {
        window.location.href = '/email?tab=inbox'
        cleanup()
      } else if (e.key === 's') {
        window.location.href = '/email?tab=sent'
        cleanup()
      } else if (e.key === 't') {
        window.location.href = '/email?tab=search'
        cleanup()
      } else if (e.key === 'a') {
        window.location.href = '/email?tab=archive'
        cleanup()
      } else if (e.key === 'p') {
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
      document.removeEventListener('keydown', handleGotoKey)
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

    document.addEventListener('keydown', handleGotoKey)

    // Auto-close after 5 seconds
    timeoutId = setTimeout(cleanup, 5000)
  }
}

// Keyboard shortcuts for email compose page
export const EmailComposeKeyboardShortcuts = {
  mounted() {
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
          if (e.target.tagName === 'INPUT' ||
              e.target.tagName === 'TEXTAREA' ||
              e.target.contentEditable === 'true') {
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
          if (e.target.tagName === 'INPUT' ||
              e.target.tagName === 'TEXTAREA' ||
              e.target.contentEditable === 'true') {
            return
          }
          if (!ctrl) {
            e.preventDefault()
            this.showGotoMenu()
          }
          break

        case '?':
          // Don't trigger if typing
          if (e.target.tagName === 'INPUT' ||
              e.target.tagName === 'TEXTAREA' ||
              e.target.contentEditable === 'true') {
            return
          }
          e.preventDefault()
          this.showShortcutsHelp()
          break
      }
    }

    document.addEventListener('keydown', this.keyHandler)
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
  },

  showGotoMenu() {
    if (this.gotoMenuCleanup) {
      this.gotoMenuCleanup()
    }

    const menu = document.createElement('div')
    menu.className = 'fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 bg-base-100 border border-base-300 rounded-lg shadow-xl p-6 z-50'
    menu.innerHTML = `
      <h3 class="text-lg font-bold mb-4">Go to...</h3>
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
      <div class="text-xs text-base-content/60 mt-4">Press Escape to close</div>
    `

    document.body.appendChild(menu)

    const handleGotoKey = (e) => {
      if (e.key === 'Escape') {
        cleanup()
      } else if (e.key === 'i') {
        window.location.href = '/email?tab=inbox'
        cleanup()
      } else if (e.key === 's') {
        window.location.href = '/email?tab=sent'
        cleanup()
      } else if (e.key === 't') {
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
      document.removeEventListener('keydown', handleGotoKey)
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

    document.addEventListener('keydown', handleGotoKey)

    timeoutId = setTimeout(cleanup, 5000)
  },

  showShortcutsHelp() {
    if (this.shortcutsModalCleanup) {
      this.shortcutsModalCleanup()
    }

    const modal = document.createElement('div')
    modal.className = 'fixed inset-0 bg-base-300/50 backdrop-blur-sm z-50 flex items-center justify-center p-4'
    modal.innerHTML = `
      <div class="bg-base-100 rounded-lg shadow-xl p-6 max-w-2xl w-full max-h-[80vh] overflow-y-auto border border-base-300">
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
            <h4 class="font-semibold mb-3 text-primary">Navigation</h4>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span class="text-sm">Go to inbox</span>
                <kbd class="kbd kbd-sm">g</kbd> <kbd class="kbd kbd-sm">i</kbd>
              </div>
              <div class="flex justify-between items-center">
                <span class="text-sm">Cancel/Go back</span>
                <kbd class="kbd kbd-sm">Esc</kbd>
              </div>
            </div>
          </div>

          <div>
            <h4 class="font-semibold mb-3 text-primary">Actions</h4>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span class="text-sm">Send email</span>
                <kbd class="kbd kbd-sm">Ctrl</kbd> + <kbd class="kbd kbd-sm">Enter</kbd>
              </div>
            </div>
          </div>
        </div>

        <div class="mt-6 pt-4 border-t border-base-300">
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
