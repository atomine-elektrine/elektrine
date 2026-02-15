// Notification-related LiveView hooks

export const NotificationHandler = {
  mounted() {
    // Store reference to current loading notifications for updates
    this.loadingNotifications = new Map()

    this.handleEvent("show_notification", (data) => {
      const {
        message,
        type,
        title,
        duration,
        persistent,
        progress,
        undoEvent,
        undoData,
        actions,
        id
      } = data

      // Build options object
      const options = {}
      if (title) options.title = title
      if (duration !== undefined) options.duration = duration
      if (persistent) options.persistent = persistent
      if (progress) options.progress = progress
      if (undoEvent) options.undoEvent = undoEvent
      if (undoData) options.undoData = undoData
      if (actions && actions.length > 0) options.actions = actions

      const notification = window.showNotification(message, type, options)

      // Store loading notifications by ID for later updates
      if (id && type === 'loading') {
        this.loadingNotifications.set(id, notification)
      }
    })

    // Handle updating a loading notification
    this.handleEvent("update_notification", ({id, message, title}) => {
      const notification = this.loadingNotifications.get(id)
      if (notification) {
        const msgEl = notification.querySelector('.text-sm')
        if (msgEl) msgEl.textContent = message
        if (title) {
          const titleEl = notification.querySelector('h3')
          if (titleEl) titleEl.textContent = title
        }
      }
    })

    // Handle dismissing a specific notification
    this.handleEvent("dismiss_notification", ({id}) => {
      const notification = this.loadingNotifications.get(id)
      if (notification && notification.dismiss) {
        notification.dismiss()
        this.loadingNotifications.delete(id)
      }
    })

    // Handle completing a loading notification (transition to success/error)
    this.handleEvent("complete_notification", ({id, type, message, title}) => {
      const notification = this.loadingNotifications.get(id)
      if (notification && notification.dismiss) {
        notification.dismiss()
        this.loadingNotifications.delete(id)
        window.showNotification(message, type || 'success', { title })
      }
    })

    // Listen for notification action events from JavaScript
    this.actionHandler = (e) => {
      const { event, data } = e.detail
      if (event) {
        this.pushEvent(event, data || {})
      }
    }
    window.addEventListener('phx:notification_action', this.actionHandler)
  },

  destroyed() {
    if (this.actionHandler) {
      window.removeEventListener('phx:notification_action', this.actionHandler)
    }
    // Dismiss any remaining loading notifications
    this.loadingNotifications?.forEach(notification => {
      if (notification.dismiss) notification.dismiss()
    })
  }
}

export const NotificationDropdown = {
  mounted() {
    // Handle clicking outside to close dropdown
    this.handleClickOutside = (e) => {
      // Don't close if clicking inside the dropdown
      if (!this.el.contains(e.target)) {
        // Send event to close dropdown
        this.pushEvent("close_dropdown", {})
      }
    }

    // Only listen for outside clicks when dropdown is open
    this.handleEvent("dropdown_opened", () => {
      setTimeout(() => {
        document.addEventListener("click", this.handleClickOutside)
      }, 100)
    })

    this.handleEvent("dropdown_closed", () => {
      document.removeEventListener("click", this.handleClickOutside)
    })
  },

  destroyed() {
    document.removeEventListener("click", this.handleClickOutside)
  }
}