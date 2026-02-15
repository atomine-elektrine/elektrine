/**
 * Clipboard Utilities
 * Handles copy to clipboard operations
 */

/**
 * Copy text to clipboard with notification
 */
export function copyToClipboard(text, type = 'link') {
  navigator.clipboard.writeText(text).then(() => {
    const message = type === 'message' ? 'Message copied to clipboard' : 'Link copied to clipboard'
    if (window.showNotification) {
      window.showNotification(message, 'info', 'Success!')
    }
  }).catch(err => {
    console.error('Failed to copy text to clipboard:', err)
    if (window.showNotification) {
      window.showNotification('Failed to copy to clipboard', 'error', 'Error!')
    }
  })
}

/**
 * Open URL in new window
 */
export function openUrl(url) {
  if (url) {
    window.open(url, '_blank', 'noopener,noreferrer')
  }
}

/**
 * Initialize clipboard event handlers
 */
export function initClipboardHandlers() {
  window.addEventListener("phx:copy_to_clipboard", (e) => {
    copyToClipboard(e.detail.text, e.detail.type)
  })

  window.addEventListener("phx:open_url", (e) => {
    openUrl(e.detail.url)
  })
}
