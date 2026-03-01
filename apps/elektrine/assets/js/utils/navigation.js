/**
 * Navigation Utilities
 * Handles click navigation with text selection awareness
 */

let mouseDownTarget = null
let mouseDownTime = 0
let mouseDownX = 0
let mouseDownY = 0

/**
 * Track mouse down for drag detection
 */
function handleMouseDown(e) {
  mouseDownTarget = e.target
  mouseDownTime = Date.now()
  mouseDownX = typeof e.clientX === 'number' ? e.clientX : 0
  mouseDownY = typeof e.clientY === 'number' ? e.clientY : 0
}

/**
 * Handle clicks with text selection and link awareness
 */
function handleNavigationClick(e) {
  const selection = window.getSelection().toString()
  const timeSinceMouseDown = Date.now() - mouseDownTime
  const clickX = typeof e.clientX === 'number' ? e.clientX : mouseDownX
  const clickY = typeof e.clientY === 'number' ? e.clientY : mouseDownY
  const pointerDistance = Math.hypot(clickX - mouseDownX, clickY - mouseDownY)
  const isDragGesture = pointerDistance > 6 && timeSinceMouseDown > 120

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

  // If text is selected or this was an actual drag gesture, prevent navigation.
  // Do not block intentional clicks simply because the click was held slightly longer.
  if ((selection && selection.length > 0) || isDragGesture) {
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
