import {
  closeExistingShortcutModals,
  isActiveEmailShortcutHelpOwner,
  isEditableTarget,
  registerEmailShortcutHelp,
} from "./email_shortcut_helpers"

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
