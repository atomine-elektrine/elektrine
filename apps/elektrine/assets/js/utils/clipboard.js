/**
 * Clipboard Utilities
 * Handles copy to clipboard operations
 */

function coerceClipboardText(text) {
  if (text === null || text === undefined) return ''
  return typeof text === 'string' ? text : String(text)
}

function fallbackCopyToClipboard(text) {
  let textarea = null
  try {
    textarea = document.createElement('textarea')
    textarea.value = text
    textarea.setAttribute('readonly', '')
    textarea.style.position = 'fixed'
    textarea.style.top = '-9999px'
    textarea.style.left = '-9999px'
    document.body.appendChild(textarea)
    textarea.select()
    textarea.setSelectionRange(0, textarea.value.length)
    return document.execCommand('copy')
  } catch (_err) {
    return false
  } finally {
    if (textarea && textarea.parentNode) {
      textarea.parentNode.removeChild(textarea)
    }
  }
}

/**
 * Copy text to clipboard with notification
 */
export function copyToClipboard(text, type = 'link') {
  const textToCopy = coerceClipboardText(text)
  const showSuccess = () => {
    const message = type === 'message' ? 'Message copied to clipboard' : 'Link copied to clipboard'
    if (window.showNotification) {
      window.showNotification(message, 'info', 'Success!')
    }
  }
  const showFailure = (err) => {
    console.error('Failed to copy text to clipboard:', err)
    if (window.showNotification) {
      window.showNotification('Failed to copy to clipboard', 'error', 'Error!')
    }
  }

  const canUseClipboardApi =
    !!navigator.clipboard &&
    typeof navigator.clipboard.writeText === 'function' &&
    window.isSecureContext

  if (canUseClipboardApi) {
    navigator.clipboard.writeText(textToCopy).then(showSuccess).catch(err => {
      if (fallbackCopyToClipboard(textToCopy)) {
        showSuccess()
        return
      }
      showFailure(err)
    })
    return
  }

  if (fallbackCopyToClipboard(textToCopy)) {
    showSuccess()
  } else {
    showFailure(new Error('Clipboard API unavailable and fallback copy failed'))
  }
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
