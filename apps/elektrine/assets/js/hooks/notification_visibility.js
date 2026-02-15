// Hook for marking notifications as read when they become visible
export const NotificationVisibility = {
  mounted() {
    this.observer = null
    this.unreadNotifications = new Set()
    this.markedAsRead = new Set()
    this.pendingMarkAsRead = []

    this.setupIntersectionObserver()
  },

  setupIntersectionObserver() {
    // Options for the intersection observer
    const options = {
      root: null, // Use the viewport as the root
      rootMargin: '0px',
      threshold: 0.1 // Trigger when just 10% of the notification is visible
    }

    // Create the observer
    this.observer = new IntersectionObserver((entries) => {

      entries.forEach(entry => {
        if (entry.isIntersecting) {
          const notificationEl = entry.target
          const notificationId = notificationEl.dataset.notificationId
          const isUnread = notificationEl.dataset.unread === 'true'


          // Only mark as read if it's unread and hasn't been marked yet
          if (isUnread && !this.markedAsRead.has(notificationId)) {
            this.markedAsRead.add(notificationId)
            this.pendingMarkAsRead.push(notificationId)

            // Update the data attribute to prevent re-marking
            notificationEl.dataset.unread = 'false'
          }
        }
      })

      // Send event to mark visible notifications as read
      if (this.pendingMarkAsRead.length > 0) {
        // Debounce the marking to avoid too many server calls
        clearTimeout(this.markTimeout)
        this.markTimeout = setTimeout(() => {
          // Send all pending notifications at once
          const idsToMark = [...this.pendingMarkAsRead]
          this.pendingMarkAsRead = []

          this.pushEvent('mark_visible_as_read', {
            notification_ids: idsToMark
          })
        }, 100) // Reduced to 100ms for faster response
      }
    }, options)

    // Observe all notification cards
    this.observeNotifications()
  },

  observeNotifications() {
    const notifications = this.el.querySelectorAll('[data-notification-id]')

    notifications.forEach(notification => {
      // Only observe unread notifications
      if (notification.dataset.unread === 'true') {
        this.observer.observe(notification)
        this.unreadNotifications.add(notification.dataset.notificationId)
      }
    })
  },

  updated() {
    // When the DOM updates, check for new notifications to observe
    this.observeNotifications()
  },

  destroyed() {
    // Clean up the observer when the component is destroyed
    if (this.observer) {
      this.observer.disconnect()
    }
    clearTimeout(this.markTimeout)
  }
}