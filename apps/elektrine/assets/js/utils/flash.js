/**
 * Flash Message Utilities
 * Handles flash message initialization for non-LiveView pages
 */

import { FlashMessageManager } from '../flash_message_manager'

/**
 * Initialize flash messages for non-LiveView pages
 */
export function initFlashMessages() {
  if (!window.flashManager) {
    window.flashManager = new FlashMessageManager()
  }

  // Find and initialize any flash messages on page load
  const flashMessages = document.querySelectorAll('[phx-hook="FlashMessage"]')
  flashMessages.forEach(element => {
    initFlashElement(element)
  })

  // Flash messages from controllers are now processed in app.js on phx:page-loading-stop
}

/**
 * Initialize a single flash element
 */
function initFlashElement(element) {
  const hook = {
    el: element,
    mounted() {
      if (!window.flashManager) {
        window.flashManager = new FlashMessageManager()
      }

      window.flashManager.addMessage(this.el, this)

      // Auto-hide after 5 seconds
      this.autoHideTimer = setTimeout(() => {
        this.hide()
      }, 5000)

      // Click to dismiss
      this.clickHandler = () => this.hide()
      this.el.addEventListener('click', this.clickHandler)
    },
    hide() {
      if (this.autoHideTimer) {
        clearTimeout(this.autoHideTimer)
        this.autoHideTimer = null
      }

      if (this.el.dataset.hiding) return
      this.el.dataset.hiding = 'true'

      if (window.flashManager) {
        window.flashManager.removeMessage(this.el)
      }

      this.el.style.transition = 'all 0.3s ease-out'
      this.el.style.opacity = '0'
      this.el.style.transform = 'translateX(-100%)'

      setTimeout(() => {
        if (this.el && this.el.parentNode) {
          this.el.style.display = 'none'
        }
      }, 300)
    }
  }

  hook.mounted()
}
