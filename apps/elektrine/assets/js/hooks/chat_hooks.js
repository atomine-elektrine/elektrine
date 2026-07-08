// Chat-specific LiveView hooks

import { submitFormPreservingEvents } from "../utils/form_submission"

export const AutoExpandTextarea = {
  mounted() {
    this.timeouts = []
    this.sendingMessage = false
    this.lastSentContent = ""
    this.lastSentTime = 0
    this.lastLiveUpdateValue = null
    this.userResized = false // Track if user manually resized
    this.currentHeight = null // Track current height to preserve during LiveView updates
    this.liveUpdateEvent = this.el.dataset.liveUpdateEvent
    this.submitOnEnter = this.el.dataset.submitOnEnter !== 'false'

    // Get min/max heights from style attribute
    const style = this.el.getAttribute('style') || ''
    const minMatch = style.match(/min-height:\s*([0-9.]+)rem/)
    const maxMatch = style.match(/max-height:\s*([0-9.]+)rem/)
    this.minHeight = minMatch ? parseFloat(minMatch[1]) * 16 : 40 // Convert rem to px
    this.maxHeight = maxMatch ? parseFloat(maxMatch[1]) * 16 : 160

    // Store original style to preserve it
    this.originalStyle = this.el.getAttribute('style') || ''

    // Auto-expand textarea function
    const queueTimeout = (callback, delay) => {
      const timer = setTimeout(() => {
        this.timeouts = this.timeouts.filter((timeout) => timeout !== timer)
        callback()
      }, delay)

      this.timeouts.push(timer)
      return timer
    }

    this.queueTimeout = queueTimeout

    const adjustHeight = () => {
      // Don't adjust if user has manually resized
      if (this.userResized) return

      // Store current scroll position
      const scrollPos = this.el.scrollTop

      // Temporarily set height to auto to measure content
      // But preserve other inline styles
      const currentStyleObj = this.el.style
      const oldHeight = currentStyleObj.height
      currentStyleObj.height = 'auto'

      // Calculate new height based on content
      const newHeight = Math.max(this.minHeight, Math.min(this.el.scrollHeight, this.maxHeight))

      // Set the new height while preserving other styles
      currentStyleObj.height = newHeight + 'px'
      this.currentHeight = newHeight // Store for LiveView updates

      // Restore scroll position if needed
      if (newHeight >= this.maxHeight) {
        this.el.scrollTop = scrollPos
      }
    }

    // Store the adjustHeight function
    this.adjustHeight = adjustHeight

    // Detect manual resize (mouseup on the resize handle)
    this.onMouseDown = (e) => {
      // Check if click is in the bottom right (resize handle area)
      const rect = this.el.getBoundingClientRect()
      const isResizeHandle = e.clientX > rect.right - 20 && e.clientY > rect.bottom - 20

      if (isResizeHandle) {
        this.userResized = true
      }
    }

    this.el.addEventListener('mousedown', this.onMouseDown)

    // Adjust height on any input or change
    const handleInput = () => {
      requestAnimationFrame(() => adjustHeight())

      if (this.liveUpdateEvent && this.el.value !== this.lastLiveUpdateValue) {
        this.lastLiveUpdateValue = this.el.value
        this.pushEvent(this.liveUpdateEvent, { value: this.el.value })
      }
    }

    this.handleInput = handleInput

    this.el.addEventListener('input', handleInput)
    this.el.addEventListener('change', handleInput)
    this.onPaste = () => queueTimeout(handleInput, 10)
    this.el.addEventListener('paste', this.onPaste)

    // Handle keyboard shortcuts
    this.onKeyDown = (e) => {
      // Allow Shift+Enter for new line
      if (e.key === "Enter" && e.shiftKey) {
        // Let the default behavior happen (insert newline)
        queueTimeout(() => adjustHeight(), 10)
        return
      }

      if (e.key === "Enter" && !e.shiftKey && !this.submitOnEnter) {
        queueTimeout(() => adjustHeight(), 10)
        return
      }

      // Send message on Enter (without Shift)
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()

        const content = this.el.value.trim()
        const now = Date.now()

        // Enhanced duplicate prevention
        if (this.sendingMessage ||
            !content ||
            (content === this.lastSentContent && (now - this.lastSentTime) < 500)) {
          return
        }

        const form = this.el.closest("form")
        if (form) {
          this.sendingMessage = true
          this.lastSentContent = content
          this.lastSentTime = now

          const submitBtn = form.querySelector('button[type="submit"]')
          submitFormPreservingEvents(form, submitBtn?.disabled ? null : submitBtn)

          // Disable the submit button temporarily after LiveView receives the submit.
          if (submitBtn) {
            submitBtn.disabled = true
          }

          // Reset after submit
          queueTimeout(() => {
            this.el.value = ""
            this.el.style.height = this.minHeight + 'px'
            this.currentHeight = this.minHeight
            this.userResized = false
            this.sendingMessage = false
            if (submitBtn) {
              submitBtn.disabled = false
            }
          }, 100)
        }
      }
    }

    this.el.addEventListener("keydown", this.onKeyDown)

    // Handle clear message input event
    this.handleEvent("clear_message_input", () => {
      this.sendingMessage = false
      this.userResized = false
      this.el.value = ""
      // Use style object to preserve other CSS properties
      this.el.style.height = this.minHeight + 'px'
      this.currentHeight = this.minHeight
      this.el.focus()

      // Re-enable submit button
      const form = this.el.closest("form")
      if (form) {
        const submitBtn = form.querySelector('button[type="submit"]')
        if (submitBtn) {
          submitBtn.disabled = false
        }
      }
    })

    // Handle reset textarea event (for explicit resets)
    this.handleEvent("reset_textarea", ({id}) => {
      if (this.el.id === id) {
        this.sendingMessage = false
        this.userResized = false
        this.el.value = ""
        // Use style object to preserve other CSS properties
        this.el.style.height = this.minHeight + 'px'
        this.currentHeight = this.minHeight

        // Re-enable submit button
        const form = this.el.closest("form")
        if (form) {
          const submitBtn = form.querySelector('button[type="submit"]')
          if (submitBtn) {
            submitBtn.disabled = false
          }
        }
      }
    })

    // Listen for form submit to clear the textarea
    const form = this.el.closest("form")
    if (form) {
      this.form = form
      this.onFormSubmit = () => {
        queueTimeout(() => {
          this.el.value = ""
          // Use style object to preserve other CSS properties
          this.el.style.height = this.minHeight + 'px'
          this.currentHeight = this.minHeight
          this.userResized = false
        }, 100)
      }

      form.addEventListener('submit', this.onFormSubmit)
    }

    // Set initial height to match reset height for consistency
    this.el.style.height = this.minHeight + 'px'
    this.currentHeight = this.minHeight

    // Initial height adjustment (in case there's pre-filled content)
    queueTimeout(() => {
      adjustHeight()
    }, 0)
  },

  updated() {
    // With phx-update="ignore", this shouldn't be called at all
    // But as a safety net, restore the height if needed
    if (this.currentHeight) {
      // Use style object to preserve other CSS properties
      this.el.style.height = this.currentHeight + 'px'
    }

    // Reset sending state
    this.sendingMessage = false
  },

  destroyed() {
    if (this.onMouseDown) this.el.removeEventListener('mousedown', this.onMouseDown)
    if (this.handleInput) {
      this.el.removeEventListener('input', this.handleInput)
      this.el.removeEventListener('change', this.handleInput)
    }
    if (this.onPaste) this.el.removeEventListener('paste', this.onPaste)
    if (this.onKeyDown) this.el.removeEventListener('keydown', this.onKeyDown)
    if (this.form && this.onFormSubmit) this.form.removeEventListener('submit', this.onFormSubmit)

    ;(this.timeouts || []).forEach((timer) => clearTimeout(timer))
    this.timeouts = []
  }
}

export const SimpleChatInput = {
  mounted() {
    this.maxHeight = 150
    this.form = this.el.closest("form")
    this.awaitingSubmitClear = false
    this.valueBeforeUpdate = ""
    this.wasFocusedBeforeUpdate = false

    this.el.rows = 1
    this.el.style.boxSizing = 'border-box'
    this.baseHeight = Math.ceil(this.el.getBoundingClientRect().height || this.el.scrollHeight)
    this.el.style.height = this.baseHeight + 'px'
    this.el.style.overflowY = 'hidden'

    this.autoResize = () => {
      this.el.style.height = 'auto'
      const scrollHeight = this.el.scrollHeight
      const newHeight = scrollHeight <= this.baseHeight + 2
        ? this.baseHeight
        : Math.min(scrollHeight, this.maxHeight)
      this.el.style.height = newHeight + 'px'
      this.el.style.overflowY = scrollHeight > this.maxHeight ? 'auto' : 'hidden'
    }

    this.handleInput = () => {
      if (this.awaitingSubmitClear) {
        this.awaitingSubmitClear = false
      }

      this.autoResize()
    }

    this.el.addEventListener("input", this.handleInput)

    // Enter key handling
    this.handleKeydown = (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        if (this.form && this.el.value.trim()) {
          this.awaitingSubmitClear = true
          const submitter = this.form.querySelector('button[type="submit"]')
          submitFormPreservingEvents(this.form, submitter?.disabled ? null : submitter)
        }
      }
    }

    this.el.addEventListener("keydown", this.handleKeydown)

    if (this.form) {
      this.handleFormSubmit = () => {
        this.awaitingSubmitClear = true
      }

      this.form.addEventListener("submit", this.handleFormSubmit)
    }

    this.handleEvent("clear_message_input", () => {
      this.awaitingSubmitClear = false
      this.el.value = ""
      this.autoResize()
      this.el.focus()
    })

    this.focusComposer = () => {
      const activeElement = document.activeElement
      const activeTag = activeElement?.tagName
      const activeIsTypingTarget = activeTag === "INPUT" || activeTag === "TEXTAREA" || activeTag === "SELECT"
      const overlayActive =
        document.getElementById("chat-keyboard-shortcuts")?.dataset.activeOverlay === "true"

      if (
        window.matchMedia("(min-width: 640px)").matches &&
        !activeIsTypingTarget &&
        !overlayActive
      ) {
        this.el.focus({ preventScroll: true })
      }
    }

    setTimeout(this.focusComposer, 0)
  },

  beforeUpdate() {
    this.valueBeforeUpdate = this.el.value
    this.wasFocusedBeforeUpdate = document.activeElement === this.el
  },

  updated() {
    if (this.awaitingSubmitClear) {
      if (this.el.value === "") {
        this.awaitingSubmitClear = false
      }

      this.autoResize()
      return
    }

    // Keep local draft if an unrelated patch tries to shorten it while typing.
    if (
      this.wasFocusedBeforeUpdate &&
      this.valueBeforeUpdate &&
      this.el.value.length < this.valueBeforeUpdate.length
    ) {
      const cursorPosition = this.el.selectionStart
      this.el.value = this.valueBeforeUpdate

      if (cursorPosition !== null) {
        const safePosition = Math.min(cursorPosition, this.el.value.length)
        this.el.setSelectionRange(safePosition, safePosition)
      }
    }

    // Restore height after LiveView re-render
    this.autoResize()
  },

  destroyed() {
    if (this.handleInput) {
      this.el.removeEventListener("input", this.handleInput)
    }

    if (this.handleKeydown) {
      this.el.removeEventListener("keydown", this.handleKeydown)
    }

    if (this.form && this.handleFormSubmit) {
      this.form.removeEventListener("submit", this.handleFormSubmit)
    }
  }
}

export const ChatKeyboardShortcuts = {
  mounted() {
    this.handleKeydown = (event) => {
      if (event.key !== "Escape" || event.defaultPrevented) return
      if (this.el.dataset.activeOverlay !== "true") return

      event.preventDefault()
      this.pushEvent("close_chat_overlay", {})
    }

    document.addEventListener("keydown", this.handleKeydown)
  },

  destroyed() {
    if (this.handleKeydown) {
      document.removeEventListener("keydown", this.handleKeydown)
    }
  }
}

export const MessageList = {
  mounted() {
    const container = this.el
    this.isLoadingOlder = false
    this.initialScrollDone = false
    this.isRestoringScroll = false
    this.currentConversationId = container.dataset.conversationId
    this.scrollPositions = window.elektrineChatScrollPositions || new Map()
    window.elektrineChatScrollPositions = this.scrollPositions

    // Check if user is near bottom (within 150px)
    const isNearBottom = () => {
      return container.scrollHeight - container.scrollTop - container.clientHeight < 150
    }

    const maxScrollTop = () => Math.max(0, container.scrollHeight - container.clientHeight)

    const saveCurrentScrollPosition = () => {
      if (!this.currentConversationId) return
      if (this.isRestoringScroll) return

      this.scrollPositions.set(String(this.currentConversationId), {
        top: container.scrollTop,
        atBottom: isNearBottom()
      })
    }

    // Smoothly scroll to bottom
    const scrollToBottom = (behavior = 'smooth') => {
      requestAnimationFrame(() => {
        container.scrollTo({
          top: container.scrollHeight,
          behavior: behavior
        })
        saveCurrentScrollPosition()
      })
    }

    const scrollElementInContainer = (element, block = 'center', behavior = 'smooth') => {
      const containerRect = container.getBoundingClientRect()
      const elementRect = element.getBoundingClientRect()
      const elementTop = elementRect.top - containerRect.top + container.scrollTop
      let targetTop

      if (block === 'top-third') {
        targetTop = elementTop - container.clientHeight / 3
      } else if (block === 'start') {
        targetTop = elementTop
      } else {
        targetTop = elementTop - container.clientHeight / 2 + elementRect.height / 2
      }

      container.scrollTo({
        top: Math.max(0, Math.min(targetTop, maxScrollTop())),
        behavior
      })
      saveCurrentScrollPosition()
    }

    this.restoreConversationScroll = (conversationId = this.currentConversationId) => {
      const savedPosition = conversationId && this.scrollPositions.get(String(conversationId))
      const restoreToken = Symbol('restore-scroll')
      this.restoreToken = restoreToken
      this.isRestoringScroll = true

      const restore = () => {
        if (savedPosition && !savedPosition.atBottom) {
          container.scrollTo({
            top: Math.min(savedPosition.top, maxScrollTop()),
            behavior: 'auto'
          })
          saveCurrentScrollPosition()
        } else {
          scrollToBottom('auto')
        }
      }

      restore()

      ;[50, 120, 250, 500].forEach(delay => {
        setTimeout(restore, delay)
      })

      setTimeout(() => {
        if (this.restoreToken !== restoreToken) return

        this.isRestoringScroll = false
        this.initialScrollDone = true
        saveCurrentScrollPosition()
      }, 600)
    }

    // Show/hide "jump to bottom" button when scrolled up
    const updateJumpButton = () => {
      const hasScrolledUp = !isNearBottom()
      const jumpBtn = document.getElementById('jump-to-bottom')
      if (jumpBtn) {
        if (hasScrolledUp && this.initialScrollDone) {
          jumpBtn.classList.remove('hidden')
        } else {
          jumpBtn.classList.add('hidden')
        }
      }
    }

    // Function to check scroll position and load more messages
    const checkScrollPosition = () => {
      const scrollTop = container.scrollTop

      // Update jump button visibility
      updateJumpButton()

      // Load older messages when scrolled near top (within 100px)
      if (scrollTop < 100 && !this.isLoadingOlder) {
        this.isLoadingOlder = true
        this.pushEvent("load_older_messages", {})
      }

      // Reset loading flag when scroll position changes
      if (scrollTop > 200) {
        this.isLoadingOlder = false
      }
    }

    // Add scroll event listener with debouncing
    let scrollTimeout
    container.addEventListener('scroll', () => {
      saveCurrentScrollPosition()
      clearTimeout(scrollTimeout)
      scrollTimeout = setTimeout(checkScrollPosition, 100)
    })

    // Handle maintaining scroll position after loading older messages
    this.handleEvent("maintain_scroll_position", () => {
      const prevHeight = container.scrollHeight
      requestAnimationFrame(() => {
        const newHeight = container.scrollHeight
        const heightDiff = newHeight - prevHeight
        container.scrollTop += heightDiff
        this.isLoadingOlder = false
      })
    })

    // Handle scroll to specific message
    this.handleEvent("scroll_to_message", ({message_id}) => {
      const messageEl = document.getElementById(`message-${message_id}`)
      if (messageEl) {
        scrollElementInContainer(messageEl, 'center', 'smooth')
        messageEl.classList.add('highlight-message')
        setTimeout(() => messageEl.classList.remove('highlight-message'), 2000)
        this.initialScrollDone = true
      }
    })

    // Handle image loading - re-scroll if user is at bottom
    let pendingImageLoads = 0

    const handleImageLoad = () => {
      pendingImageLoads = Math.max(0, pendingImageLoads - 1)

      // Only re-scroll if user is still near bottom and initial scroll is done
      if (this.initialScrollDone && isNearBottom()) {
        scrollToBottom('auto')

        // Do one more scroll after a delay to catch any dimension changes
        setTimeout(() => {
          if (isNearBottom()) {
            scrollToBottom('auto')
          }
        }, 100)
      }
    }

    const imagesFromNode = (node) => {
      if (node.nodeType !== Node.ELEMENT_NODE) return []

      const images = node.tagName === 'IMG' ? [node] : []
      return images.concat(Array.from(node.querySelectorAll?.('img') || []))
    }

    // Add listeners only within the changed subtree instead of rescanning the full chat.
    const addImageListeners = (root = container) => {
      const images = root === container ? container.querySelectorAll('img') : imagesFromNode(root)
      images.forEach(img => {
        if (!img.dataset.listenerAdded) {
          img.dataset.listenerAdded = 'true'

          if (!img.complete) {
            pendingImageLoads++
            img.addEventListener('load', handleImageLoad, { once: true })
            img.addEventListener('error', handleImageLoad, { once: true })
          }
        }
      })
    }

    // Initial image listener setup
    addImageListeners()

    // Scroll to the latest messages on initial load.
    // Server-driven unread scrolling can still override this afterward.
    if (this.currentConversationId) {
      this.restoreConversationScroll()
    }

    // Add image listeners when new content is added
    const imageObserver = new MutationObserver((mutations) => {
      mutations.forEach(mutation => {
        mutation.addedNodes.forEach(node => addImageListeners(node))
      })
    })

    imageObserver.observe(container, {
      childList: true,
      subtree: true
    })

    this.imageObserver = imageObserver

    this.handleEvent("restore_conversation_scroll", ({conversation_id}) => {
      if (String(conversation_id) === String(this.currentConversationId)) {
        this.initialScrollDone = false
        this.restoreConversationScroll(conversation_id)
      }
    })

    // Handle scroll to bottom (server controls initial scroll)
    this.handleEvent("scroll_to_bottom", () => {
      // Aggressive initial scroll to handle images
      const doScroll = () => {
        const wasNearBottom = isNearBottom()
        scrollToBottom('auto')
        return wasNearBottom
      }

      // Immediate scroll
      doScroll()

      // Re-scroll multiple times to catch images loading
      // This is necessary because images load asynchronously
      const scrollAttempts = [50, 100, 200, 300, 500, 800, 1200, 1800]
      scrollAttempts.forEach(delay => {
        setTimeout(() => {
          // Only keep scrolling if we were at/near bottom
          // This prevents fighting with user if they scrolled up
          if (isNearBottom()) {
            scrollToBottom('auto')
          }
        }, delay)
      })

      // Mark done after all attempts
      setTimeout(() => {
        this.initialScrollDone = true
      }, 2000)
    })

    // Handle scroll to element (for unread indicator)
    this.handleEvent("scroll_to_element", ({element_id, position}) => {
      setTimeout(() => {
        const element = document.getElementById(element_id)
        if (element) {
          const block = position === 'top-third' ? 'center' : 'start'
          scrollElementInContainer(element, position === 'top-third' ? 'top-third' : block, 'smooth')
          setTimeout(() => {
            this.initialScrollDone = true
          }, 500)
        }
      }, 100)
    })

    // Watch for new messages being added (after initial scroll)
    const observer = new MutationObserver((mutations) => {
      // Only process after initial scroll is complete
      if (!this.initialScrollDone) return

      // Check if new messages were added (not just timestamp updates)
      const hasNewMessages = mutations.some(mutation => {
        return Array.from(mutation.addedNodes).some(node => {
          if (node.nodeType !== 1) return false

          // Check if this is an actual message element
          if (node.id?.startsWith('message-') && !node.id?.includes('bubble') && !node.id?.includes('local-time')) {
            return true
          }

          // Check for containers with message children
          const hasMessageChild = node.querySelector?.('[id^="message-"]:not([id*="bubble"]):not([id*="local-time"])')
          return hasMessageChild ? true : false
        })
      })

      if (hasNewMessages) {
        // Add image listeners to any new images
        mutations.forEach(mutation => {
          mutation.addedNodes.forEach(node => addImageListeners(node))
        })

        // Only auto-scroll if user is near bottom (standard messenger UX)
        if (isNearBottom()) {
          requestAnimationFrame(() => {
            scrollToBottom('smooth')
          })
        } else {
          // User scrolled up - show jump button instead
          updateJumpButton()
        }
      }
    })

    observer.observe(container, {
      childList: true,
      subtree: true
    })

    this.observer = observer
  },

  updated() {
    // When conversation changes (detected by data-conversation-id change)
    const newConversationId = this.el.dataset.conversationId
    if (newConversationId && newConversationId !== this.currentConversationId) {
      // Conversation switched - reset state
      this.currentConversationId = newConversationId
      this.initialScrollDone = false
      this.isLoadingOlder = false

      // The imageObserver will automatically catch new images in the new conversation
      // No need to manually call addImageListeners - MutationObserver handles it
      this.restoreConversationScroll(newConversationId)
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
    if (this.imageObserver) {
      this.imageObserver.disconnect()
    }
  }
}
