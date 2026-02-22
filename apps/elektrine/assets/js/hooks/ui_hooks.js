// General UI-related LiveView hooks
/**
 * UI Hooks
 * General-purpose UI hooks for common interactions like copying to clipboard,
 * focus management, flash messages, scrolling, and visual effects.
 */

/**
 * Copy Email Hook
 * Copies email address to clipboard with visual feedback.
 */
export const CopyEmail = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      e.preventDefault()
      const email = this.el.dataset.email

      if (email) {
        navigator.clipboard.writeText(email).then(() => {
          // Show success by changing icon temporarily
          const icon = this.el.querySelector('span')
          if (icon) {
            const originalClass = icon.className
            icon.className = 'hero-check w-3 h-3'

            setTimeout(() => {
              icon.className = originalClass
            }, 2000)
          }

          // Show notification if available
          if (window.showNotification) {
            window.showNotification('Email address copied', 'info', 'Copied!')
          }
        }).catch(err => {
          console.error('Copy failed:', err)
          if (window.showNotification) {
            window.showNotification('Failed to copy', 'error', 'Error')
          }
        })
      }
    })
  }
}

export const PreserveFocus = {
  mounted() {
    this.focusedId = null

    this.handleEvent("restore_focus", () => {
      // Try to restore focus to the previously focused element
      if (this.focusedId) {
        const element = document.getElementById(this.focusedId)
        if (element) {
          element.focus()
        }
      }
    })

    // Track focus changes
    this.focusInHandler = (e) => {
      if (e.target.id) {
        this.focusedId = e.target.id
      }
    }

    document.addEventListener('focusin', this.focusInHandler)
  },

  destroyed() {
    if (this.focusInHandler) {
      document.removeEventListener('focusin', this.focusInHandler)
    }
  }
}

export const FlashAutoDismiss = {
  mounted() {
    this.schedule()
  },

  updated() {
    this.schedule()
  },

  schedule() {
    if (window.initAutoDismissFlashes) {
      window.initAutoDismissFlashes(this.el)
    }
  }
}

import { FlashMessageManager } from '../flash_message_manager'

export const FlashMessage = {
  mounted() {
    // Initialize flash message manager if not exists
    if (!window.flashManager) {
      window.flashManager = new FlashMessageManager()
    }

    // Reset any previous state to ensure clean mounting
    if (this.el.dataset.hiding) {
      delete this.el.dataset.hiding
    }

    // Reset element styles to ensure it can be shown
    this.el.style.display = ''
    this.el.style.opacity = ''
    this.el.style.transform = ''
    this.el.style.transition = ''

    // Add this message to the manager and get the ID
    this.messageId = window.flashManager.addMessage(this.el, this)

    // Set up auto-hide timer - trigger LiveView clear instead of hiding
    this.autoHideTimer = setTimeout(() => {
      this.clearFlash()
    }, 5000)

    // Stop propagation on click to prevent double clearing
    this.el.addEventListener('click', (e) => {
      if (e.target.closest('button')) {
        // Button click will handle clearing via phx-click
        return
      }
      e.stopPropagation()
    })
  },

  destroyed() {
    // Clear all timeouts
    if (this.autoHideTimer) clearTimeout(this.autoHideTimer)
    if (this.fadeOutTimeout) clearTimeout(this.fadeOutTimeout)

    // Remove from manager
    if (window.flashManager) {
      window.flashManager.removeMessage(this.el)
    }
  },

  clearFlash() {
    if (this.autoHideTimer) {
      clearTimeout(this.autoHideTimer)
      this.autoHideTimer = null
    }

    // Trigger the LiveView clear-flash event
    // This will properly clear the flash from LiveView's state
    const flashKey = this.el.getAttribute('phx-value-key')
    if (flashKey) {
      // Trigger a click event on the element which has phx-click="lv:clear-flash"
      this.el.click()
    }
  }
}

export const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", e => {
      e.preventDefault()
      e.stopPropagation()
      
      // Get content from data-content attribute, or fall back to legacy email-address element
      let textToCopy = this.el.dataset.content
      if (!textToCopy) {
        const emailElement = document.getElementById('email-address')
        if (emailElement) {
          textToCopy = emailElement.textContent
        }
      }
      
      if (textToCopy) {
        navigator.clipboard.writeText(textToCopy).then(() => {
          // Show success feedback (change icon temporarily)
          const originalHTML = this.el.innerHTML
          this.el.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd" /></svg>'

          // Restore original icon after a delay
          setTimeout(() => {
            this.el.innerHTML = originalHTML
          }, 2000)
          
          // Show notification if available
          if (window.showNotification) {
            window.showNotification('Copied to clipboard', 'info', 'Copied!')
          }
        }).catch(err => {
          console.error('Copy failed:', err)
        })
      }
    })
  }
}

/**
 * Copy Button Hook
 * Provides visual feedback when copying to clipboard via LiveView events.
 * Changes button to checkmark icon with success color, then reverts after 2 seconds.
 * Used for share modals and other copy-to-clipboard buttons.
 */
export const CopyButton = {
  mounted() {
    this.originalHTML = this.el.innerHTML
    
    // Listen for the copy_to_clipboard event from LiveView
    this.handleEvent("copy_to_clipboard", ({ text }) => {
      navigator.clipboard.writeText(text).then(() => {
        this.showSuccess()
      }).catch(err => {
        console.error('Copy failed:', err)
        // Try fallback
        const textarea = document.createElement('textarea')
        textarea.value = text
        document.body.appendChild(textarea)
        textarea.select()
        document.execCommand('copy')
        document.body.removeChild(textarea)
        this.showSuccess()
      })
    })
  },
  
  showSuccess() {
    // Change to checkmark icon and green color
    this.el.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="m4.5 12.75 6 6 9-13.5" /></svg>'
    this.el.classList.remove('btn-primary')
    this.el.classList.add('btn-success')
    
    // Reset after 2 seconds
    setTimeout(() => {
      this.el.innerHTML = this.originalHTML
      this.el.classList.remove('btn-success')
      this.el.classList.add('btn-primary')
    }, 2000)
  }
}

export const FocusOnMount = {
  mounted() {
    // Focus on the textarea when mounted
    this.el.focus()

    // Add event listener to combine new message with original when form is submitted
    const form = this.el.closest('form')
    if (form) {
      form.addEventListener('submit', (e) => {
        const newMessage = this.el.value.trim()
        const hiddenBodyField = form.querySelector('#full-message-body')
        const originalMessage = hiddenBodyField.value

        // Combine new message with original
        if (newMessage) {
          hiddenBodyField.value = newMessage + originalMessage
        } else {
          // If no new message, just use original (for forwarding without adding text)
          hiddenBodyField.value = originalMessage
        }
      })
    }
  }
}

export const TimelineReply = {
  mounted() {
    this.replyFocusPending = false
    this.queuedAnchor = null

    this.handleQueuedClick = (event) => {
      const queuedBtn = event.target.closest('[data-load-queued-posts]')
      if (!queuedBtn) return

      const postCards = Array.from(document.querySelectorAll('[data-post-id]'))
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight

      const anchor = postCards.find((card) => {
        const rect = card.getBoundingClientRect()
        return rect.bottom > 0 && rect.top < viewportHeight
      })

      if (anchor && anchor.dataset.postId) {
        this.queuedAnchor = {
          postId: anchor.dataset.postId,
          top: anchor.getBoundingClientRect().top
        }
      }
    }

    this.el.addEventListener('click', this.handleQueuedClick)

    // Focus and gently scroll active reply form into view without jumping around.
    this.handleEvent("focus_reply_form", ({ textarea_id, container_id }) => {
      this.replyFocusPending = true
      setTimeout(() => {
        const textarea = document.getElementById(textarea_id)
        const container = container_id ? document.getElementById(container_id) : null

        if (container) {
          const rect = container.getBoundingClientRect()
          const topGuard = 96
          const bottomGuard = 24
          const needsScroll =
            rect.top < topGuard || rect.bottom > (window.innerHeight - bottomGuard)

          if (needsScroll) {
            container.scrollIntoView({ behavior: 'smooth', block: 'center' })
          }
        }

        if (textarea) {
          textarea.focus()
          if (textarea.value) {
            textarea.setSelectionRange(textarea.value.length, textarea.value.length)
          }
        }
      }, 100)
    })
  },

  beforeUpdate() {
    // Intentionally no generic scroll preservation here.
    // Restoring window.scrollY on every LiveView patch can fight natural scrolling
    // when background timeline updates arrive.
  },

  updated() {
    if (this.queuedAnchor) {
      const anchor = document.querySelector(`[data-post-id="${this.queuedAnchor.postId}"]`)

      if (anchor) {
        const newTop = anchor.getBoundingClientRect().top
        const delta = newTop - this.queuedAnchor.top
        if (delta !== 0) window.scrollBy(0, delta)
      }

      this.queuedAnchor = null
      this.replyFocusPending = false
      return
    }

    this.replyFocusPending = false
  },

  destroyed() {
    this.el.removeEventListener('click', this.handleQueuedClick)
  }
}

export const FileDownloader = {
  mounted() {
    this.handleEvent("download_file", ({filename, data, content_type}) => {
      try {
        // Decode base64 data
        const binaryString = atob(data)
        const bytes = new Uint8Array(binaryString.length)
        for (let i = 0; i < binaryString.length; i++) {
          bytes[i] = binaryString.charCodeAt(i)
        }

        // Create blob and download
        const blob = new Blob([bytes], { type: content_type })
        const url = URL.createObjectURL(blob)

        const link = document.createElement('a')
        link.href = url
        link.download = filename
        link.style.display = 'none'

        document.body.appendChild(link)
        link.click()
        document.body.removeChild(link)

        // Clean up
        URL.revokeObjectURL(url)
      } catch (error) {
        console.error('Failed to download file:', error)
        // Show error to user via flash message
        this.pushEvent("download_error", {message: "Failed to download attachment"})
      }
    })
  }
}

export const IframeAutoResize = {
  mounted() {
    const iframe = this.el

    // Function to resize iframe based on content
    const resizeIframe = () => {
      try {
        // Reset height to allow shrinking
        iframe.style.height = 'auto'

        // Get the content document
        const contentDoc = iframe.contentWindow.document
        const contentBody = contentDoc.body

        // Only set basic overflow handling - don't break email styling
        contentBody.style.overflowX = 'auto'

        // Get the actual content height, accounting for scrollbars
        const contentHeight = Math.max(
          contentBody.scrollHeight,
          contentBody.offsetHeight,
          contentDoc.documentElement.scrollHeight,
          contentDoc.documentElement.offsetHeight
        )

        // Set minimum height of 400px, maximum of viewport height - 200px
        const maxHeight = window.innerHeight - 200
        const newHeight = Math.max(400, Math.min(contentHeight + 40, maxHeight))

        iframe.style.height = newHeight + 'px'

      } catch (e) {
        // Cross-origin or other errors, use default height
        iframe.style.height = '600px'
      }
    }

    // Resize on load
    iframe.addEventListener('load', resizeIframe)

    // Also try to resize after delays (for dynamic content)
    iframe.addEventListener('load', () => {
      setTimeout(resizeIframe, 100)
      setTimeout(resizeIframe, 500)
      setTimeout(resizeIframe, 1000) // Give more time for complex layouts
    })

    // Handle window resize events
    window.addEventListener('resize', resizeIframe)

    // Store the resize function for cleanup
    this.resizeFunction = resizeIframe
  },

  destroyed() {
    // Clean up event listener
    if (this.resizeFunction) {
      window.removeEventListener('resize', this.resizeFunction)
    }
  }
}

export const BackupCodesPrinter = {
  mounted() {
    // Extract backup codes from data attributes
    this.codes = JSON.parse(this.el.dataset.codes || '[]')

    // Add click handler to print button
    const printButton = this.el.querySelector('[data-action="print"]')
    if (printButton) {
      printButton.addEventListener('click', () => this.printCodes())
    }
  },

  printCodes() {
    const printWindow = window.open('', '_blank')

    const printContent = `
      <html>
      <head>
        <title>Elektrine Backup Codes</title>
        <style>
          body { font-family: Arial, sans-serif; padding: 20px; }
          .header { text-align: center; margin-bottom: 30px; }
          .codes-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; }
          .code { padding: 10px; border: 1px solid #ccc; text-align: center; font-family: monospace; font-size: 14px; }
          .warning { background-color: #fff3cd; border: 1px solid #ffeaa7; padding: 15px; margin-bottom: 20px; }
        </style>
      </head>
      <body>
        <div class="header">
          <h1>Elektrine Two-Factor Authentication</h1>
          <h2>Backup Codes</h2>
          <p>Generated on: ${new Date().toLocaleDateString()}</p>
        </div>

        <div class="warning">
          <strong>Important:</strong> Keep these codes safe and secure. Each code can only be used once to access your account if you lose your authenticator device.
        </div>

        <div class="codes-grid">
          ${this.codes.map(code => `<div class="code">${code}</div>`).join('')}
        </div>
      </body>
      </html>
    `

    printWindow.document.write(printContent)
    printWindow.document.close()
    printWindow.print()
  }
}

// Preserve details/dropdown open state across LiveView re-renders
export const DetailsPreserve = {
  mounted() {
    this._wasOpen = false
  },

  beforeUpdate() {
    this._wasOpen = this.el.open
  },

  updated() {
    if (this._wasOpen) {
      this.el.open = true
    }
  }
}

// Apple-like glass card effect that follows cursor
export const GlassCard = {
  mounted() {
    this.initGlassEffect(this.el)
  },

  beforeUpdate() {
    // Save current position before DOM update
    this._savedX = this.el._lastX
    this._savedY = this.el._lastY
  },

  updated() {
    // Re-init if element lost its listeners
    if (!this.el._glassCardInit) {
      this.initGlassEffect(this.el)
    }

    // Restore CSS properties after DOM update (LiveView may have reset inline styles)
    if (this._savedX && this._savedY) {
      this.el.style.setProperty('--mouse-x', `${this._savedX}px`)
      this.el.style.setProperty('--mouse-y', `${this._savedY}px`)
      this.el._lastX = this._savedX
      this.el._lastY = this._savedY
    }
  },

  initGlassEffect(element) {
    if (element._glassCardInit) return

    // Use requestAnimationFrame to throttle updates and prevent layout thrashing
    element._rafId = null
    element._lastX = 0
    element._lastY = 0
    element._paused = false

    element._handleMouseMove = (e) => {
      // Skip if paused (during click/collapse) or already waiting for animation frame
      if (element._paused || element._rafId) return

      element._rafId = requestAnimationFrame(() => {
        const rect = element.getBoundingClientRect()
        const x = e.clientX - rect.left
        const y = e.clientY - rect.top

        // Only update if position changed significantly (reduces repaints)
        if (Math.abs(x - element._lastX) > 1 || Math.abs(y - element._lastY) > 1) {
          element.style.setProperty('--mouse-x', `${x}px`)
          element.style.setProperty('--mouse-y', `${y}px`)
          element._lastX = x
          element._lastY = y
        }

        element._rafId = null
      })
    }

    element._handleMouseLeave = () => {
      // Cancel any pending animation frame
      if (element._rafId) {
        cancelAnimationFrame(element._rafId)
        element._rafId = null
      }
      element.style.setProperty('--mouse-x', '-1000px')
      element.style.setProperty('--mouse-y', '-1000px')
      element._lastX = 0
      element._lastY = 0
    }

    // Pause tracking during clicks to prevent glitches when collapsible elements change size
    element._handleClick = () => {
      element._paused = true
      // Resume tracking after collapse animation completes
      setTimeout(() => {
        element._paused = false
      }, 350)
    }

    element.addEventListener('mousemove', element._handleMouseMove, { passive: true })
    element.addEventListener('mouseleave', element._handleMouseLeave, { passive: true })
    element.addEventListener('click', element._handleClick, { capture: true, passive: true })
    element._glassCardInit = true
  },

  destroyed() {
    if (this.el._rafId) {
      cancelAnimationFrame(this.el._rafId)
    }
    if (this.el._handleMouseMove) {
      this.el.removeEventListener('mousemove', this.el._handleMouseMove)
    }
    if (this.el._handleMouseLeave) {
      this.el.removeEventListener('mouseleave', this.el._handleMouseLeave)
    }
    if (this.el._handleClick) {
      this.el.removeEventListener('click', this.el._handleClick, { capture: true })
    }
    this.el._glassCardInit = false
  }
}

// Container hook that initializes glass effect on all child .glass-card elements
export const GlassCardContainer = {
  mounted() {
    this.initAllCards()
  },

  beforeUpdate() {
    // Save positions of all cards before DOM update
    this._savedPositions = new Map()
    const cards = this.el.querySelectorAll('.glass-card')
    cards.forEach((card, index) => {
      if (card._lastX || card._lastY) {
        this._savedPositions.set(index, { x: card._lastX, y: card._lastY })
      }
    })
  },

  updated() {
    this.initAllCards()

    // Restore positions after DOM update
    if (this._savedPositions && this._savedPositions.size > 0) {
      const cards = this.el.querySelectorAll('.glass-card')
      cards.forEach((card, index) => {
        const saved = this._savedPositions.get(index)
        if (saved && (saved.x || saved.y)) {
          card.style.setProperty('--mouse-x', `${saved.x}px`)
          card.style.setProperty('--mouse-y', `${saved.y}px`)
          card._lastX = saved.x
          card._lastY = saved.y
        }
      })
    }
  },

  initAllCards() {
    const cards = this.el.querySelectorAll('.glass-card')
    cards.forEach(card => {
      if (card._glassCardInit) return

      // Use requestAnimationFrame to throttle updates
      card._rafId = null
      card._lastX = 0
      card._lastY = 0
      card._paused = false

      card._handleMouseMove = (e) => {
        if (card._paused || card._rafId) return

        card._rafId = requestAnimationFrame(() => {
          const rect = card.getBoundingClientRect()
          const x = e.clientX - rect.left
          const y = e.clientY - rect.top

          if (Math.abs(x - card._lastX) > 1 || Math.abs(y - card._lastY) > 1) {
            card.style.setProperty('--mouse-x', `${x}px`)
            card.style.setProperty('--mouse-y', `${y}px`)
            card._lastX = x
            card._lastY = y
          }

          card._rafId = null
        })
      }

      card._handleMouseLeave = () => {
        if (card._rafId) {
          cancelAnimationFrame(card._rafId)
          card._rafId = null
        }
        card.style.setProperty('--mouse-x', '-1000px')
        card.style.setProperty('--mouse-y', '-1000px')
        card._lastX = 0
        card._lastY = 0
      }

      // Pause tracking during clicks to prevent glitches when collapsible elements change size
      card._handleClick = () => {
        card._paused = true
        setTimeout(() => {
          card._paused = false
        }, 350)
      }

      card.addEventListener('mousemove', card._handleMouseMove, { passive: true })
      card.addEventListener('mouseleave', card._handleMouseLeave, { passive: true })
      card.addEventListener('click', card._handleClick, { capture: true, passive: true })
      card._glassCardInit = true
    })
  },

  destroyed() {
    const cards = this.el.querySelectorAll('.glass-card')
    cards.forEach(card => {
      if (card._rafId) {
        cancelAnimationFrame(card._rafId)
      }
      if (card._handleMouseMove) {
        card.removeEventListener('mousemove', card._handleMouseMove)
      }
      if (card._handleMouseLeave) {
        card.removeEventListener('mouseleave', card._handleMouseLeave)
      }
      if (card._handleClick) {
        card.removeEventListener('click', card._handleClick, { capture: true })
      }
      card._glassCardInit = false
    })
  }
}

// Scroll to top button that appears when scrolled down
export const ScrollToTop = {
  mounted() {
    this.scrollThreshold = 400 // Show button after scrolling 400px

    this.handleScroll = () => {
      if (window.scrollY > this.scrollThreshold) {
        this.el.classList.remove('opacity-0', 'pointer-events-none')
        this.el.classList.add('opacity-100', 'pointer-events-auto')
      } else {
        this.el.classList.remove('opacity-100', 'pointer-events-auto')
        this.el.classList.add('opacity-0', 'pointer-events-none')
      }
    }

    this.el.addEventListener('click', () => {
      window.scrollTo({
        top: 0,
        behavior: 'smooth'
      })
    })

    window.addEventListener('scroll', this.handleScroll, { passive: true })

    // Initial check
    this.handleScroll()
  },

  destroyed() {
    window.removeEventListener('scroll', this.handleScroll)
  }
}

/**
 * ScrollToBottom - Auto-scrolls container to bottom when content changes
 * Used for chat/activity interfaces to keep newest content visible
 *
 * Features:
 * - Respects user scroll position - won't auto-scroll if user scrolled up
 * - Shows "Jump to bottom" button when user scrolls up
 * - Tracks new items count when scrolled up
 * - Only resets scroll lock when user clicks the button
 */
export const ScrollToBottom = {
  mounted() {
    this.userScrolledUp = false
    this.lastScrollTop = 0
    this.scrollThreshold = 150 // pixels from bottom to consider "at bottom"
    this.newItemsWhileScrolledUp = 0
    this.scrollLocked = false // True when user has intentionally scrolled up

    // Create jump-to-bottom button
    this.createJumpButton()

    // Track user scroll with intent detection
    this.handleScroll = () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el
      const distanceFromBottom = scrollHeight - scrollTop - clientHeight
      const isAtBottom = distanceFromBottom < this.scrollThreshold

      // Detect intentional scroll UP (not just content pushing)
      if (scrollTop < this.lastScrollTop && !isAtBottom) {
        this.scrollLocked = true
        this.showJumpButton()
      }

      // If user scrolls back to bottom manually, unlock
      if (isAtBottom && this.scrollLocked) {
        this.scrollLocked = false
        this.newItemsWhileScrolledUp = 0
        this.hideJumpButton()
      }

      this.lastScrollTop = scrollTop
      this.userScrolledUp = !isAtBottom
    }

    this.el.addEventListener('scroll', this.handleScroll, { passive: true })

    // Initial scroll to bottom
    requestAnimationFrame(() => this.scrollToBottom())
  },

  updated() {
    // Only auto-scroll if:
    // 1. data-follow is true (scan is running)
    // 2. User hasn't locked scroll by scrolling up
    if (this.el.dataset.follow === "true" && !this.scrollLocked) {
      requestAnimationFrame(() => this.scrollToBottom())
    } else if (this.scrollLocked) {
      // Track new items when scrolled up
      this.newItemsWhileScrolledUp++
      this.updateJumpButtonCount()
    }
  },

  destroyed() {
    this.el.removeEventListener('scroll', this.handleScroll)
    if (this.jumpButton && this.jumpButton.parentNode) {
      this.jumpButton.parentNode.removeChild(this.jumpButton)
    }
  },

  createJumpButton() {
    this.jumpButton = document.createElement('button')
    this.jumpButton.className = 'fixed bottom-24 right-8 z-50 btn btn-primary btn-sm shadow-lg gap-2 opacity-0 pointer-events-none transition-all duration-200 transform translate-y-2'
    this.jumpButton.innerHTML = `
      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3"/>
      </svg>
      <span class="jump-text">Jump to bottom</span>
    `
    this.jumpButton.addEventListener('click', () => {
      this.scrollLocked = false
      this.newItemsWhileScrolledUp = 0
      this.scrollToBottom()
      this.hideJumpButton()
    })

    // Append to parent container or body
    const parent = this.el.closest('.card-body') || this.el.parentNode || document.body
    parent.style.position = 'relative'
    parent.appendChild(this.jumpButton)
  },

  showJumpButton() {
    if (this.jumpButton) {
      this.jumpButton.classList.remove('opacity-0', 'pointer-events-none', 'translate-y-2')
      this.jumpButton.classList.add('opacity-100', 'pointer-events-auto', 'translate-y-0')
    }
  },

  hideJumpButton() {
    if (this.jumpButton) {
      this.jumpButton.classList.add('opacity-0', 'pointer-events-none', 'translate-y-2')
      this.jumpButton.classList.remove('opacity-100', 'pointer-events-auto', 'translate-y-0')
    }
  },

  updateJumpButtonCount() {
    if (this.jumpButton && this.newItemsWhileScrolledUp > 0) {
      const textEl = this.jumpButton.querySelector('.jump-text')
      if (textEl) {
        textEl.textContent = `${this.newItemsWhileScrolledUp} new`
      }
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
    this.lastScrollTop = this.el.scrollTop
  }
}

/**
 * ImageFallback - Handles image load errors without inline event handlers
 * Hides the image and shows a fallback element when image fails to load
 *
 * Usage:
 *   <img src="..." phx-hook="ImageFallback" data-fallback-class="hidden" />
 *   <div data-fallback-icon class="hidden">Fallback content</div>
 *
 * The hook will hide the img and show elements with [data-fallback-icon]
 */
export const ImageFallback = {
  mounted() {
    this.el.addEventListener('error', () => {
      // Hide the image
      this.el.style.display = 'none'

      // Show the next sibling with data-fallback-icon if present
      const fallback = this.el.nextElementSibling
      if (fallback && fallback.hasAttribute('data-fallback-icon')) {
        fallback.style.display = 'flex'
        fallback.classList.remove('hidden')
      }
    })

    // Also handle case where image is already broken (cached error)
    if (this.el.complete && this.el.naturalHeight === 0) {
      this.el.dispatchEvent(new Event('error'))
    }
  }
}

/**
 * StopPropagation - Prevents click events from bubbling up to parent elements.
 * Used for interactive elements (buttons) nested inside clickable containers (links).
 * Replaces inline onclick="event.stopPropagation()" handlers.
 */
export const StopPropagation = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      e.stopPropagation()
    })
  }
}

// 3D tilt effect that follows mouse position with smooth easing
export const Tilt3D = {
  mounted() {
    this.maxTilt = 12 // max tilt in degrees
    this.ease = 0.08 // easing factor (lower = smoother)

    // Current and target values
    this.currentX = 0
    this.currentY = 0
    this.targetX = 0
    this.targetY = 0
    this.animating = false

    this.animate = () => {
      // Lerp toward target
      this.currentX += (this.targetX - this.currentX) * this.ease
      this.currentY += (this.targetY - this.currentY) * this.ease

      this.el.style.setProperty('--tilt-x', `${this.currentX}deg`)
      this.el.style.setProperty('--tilt-y', `${this.currentY}deg`)

      // Keep animating if not close enough to target
      if (Math.abs(this.targetX - this.currentX) > 0.01 ||
          Math.abs(this.targetY - this.currentY) > 0.01) {
        requestAnimationFrame(this.animate)
      } else {
        this.animating = false
      }
    }

    this.startAnimation = () => {
      if (!this.animating) {
        this.animating = true
        requestAnimationFrame(this.animate)
      }
    }

    this.handleMouseMove = (e) => {
      const rect = this.el.getBoundingClientRect()
      const centerX = rect.left + rect.width / 2
      const centerY = rect.top + rect.height / 2

      // Calculate distance from center (-1 to 1)
      const percentX = (e.clientX - centerX) / (rect.width / 2)
      const percentY = (e.clientY - centerY) / (rect.height / 2)

      // Set target tilt (invert Y for natural feel)
      this.targetX = -percentY * this.maxTilt
      this.targetY = percentX * this.maxTilt

      this.startAnimation()
    }

    this.handleMouseLeave = () => {
      this.targetX = 0
      this.targetY = 0
      this.startAnimation()
    }

    this.el.addEventListener('mousemove', this.handleMouseMove)
    this.el.addEventListener('mouseleave', this.handleMouseLeave)
  },

  destroyed() {
    this.el.removeEventListener('mousemove', this.handleMouseMove)
    this.el.removeEventListener('mouseleave', this.handleMouseLeave)
  }
}
