// Hook to automatically resize email content iframe based on content height

export const EmailIframeResize = {
  mounted() {
    this.iframe = this.el
    // Initialize maxHeight from current iframe height to prevent shrinking
    this.maxHeight = this.iframe.offsetHeight || 600
    this.resizeTimers = []
    this.imageListeners = []
    this.mutationObserver = null

    // Resize when iframe loads
    this.loadHandler = () => {
      // Resize immediately
      this.resizeIframe()
      this.bindContentResizeWatchers()

      // Check again after brief delays to catch images loading
      this.scheduleResize(100)
      this.scheduleResize(300)
      this.scheduleResize(600)
      this.scheduleResize(1000)
      this.scheduleResize(2000)
    }

    this.iframe.addEventListener('load', this.loadHandler)
  },

  scheduleResize(delay) {
    const timer = setTimeout(() => this.resizeIframe(), delay)
    this.resizeTimers.push(timer)
  },

  bindContentResizeWatchers() {
    this.cleanupContentResizeWatchers()

    try {
      const iframeDoc = this.iframe.contentDocument || this.iframe.contentWindow.document
      if (!iframeDoc) return

      iframeDoc.querySelectorAll('img').forEach((image) => {
        const listener = () => this.resizeIframe()
        image.addEventListener('load', listener, { once: true })
        image.addEventListener('error', listener, { once: true })
        this.imageListeners.push({ image, listener })
      })

      if (iframeDoc.fonts && typeof iframeDoc.fonts.ready?.then === 'function') {
        iframeDoc.fonts.ready.then(() => this.resizeIframe()).catch(() => {})
      }

      this.mutationObserver = new MutationObserver(() => this.resizeIframe())
      this.mutationObserver.observe(iframeDoc.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        characterData: true,
      })
    } catch (_error) {
      // Cross-origin restrictions - iframe will use scheduled height checks.
    }
  },

  cleanupContentResizeWatchers() {
    this.imageListeners.forEach(({ image, listener }) => {
      image.removeEventListener('load', listener)
      image.removeEventListener('error', listener)
    })
    this.imageListeners = []

    if (this.mutationObserver) {
      this.mutationObserver.disconnect()
      this.mutationObserver = null
    }
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

    this.resizeTimers.forEach((timer) => clearTimeout(timer))
    this.resizeTimers = []
    this.cleanupContentResizeWatchers()
  }
}
