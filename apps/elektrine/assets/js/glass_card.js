/**
 * Glass Card Effect
 *
 * Apple-like glass effect with gradient glow following cursor.
 * Works for both LiveView (via hooks) and regular pages (via vanilla JS).
 */

// Track initialized elements to avoid double-initialization
const initializedElements = new WeakSet()

function initGlassCard(element) {
  if (initializedElements.has(element)) return

  // Use requestAnimationFrame to throttle updates and prevent layout thrashing
  let rafId = null
  let lastX = 0
  let lastY = 0

  const handleMouseMove = (e) => {
    // Skip if already waiting for animation frame
    if (rafId) return

    rafId = requestAnimationFrame(() => {
      const rect = element.getBoundingClientRect()
      const x = e.clientX - rect.left
      const y = e.clientY - rect.top

      // Only update if position changed significantly (reduces repaints)
      if (Math.abs(x - lastX) > 1 || Math.abs(y - lastY) > 1) {
        element.style.setProperty('--mouse-x', `${x}px`)
        element.style.setProperty('--mouse-y', `${y}px`)
        lastX = x
        lastY = y
      }

      rafId = null
    })
  }

  const handleMouseLeave = () => {
    // Cancel any pending animation frame
    if (rafId) {
      cancelAnimationFrame(rafId)
      rafId = null
    }
    element.style.setProperty('--mouse-x', '-1000px')
    element.style.setProperty('--mouse-y', '-1000px')
    lastX = 0
    lastY = 0
  }

  element.addEventListener('mousemove', handleMouseMove, { passive: true })
  element.addEventListener('mouseleave', handleMouseLeave, { passive: true })

  // Store cleanup function on element
  element._glassCardCleanup = () => {
    if (rafId) {
      cancelAnimationFrame(rafId)
    }
    element.removeEventListener('mousemove', handleMouseMove)
    element.removeEventListener('mouseleave', handleMouseLeave)
  }

  initializedElements.add(element)
}

function destroyGlassCard(element) {
  if (element._glassCardCleanup) {
    element._glassCardCleanup()
    delete element._glassCardCleanup
  }
  initializedElements.delete(element)
}

// Initialize all glass cards on page (for non-LiveView pages)
export function initAllGlassCards() {
  // Only initialize elements that have glass-card class but no phx-hook
  // (elements with phx-hook will be initialized by LiveView)
  document.querySelectorAll('.glass-card:not([phx-hook])').forEach(initGlassCard)
}

// Re-initialize after DOM changes (for turbolinks/pjax style navigation)
export function refreshGlassCards() {
  document.querySelectorAll('.glass-card:not([phx-hook])').forEach(initGlassCard)
}

// Export for direct use
export { initGlassCard, destroyGlassCard }
