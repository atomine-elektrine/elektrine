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
    this.prePatchAnchor = null
    this.prePatchScrollY = null
    this.prePatchHadFeedSkeleton = this.feedSkeletonVisible()
    this.prePatchShouldPreserve = false

    this.handleQueuedClick = (event) => {
      const queuedBtn = event.target.closest('[data-load-queued-posts]')
      if (!queuedBtn) return

      this.queuedAnchor = this.findVisiblePostAnchor()
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
    this.prePatchHadFeedSkeleton = this.feedSkeletonVisible()
    this.prePatchShouldPreserve = this.shouldPreserveFeedPatch()

    if (this.prePatchShouldPreserve) {
      this.prePatchAnchor = this.findVisiblePostAnchor()
      this.prePatchScrollY = window.scrollY
    } else {
      this.prePatchAnchor = null
      this.prePatchScrollY = null
    }
  },

  updated() {
    const hasFeedSkeleton = this.feedSkeletonVisible()

    if (this.queuedAnchor) {
      this.restoreAnchorPosition(this.queuedAnchor, null)

      this.queuedAnchor = null
      this.prePatchAnchor = null
      this.prePatchScrollY = null
      this.prePatchHadFeedSkeleton = hasFeedSkeleton
      this.prePatchShouldPreserve = false
      this.replyFocusPending = false
      return
    }

    if (this.prePatchShouldPreserve) {
      this.restoreAnchorPosition(this.prePatchAnchor, this.prePatchScrollY)
    } else if (
      this.prePatchHadFeedSkeleton !== hasFeedSkeleton &&
      typeof this.prePatchScrollY === 'number'
    ) {
      window.scrollTo({ top: this.prePatchScrollY, behavior: 'auto' })
    }

    this.prePatchAnchor = null
    this.prePatchScrollY = null
    this.prePatchHadFeedSkeleton = hasFeedSkeleton
    this.prePatchShouldPreserve = false
    this.replyFocusPending = false
  },

  findVisiblePostAnchor() {
    const postCards = this.el.querySelectorAll('[data-post-id]')
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight

    for (const card of postCards) {
      const rect = card.getBoundingClientRect()
      if (rect.bottom <= 0 || rect.top >= viewportHeight) continue

      const postId = card.dataset.postId
      if (!postId) continue

      return {
        postId,
        top: rect.top
      }
    }

    return null
  },

  restoreAnchorPosition(anchorSnapshot, fallbackScrollY) {
    if (anchorSnapshot?.postId) {
      const anchor = this.findPostById(anchorSnapshot.postId)

      if (anchor) {
        const newTop = anchor.getBoundingClientRect().top
        const delta = newTop - anchorSnapshot.top
        if (delta !== 0) window.scrollBy(0, delta)
        return
      }
    }

    if (typeof fallbackScrollY === 'number') {
      window.scrollTo({ top: fallbackScrollY, behavior: 'auto' })
    }
  },

  findPostById(postId) {
    if (!postId) return null

    const escapedPostId = typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(postId) : postId
    return this.el.querySelector(`[data-post-id="${escapedPostId}"]`)
  },

  shouldPreserveFeedPatch() {
    if (this.timelineLoadMoreActive()) return false

    return this.feedSkeletonVisible() || this.el.querySelector('[data-post-id]') !== null
  },

  feedSkeletonVisible() {
    return this.el.querySelector('[data-feed-loading-skeleton], [data-timeline-loading-skeleton]') !== null
  },

  timelineLoadMoreActive() {
    const infiniteScrollRoot = this.el.querySelector('#timeline-infinite-scroll')
    return infiniteScrollRoot?.dataset?.loadingMore === 'true'
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
    this.codes = JSON.parse(this.el.dataset.codes || '[]')
    initBackupCodesPrinter(this.el)
  },

  destroyed() {
    destroyBackupCodesPrinter(this.el)
  },

  printCodes() {
    printBackupCodes(this.codes || [])
  }
}

export function initBackupCodesPrinter(element) {
  if (!element || element.dataset.backupCodesPrinterInitialized === 'true') return

  const printButton = element.querySelector('[data-action="print"]')
  if (!printButton) return

  const handlePrint = () => {
    const codes = JSON.parse(element.dataset.codes || '[]')
    printBackupCodes(codes)
  }

  printButton.addEventListener('click', handlePrint)

  element._backupCodesPrinterCleanup = () => {
    printButton.removeEventListener('click', handlePrint)
  }

  element.dataset.backupCodesPrinterInitialized = 'true'
}

export function destroyBackupCodesPrinter(element) {
  if (!element) return

  if (typeof element._backupCodesPrinterCleanup === 'function') {
    element._backupCodesPrinterCleanup()
    delete element._backupCodesPrinterCleanup
  }

  delete element.dataset.backupCodesPrinterInitialized
}

export function initBackupCodesPrinters(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === 'function' ? rootCandidate : document

  root.querySelectorAll('[data-backup-codes-printer]').forEach((element) => {
    initBackupCodesPrinter(element)
  })
}

function printBackupCodes(codes) {
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
        ${codes.map(code => `<div class="code">${code}</div>`).join('')}
      </div>
    </body>
    </html>
  `

  printWindow.document.write(printContent)
  printWindow.document.close()
  printWindow.print()
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

export const GlassCard = {
  mounted() {},
  beforeUpdate() {},
  updated() {},
  destroyed() {}
}

export const GlassCardContainer = {
  mounted() {},
  beforeUpdate() {},
  updated() {},
  destroyed() {}
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
