/**
 * Navigation Utilities
 * Handles click navigation with text selection awareness
 */

let mouseDownTarget = null
let mouseDownTime = 0

/**
 * Track mouse down for drag detection
 */
function handleMouseDown(e) {
  mouseDownTarget = e.target
  mouseDownTime = Date.now()
}

/**
 * Handle clicks with text selection and link awareness
 */
function handleNavigationClick(e) {
  const selection = window.getSelection().toString()
  const timeSinceMouseDown = Date.now() - mouseDownTime

  // Check if clicking an external link
  const isLink = e.target.closest('a[href]')

  // If clicking an external link inside a phx-click element, let the link work
  if (isLink && isLink.getAttribute('target') === '_blank') {
    const phxClickElement = e.target.closest('[phx-click]')
    if (phxClickElement && !isLink.hasAttribute('phx-click')) {
      e.stopPropagation()
      return
    }
  }

  // If text is selected OR if this was a drag (took more than 150ms), prevent navigation
  if ((selection && selection.length > 0) || timeSinceMouseDown > 150) {
    const navigableElement = e.target.closest('[phx-click="navigate_to_post"], [phx-click="navigate_to_message"], [phx-click="navigate_to_embedded_post"]')
    if (navigableElement) {
      e.preventDefault()
      e.stopPropagation()
      e.stopImmediatePropagation()
      return false
    }
  }
}

/**
 * Initialize navigation handlers
 */
export function initNavigationHandlers() {
  document.addEventListener("mousedown", handleMouseDown, true)
  document.addEventListener("click", handleNavigationClick, true)
}
