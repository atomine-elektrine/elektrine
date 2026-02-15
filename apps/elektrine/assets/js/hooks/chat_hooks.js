// Chat-specific LiveView hooks

export const AutoExpandTextarea = {
  mounted() {
    this.sendingMessage = false
    this.lastSentContent = ""
    this.lastSentTime = 0
    this.userResized = false // Track if user manually resized
    this.currentHeight = null // Track current height to preserve during LiveView updates

    // Get min/max heights from style attribute
    const style = this.el.getAttribute('style') || ''
    const minMatch = style.match(/min-height:\s*([0-9.]+)rem/)
    const maxMatch = style.match(/max-height:\s*([0-9.]+)rem/)
    this.minHeight = minMatch ? parseFloat(minMatch[1]) * 16 : 40 // Convert rem to px
    this.maxHeight = maxMatch ? parseFloat(maxMatch[1]) * 16 : 160

    // Store original style to preserve it
    this.originalStyle = this.el.getAttribute('style') || ''

    // Auto-expand textarea function
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
    this.el.addEventListener('mousedown', (e) => {
      // Check if click is in the bottom right (resize handle area)
      const rect = this.el.getBoundingClientRect()
      const isResizeHandle = e.clientX > rect.right - 20 && e.clientY > rect.bottom - 20

      if (isResizeHandle) {
        this.userResized = true
      }
    })

    // Adjust height on any input or change
    const handleInput = () => {
      requestAnimationFrame(() => adjustHeight())
    }

    this.el.addEventListener('input', handleInput)
    this.el.addEventListener('change', handleInput)
    this.el.addEventListener('paste', () => {
      setTimeout(handleInput, 10)
    })

    // Handle keyboard shortcuts
    this.el.addEventListener("keydown", (e) => {
      // Allow Shift+Enter for new line
      if (e.key === "Enter" && e.shiftKey) {
        // Let the default behavior happen (insert newline)
        setTimeout(() => adjustHeight(), 10)
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

          // Disable the submit button temporarily
          const submitBtn = form.querySelector('button[type="submit"]')
          if (submitBtn) {
            submitBtn.disabled = true
          }

          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

          // Reset after submit
          setTimeout(() => {
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
    })

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
      form.addEventListener('submit', () => {
        setTimeout(() => {
          this.el.value = ""
          // Use style object to preserve other CSS properties
          this.el.style.height = this.minHeight + 'px'
          this.currentHeight = this.minHeight
          this.userResized = false
        }, 100)
      })
    }

    // Set initial height to match reset height for consistency
    this.el.style.height = this.minHeight + 'px'
    this.currentHeight = this.minHeight

    // Initial height adjustment (in case there's pre-filled content)
    setTimeout(() => {
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
  }
}

export const SimpleChatInput = {
  mounted() {
    this.maxHeight = 150

    // Get the natural single-line height
    this.el.style.height = 'auto'
    this.el.rows = 1
    this.baseHeight = this.el.scrollHeight
    this.el.style.height = this.baseHeight + 'px'
    this.el.style.overflowY = 'hidden'

    this.autoResize = () => {
      this.el.style.height = 'auto'
      const scrollHeight = this.el.scrollHeight
      const newHeight = Math.min(scrollHeight, this.maxHeight)
      this.el.style.height = newHeight + 'px'
      this.el.style.overflowY = scrollHeight > this.maxHeight ? 'auto' : 'hidden'
      // Adjust border radius when expanded
      this.el.style.borderRadius = newHeight > this.baseHeight + 10 ? '1rem' : '9999px'
    }

    this.el.addEventListener("input", this.autoResize)

    // Enter key handling
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        const form = this.el.closest("form")
        if (form && this.el.value.trim()) {
          form.requestSubmit()
        }
      }
    })
  },
  updated() {
    // Restore height after LiveView re-render
    this.autoResize()
  }
}

export const MessageInput = {
  mounted() {
    this.sendingMessage = false
    this.lastSentContent = ""
    this.lastSentTime = 0

    this.el.addEventListener("keydown", (e) => {
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

          // Disable the submit button temporarily
          const submitBtn = form.querySelector('button[type="submit"]')
          if (submitBtn) {
            submitBtn.disabled = true
          }

          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
        }
      }
    })

    // Handle clear message input event
    this.handleEvent("clear_message_input", () => {
      this.sendingMessage = false
      this.el.value = ""
      this.el.focus()

      // Re-enable submit button
      const form = this.el.closest("form")
      if (form) {
        const submitBtn = form.querySelector('button[type="submit"]')
        if (submitBtn) {
          submitBtn.disabled = false
        }
      }

      // Trigger change event to update LiveView state
      this.el.dispatchEvent(new Event("input", { bubbles: true }))
    })

    // Focus input on mount
    this.el.focus()
  },

  updated() {
    // Reset sending state and keep focus
    this.sendingMessage = false
    if (document.activeElement !== this.el) {
      this.el.focus()
    }
  }
}

export const MessagesContainer = {
  mounted() {
    // Only respond to LiveView commands - no auto-scrolling
    this.handleEvent("scroll_to_bottom", () => {
      this.scrollToBottom()
    })

    this.handleEvent("scroll_to_element", ({element_id, position}) => {
      const element = document.getElementById(element_id)
      if (element) {
        const containerHeight = this.el.clientHeight
        const elementOffset = element.offsetTop
        let targetScroll = position === "center" ? elementOffset - (containerHeight / 2) :
                          position === "top-third" ? elementOffset - (containerHeight / 3) :
                          elementOffset

        this.el.scrollTo({
          top: Math.max(0, targetScroll),
          behavior: 'smooth'
        })
      }
    })
  },

  updated() {
    // LiveView controls all scrolling
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

export const MessageList = {
  mounted() {
    const container = this.el
    this.isLoadingOlder = false
    this.initialScrollDone = false
    this.currentConversationId = container.dataset.conversationId

    // Check if user is near bottom (within 150px)
    const isNearBottom = () => {
      return container.scrollHeight - container.scrollTop - container.clientHeight < 150
    }

    // Smoothly scroll to bottom
    const scrollToBottom = (behavior = 'smooth') => {
      requestAnimationFrame(() => {
        container.scrollTo({
          top: container.scrollHeight,
          behavior: behavior
        })
      })
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
        messageEl.scrollIntoView({behavior: 'smooth', block: 'center'})
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

    // Add listeners to all current and future images
    const addImageListeners = () => {
      const images = container.querySelectorAll('img')
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

    // Add image listeners when new content is added
    const imageObserver = new MutationObserver(() => {
      addImageListeners()
    })

    imageObserver.observe(container, {
      childList: true,
      subtree: true
    })

    this.imageObserver = imageObserver

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
          element.scrollIntoView({behavior: 'smooth', block: block})
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
        addImageListeners()

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

export const ContextMenu = {
  mounted() {
    // Get conversation ID from data attribute
    const conversationId = this.el.dataset.conversationId

    // Handle right-click context menu
    this.contextMenuHandler = (e) => {
      e.preventDefault()
      // Hide any existing context menus first
      this.pushEvent("hide_message_context_menu", {})
      this.pushEvent("show_context_menu", {
        conversation_id: parseInt(conversationId),
        x: e.clientX,
        y: e.clientY
      })
    }
    this.el.addEventListener("contextmenu", this.contextMenuHandler)

    // Handle custom context menu event (for backwards compatibility)
    this.customEventHandler = (e) => {
      const { conversation_id, x, y } = e.detail
      // Hide any existing context menus first
      this.pushEvent("hide_message_context_menu", {})
      this.pushEvent("show_context_menu", {
        conversation_id: conversation_id,
        x: x,
        y: y
      })
    }
    this.el.addEventListener("phx:show_context_menu", this.customEventHandler)

    // Hide context menu immediately on any click
    this.clickHandler = (e) => {
      // Skip if clicking on the context menu itself
      const contextMenu = document.querySelector('[phx-click-away="hide_context_menu"]')
      if (contextMenu && !contextMenu.contains(e.target)) {
        this.pushEvent("hide_context_menu", {})
      }
    }

    document.addEventListener("click", this.clickHandler)

    // Also hide on scroll for better UX
    this.scrollHandler = () => {
      this.pushEvent("hide_context_menu", {})
    }
    this.el.addEventListener("scroll", this.scrollHandler)
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.contextMenuHandler)
    this.el.removeEventListener("phx:show_context_menu", this.customEventHandler)
    document.removeEventListener("click", this.clickHandler)
    this.el.removeEventListener("scroll", this.scrollHandler)
  }
}

export const VoiceRecorder = {
  mounted() {
    this.mediaRecorder = null
    this.audioChunks = []
    this.isRecording = false
    this.recordingTimer = null
    this.recordingSeconds = 0
    this.maxDuration = 120 // Max 2 minutes

    // UI elements
    const recordBtn = this.el
    const timerEl = document.getElementById('voice-timer')
    const cancelBtn = document.getElementById('voice-cancel')
    const sendBtn = document.getElementById('voice-send')
    const recordingIndicator = document.getElementById('voice-recording-indicator')

    const updateUI = (recording) => {
      if (recordingIndicator) {
        recordingIndicator.classList.toggle('hidden', !recording)
      }
      recordBtn.classList.toggle('text-error', recording)
      recordBtn.classList.toggle('animate-pulse', recording)
    }

    const formatTime = (seconds) => {
      const mins = Math.floor(seconds / 60)
      const secs = seconds % 60
      return `${mins}:${secs.toString().padStart(2, '0')}`
    }

    const startRecording = async () => {
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
        this.audioChunks = []

        // Use webm for better browser support, fall back to mp4
        const mimeType = MediaRecorder.isTypeSupported('audio/webm') ? 'audio/webm' : 'audio/mp4'
        this.mediaRecorder = new MediaRecorder(stream, { mimeType })

        this.mediaRecorder.ondataavailable = (e) => {
          if (e.data.size > 0) {
            this.audioChunks.push(e.data)
          }
        }

        this.mediaRecorder.onstop = () => {
          stream.getTracks().forEach(track => track.stop())
        }

        this.mediaRecorder.start(100) // Collect data every 100ms
        this.isRecording = true
        this.recordingSeconds = 0
        updateUI(true)

        // Start timer
        this.recordingTimer = setInterval(() => {
          this.recordingSeconds++
          if (timerEl) {
            timerEl.textContent = formatTime(this.recordingSeconds)
          }
          // Auto-stop at max duration
          if (this.recordingSeconds >= this.maxDuration) {
            sendRecording()
          }
        }, 1000)

      } catch (err) {
        console.error('Failed to start recording:', err)
        this.pushEvent('voice_recording_error', { error: 'Microphone access denied' })
      }
    }

    const stopRecording = () => {
      if (this.mediaRecorder && this.isRecording) {
        this.mediaRecorder.stop()
        this.isRecording = false
        clearInterval(this.recordingTimer)
        updateUI(false)
        if (timerEl) timerEl.textContent = '0:00'
      }
    }

    const cancelRecording = () => {
      stopRecording()
      this.audioChunks = []
      this.recordingSeconds = 0
    }

    const sendRecording = async () => {
      if (!this.isRecording && this.audioChunks.length === 0) return

      // Stop if still recording
      if (this.isRecording) {
        this.mediaRecorder.stop()
        this.isRecording = false
        clearInterval(this.recordingTimer)
        updateUI(false)

        // Wait for final data
        await new Promise(resolve => setTimeout(resolve, 100))
      }

      if (this.audioChunks.length === 0) return

      const mimeType = this.mediaRecorder?.mimeType || 'audio/webm'
      const audioBlob = new Blob(this.audioChunks, { type: mimeType })
      const duration = this.recordingSeconds

      // Convert to base64 for sending via LiveView
      const reader = new FileReader()
      reader.onload = () => {
        const base64 = reader.result.split(',')[1]
        this.pushEvent('send_voice_message', {
          audio_data: base64,
          duration: duration,
          mime_type: mimeType
        })
      }
      reader.readAsDataURL(audioBlob)

      // Reset
      this.audioChunks = []
      this.recordingSeconds = 0
      if (timerEl) timerEl.textContent = '0:00'
    }

    // Toggle recording on button click
    recordBtn.addEventListener('click', () => {
      if (this.isRecording) {
        sendRecording()
      } else {
        startRecording()
      }
    })

    // Cancel button
    if (cancelBtn) {
      cancelBtn.addEventListener('click', cancelRecording)
    }

    // Send button (if separate)
    if (sendBtn) {
      sendBtn.addEventListener('click', sendRecording)
    }

    // Handle escape to cancel
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && this.isRecording) {
        cancelRecording()
      }
    })
  },

  destroyed() {
    if (this.recordingTimer) {
      clearInterval(this.recordingTimer)
    }
    if (this.mediaRecorder && this.isRecording) {
      this.mediaRecorder.stop()
    }
  }
}

export const MessageContextMenu = {
  mounted() {
    // Get message info from data attributes
    const messageId = this.el.dataset.messageId
    const senderId = this.el.dataset.senderId

    // Handle right-click context menu
    this.contextMenuHandler = (e) => {
      e.preventDefault()
      // Hide any existing context menus first
      this.pushEvent("hide_context_menu", {})
      this.pushEvent("show_message_context_menu", {
        message_id: parseInt(messageId),
        sender_id: parseInt(senderId),
        x: e.clientX,
        y: e.clientY
      })
    }
    this.el.addEventListener("contextmenu", this.contextMenuHandler)

    // Handle custom message context menu event (for backwards compatibility)
    this.customEventHandler = (e) => {
      const { message_id, sender_id, x, y } = e.detail
      // Hide any existing context menus first
      this.pushEvent("hide_context_menu", {})
      this.pushEvent("show_message_context_menu", {
        message_id: message_id,
        sender_id: sender_id,
        x: x,
        y: y
      })
    }
    this.el.addEventListener("phx:show_message_context_menu", this.customEventHandler)

    // Hide context menu immediately on any click
    this.clickHandler = (e) => {
      // Skip if clicking on the context menu itself
      const contextMenu = document.querySelector('[phx-click-away="hide_message_context_menu"]')
      if (contextMenu && !contextMenu.contains(e.target)) {
        this.pushEvent("hide_message_context_menu", {})
      }
    }

    document.addEventListener("click", this.clickHandler)

    // Also hide on scroll for better UX
    this.scrollHandler = () => {
      this.pushEvent("hide_message_context_menu", {})
    }
    this.el.addEventListener("scroll", this.scrollHandler)

    // Hide on Escape key
    this.keyHandler = (e) => {
      if (e.key === "Escape") {
        this.pushEvent("hide_message_context_menu", {})
      }
    }
    document.addEventListener("keydown", this.keyHandler)
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.contextMenuHandler)
    this.el.removeEventListener("phx:show_message_context_menu", this.customEventHandler)
    document.removeEventListener("click", this.clickHandler)
    document.removeEventListener("keydown", this.keyHandler)
    this.el.removeEventListener("scroll", this.scrollHandler)
  }
}
