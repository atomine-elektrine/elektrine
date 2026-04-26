// Global notification system for reliable notifications

import { FlashMessageManager } from './flash_message_manager'
import { spinnerSvg } from './utils/spinner'

function appendHtml(parent, html) {
  const template = document.createElement('template')
  template.innerHTML = html.trim()
  parent.appendChild(template.content)
}

function notificationToneVars(type) {
  const tone = {
    success: 'var(--color-success)',
    info: 'var(--color-info)',
    warning: 'var(--color-warning)',
    error: 'var(--color-error)',
    loading: 'var(--color-info)'
  }[type] || 'var(--color-info)'

  return {
    '--flash-accent': `color-mix(in srgb, ${tone} 92%, transparent)`,
    '--flash-accent-soft': `color-mix(in srgb, ${tone} 25%, transparent)`,
    '--flash-tint-start': `color-mix(in srgb, ${tone} 20%, transparent)`,
    '--flash-tint-mid': `color-mix(in srgb, ${tone} 8%, transparent)`,
    '--flash-border': `color-mix(in srgb, ${tone} 48%, transparent)`,
    '--flash-icon': `color-mix(in srgb, ${tone} 72%, var(--color-base-content) 28%)`
  }
}

/**
 * Show a toast notification with various options
 * @param {string} message - The notification message
 * @param {string} type - Notification type: 'success', 'info', 'warning', 'error', 'loading'
 * @param {string|Object} titleOrOptions - Title string or options object
 * @param {Object} options - Additional options (if title is a string)
 *   - title: Custom title
 *   - duration: Auto-dismiss time in ms (default: 5000, use 0 or 'persistent' for no auto-dismiss)
 *   - persistent: If true, notification won't auto-dismiss
 *   - actions: Array of action buttons [{label, event, class}]
 *   - progress: Show progress bar (countdown)
 *   - undoEvent: Event name for undo action (adds Undo button)
 *   - undoData: Data to pass with undo event
 */
export function showNotification(message, type = 'info', titleOrOptions = null, options = {}) {
  // Handle different parameter signatures
  let config = {
    title: null,
    duration: 5000,
    persistent: false,
    actions: [],
    progress: false,
    undoEvent: null,
    undoData: {},
    ...options
  }

  if (typeof titleOrOptions === 'string') {
    config.title = titleOrOptions
  } else if (typeof titleOrOptions === 'object' && titleOrOptions !== null) {
    config = { ...config, ...titleOrOptions }
  }

  // Handle persistent option
  if (config.persistent || config.duration === 'persistent') {
    config.duration = 0
  }

  // Map types to DaisyUI alert classes
  const alertClass = {
    'success': 'alert-success',
    'info': 'alert-info',
    'warning': 'alert-warning',
    'error': 'alert-error',
    'loading': 'alert-info'
  }[type] || 'alert-info'

  // Map types to appropriate icons (using hero icons paths)
  const icons = {
    'success': 'M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z',
    'info': 'M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z',
    'warning': 'M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.5 0L4.268 18.5c-.77.833.192 2.5 1.732 2.5z',
    'error': 'M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z',
    'loading': null // Will use spinner instead
  }

  const iconPath = icons[type]

  // Default titles based on type
  const defaultTitle = config.title || {
    'success': 'Success!',
    'info': 'Info',
    'warning': 'Warning',
    'error': 'Error!',
    'loading': 'Loading...'
  }[type] || ''

  // Build icon HTML - spinner for loading type
  const iconHtml = type === 'loading'
    ? spinnerSvg()
    : `<svg xmlns="http://www.w3.org/2000/svg" class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="${iconPath}" />
       </svg>`

  const allActions = [...config.actions]

  // Add undo button if undoEvent is specified
  if (config.undoEvent) {
    allActions.push({
      label: 'Undo',
      event: config.undoEvent,
      data: config.undoData,
      class: 'btn-ghost btn-xs'
    })
  }

  // Create notification element matching the LiveView flash structure
  const notification = document.createElement('div')
  notification.className = `flash-message alert app-flash ${alertClass} shadow-xl rounded-lg relative transition-all duration-300 cursor-pointer overflow-hidden`
  Object.entries(notificationToneVars(type)).forEach(([property, value]) => {
    notification.style.setProperty(property, value)
  })
  const content = document.createElement('div')
  content.className = 'flex items-center gap-3 w-full'

  const iconWrapper = document.createElement('div')
  iconWrapper.className = 'flash-message__icon flex-shrink-0'
  appendHtml(iconWrapper, iconHtml)

  const body = document.createElement('div')
  body.className = 'flex-grow min-w-0'

  if (defaultTitle) {
    const title = document.createElement('h3')
    title.className = 'font-bold'
    title.textContent = defaultTitle
    body.appendChild(title)
  }

  const messageEl = document.createElement('div')
  messageEl.className = 'text-sm'
  messageEl.textContent = message
  body.appendChild(messageEl)

  if (allActions.length > 0) {
    const actions = document.createElement('div')
    actions.className = 'notification-actions flex gap-2 mt-2'

    allActions.forEach((action, idx) => {
      const button = document.createElement('button')
      button.className = `btn ${action.class || 'btn-ghost btn-xs'}`
      button.dataset.actionIdx = String(idx)
      button.textContent = action.label
      actions.appendChild(button)
    })

    body.appendChild(actions)
  }

  const closeBtn = document.createElement('button')
  closeBtn.className = 'btn btn-ghost btn-sm btn-circle notification-close-btn flex-shrink-0'
  appendHtml(closeBtn, `
    <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
    </svg>
  `)

  content.appendChild(iconWrapper)
  content.appendChild(body)
  content.appendChild(closeBtn)
  notification.appendChild(content)

  if (config.progress && config.duration > 0) {
    const progress = document.createElement('div')
    progress.className = 'notification-progress absolute bottom-0 left-0 h-1 bg-current opacity-30'
    progress.style.width = '100%'
    progress.style.transition = `width ${config.duration}ms linear`
    notification.appendChild(progress)
  }

  // Initialize flash manager if not exists
  if (!window.flashManager) {
    window.flashManager = new FlashMessageManager()
  }

  // Add to DOM
  document.body.appendChild(notification)

  let autoRemoveTimer = null

  // Function to remove the notification
  const removeNotification = () => {
    if (autoRemoveTimer) {
      clearTimeout(autoRemoveTimer)
    }
    notification.style.transition = 'all 0.3s ease-out'
    notification.style.opacity = '0'
    notification.style.transform = 'translateX(-100%)'
    setTimeout(() => {
      if (notification.parentNode) {
        notification.remove()
      }
      if (window.flashManager) {
        window.flashManager.removeMessage(notification)
      }
    }, 300)
  }

  // Add event listener to close button
  closeBtn.addEventListener('click', () => {
    removeNotification()
  })

  // Add event listeners to action buttons
  if (allActions.length > 0) {
    const actionBtns = notification.querySelectorAll('[data-action-idx]')
    actionBtns.forEach(btn => {
      btn.addEventListener('click', () => {
        const idx = parseInt(btn.dataset.actionIdx)
        const action = allActions[idx]
        if (action && action.event) {
          // Dispatch custom event for LiveView to handle
          window.dispatchEvent(new CustomEvent('phx:notification_action', {
            detail: { event: action.event, data: action.data || {} }
          }))
          // Also push to LiveView if available
          if (window.liveSocket) {
            const mainEl = document.querySelector('[data-phx-main]')
            if (mainEl && mainEl._liveView) {
              mainEl._liveView.pushEvent(action.event, action.data || {})
            }
          }
        }
        if (action.callback) {
          action.callback()
        }
        // Dismiss notification after action
        removeNotification()
      })
    })
  }

  // Use the flash manager for consistent positioning and animation
  window.flashManager.addMessage(notification, {
    hide: removeNotification
  })

  // Start progress bar animation
  if (config.progress && config.duration > 0) {
    const progressBar = notification.querySelector('.notification-progress')
    if (progressBar) {
      // Trigger reflow before starting animation
      progressBar.offsetWidth
      requestAnimationFrame(() => {
        progressBar.style.width = '0%'
      })
    }
  }

  // Auto-remove after duration (if not persistent)
  if (config.duration > 0) {
    autoRemoveTimer = setTimeout(() => {
      removeNotification()
    }, config.duration)
  }

  // Click to dismiss (on the notification itself, not the close button or action buttons)
  notification.addEventListener('click', (e) => {
    // Don't dismiss if clicking the close button or action buttons
    if (!e.target.closest('.notification-close-btn') && !e.target.closest('[data-action-idx]')) {
      if (autoRemoveTimer) {
        clearTimeout(autoRemoveTimer)
      }
      removeNotification()
    }
  })

  // Return notification element and dismiss function for programmatic control
  notification.dismiss = removeNotification
  return notification
}

/**
 * Normalizes LiveView-style payloads into notification options and renders them.
 * @param {Object} payload - Notification payload from push_event/window events
 * @returns {HTMLElement|null}
 */
export function showNotificationFromPayload(payload = {}) {
  const {
    message,
    type,
    title,
    duration,
    persistent,
    progress,
    undoEvent,
    undoData,
    actions
  } = payload

  if (!message) return null

  const options = {}
  if (title) options.title = title
  if (duration !== undefined) options.duration = duration
  if (persistent) options.persistent = persistent
  if (progress) options.progress = progress
  if (undoEvent) options.undoEvent = undoEvent
  if (undoData) options.undoData = undoData
  if (actions && actions.length > 0) options.actions = actions

  return showNotification(message, type || 'info', options)
}

/**
 * Show a loading notification that can be updated or dismissed
 * @param {string} message - Loading message
 * @param {Object} options - Additional options
 * @returns {Object} - Object with update() and dismiss() methods
 */
export function showLoadingNotification(message, options = {}) {
  const notification = showNotification(message, 'loading', {
    ...options,
    persistent: true,
    title: options.title || 'Loading...'
  })

  return {
    element: notification,
    update: (newMessage, newTitle = null) => {
      const msgEl = notification.querySelector('.text-sm')
      if (msgEl) msgEl.textContent = newMessage
      if (newTitle) {
        const titleEl = notification.querySelector('h3')
        if (titleEl) titleEl.textContent = newTitle
      }
    },
    dismiss: () => notification.dismiss(),
    success: (msg, title = 'Success!') => {
      notification.dismiss()
      showNotification(msg, 'success', { title })
    },
    error: (msg, title = 'Error!') => {
      notification.dismiss()
      showNotification(msg, 'error', { title })
    }
  }
}

/**
 * Show a notification with an undo action
 * @param {string} message - The notification message
 * @param {string} undoEvent - Event name to trigger on undo
 * @param {Object} undoData - Data to pass with undo event
 * @param {Object} options - Additional options
 */
export function showUndoNotification(message, undoEvent, undoData = {}, options = {}) {
  return showNotification(message, options.type || 'info', {
    ...options,
    duration: options.duration || 8000, // Longer duration for undo
    undoEvent,
    undoData
  })
}

/**
 * Show a confirmation notification with confirm/cancel actions
 * @param {string} message - The notification message
 * @param {Function} onConfirm - Callback on confirm
 * @param {Function} onCancel - Callback on cancel
 * @param {Object} options - Additional options
 */
export function showConfirmNotification(message, onConfirm, onCancel = null, options = {}) {
  return showNotification(message, options.type || 'warning', {
    title: options.title || 'Confirm',
    persistent: true,
    actions: [
      {
        label: options.confirmLabel || 'Confirm',
        class: 'btn-primary btn-xs',
        callback: onConfirm
      },
      {
        label: options.cancelLabel || 'Cancel',
        class: 'btn-ghost btn-xs',
        callback: onCancel || (() => {})
      }
    ]
  })
}

// Global function to show keyboard shortcuts (called from buttons)
export function showKeyboardShortcuts() {

  // Check if modal already exists to prevent duplicates
  if (document.getElementById('keyboard-shortcuts-modal')) {
    return
  }

  const modal = document.createElement('div')
  modal.id = 'keyboard-shortcuts-modal'
  modal.className = 'fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50'

  // Create modal content container
  const modalContent = document.createElement('div')
  modalContent.className = 'bg-base-100 rounded-lg shadow-xl p-6 max-w-2xl w-full mx-4 max-h-96 overflow-y-auto'
  modalContent.innerHTML = `
    <div class="flex justify-between items-center mb-6">
      <h2 class="text-2xl font-bold">Keyboard Shortcuts</h2>
      <button class="btn btn-ghost btn-sm btn-circle modal-close-btn">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
      <div>
        <h3 class="font-semibold mb-3">Navigation</h3>
        <div class="space-y-2 text-sm">
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">c</kbd>
            <span>Compose</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">g</kbd>
            <span>Go to menu</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">/</kbd>
            <span>Search</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">j</kbd>
            <span>Next message</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">k</kbd>
            <span>Previous message</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">Enter</kbd>
            <span>Open message</span>
          </div>
        </div>
      </div>

      <div>
        <h3 class="font-semibold mb-3">Actions</h3>
        <div class="space-y-2 text-sm">
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">e</kbd>
            <span>Archive</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">r</kbd>
            <span>Reply</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">f</kbd>
            <span>Forward</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">#</kbd>
            <span>Delete</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">!</kbd>
            <span>Mark as spam</span>
          </div>
          <div class="flex justify-between">
            <kbd class="kbd kbd-sm">Shift + /</kbd>
            <span>Show this help (?)</span>
          </div>
        </div>
      </div>
    </div>

    <div class="mt-6 p-4 bg-base-200 rounded-lg">
      <h4 class="font-semibold mb-2">Go to shortcuts (press 'g' then):</h4>
      <div class="grid grid-cols-2 gap-2 text-sm">
        <div><kbd class="kbd kbd-xs">i</kbd> Inbox</div>
        <div><kbd class="kbd kbd-xs">s</kbd> Sent</div>
        <div><kbd class="kbd kbd-xs">t</kbd> Search</div>
        <div><kbd class="kbd kbd-xs">a</kbd> Archive</div>
        <div><kbd class="kbd kbd-xs">p</kbd> Spam</div>
      </div>
    </div>
  `

  modal.appendChild(modalContent)

  // Function to close modal
  const closeModal = () => {
    modal.remove()
  }

  // Close modal when clicking outside the content area
  modal.addEventListener('click', (e) => {
    if (!modalContent.contains(e.target)) {
      closeModal()
    }
  })

  // Add event listener to close button
  const closeBtn = modalContent.querySelector('.modal-close-btn')
  if (closeBtn) {
    closeBtn.addEventListener('click', closeModal)
  }

  // Close on Escape key
  const escapeHandler = (e) => {
    if (e.key === 'Escape') {
      closeModal()
      document.removeEventListener('keydown', escapeHandler)
    }
  }
  document.addEventListener('keydown', escapeHandler)

  document.body.appendChild(modal)

  return modal
}
