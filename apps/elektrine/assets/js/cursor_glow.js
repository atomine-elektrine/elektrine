/**
 * Cursor Glow Effect
 *
 * Subtly brightens grid lines near the cursor position.
 * Uses a dedicated overlay element to avoid affecting scrollbars.
 */

let rafId = null
let lastX = 0
let lastY = 0
let overlay = null

function updateCursorPosition(e) {
  if (rafId || !overlay) return

  rafId = requestAnimationFrame(() => {
    const x = e.clientX
    const y = e.clientY

    if (Math.abs(x - lastX) > 1 || Math.abs(y - lastY) > 1) {
      overlay.style.setProperty('--cursor-x', `${x}px`)
      overlay.style.setProperty('--cursor-y', `${y}px`)
      lastX = x
      lastY = y
    }

    rafId = null
  })
}

function handleMouseLeave() {
  if (overlay) {
    overlay.style.setProperty('--cursor-x', '-1000px')
    overlay.style.setProperty('--cursor-y', '-1000px')
  }
}

export function initCursorGlow() {
  if (window.matchMedia('(pointer: fine)').matches) {
    // Create the overlay element
    overlay = document.createElement('div')
    overlay.id = 'cursor-glow-overlay'
    document.body.insertBefore(overlay, document.body.firstChild)

    document.addEventListener('mousemove', updateCursorPosition, { passive: true })
    document.addEventListener('mouseleave', handleMouseLeave, { passive: true })
  }
}

export function destroyCursorGlow() {
  document.removeEventListener('mousemove', updateCursorPosition)
  document.removeEventListener('mouseleave', handleMouseLeave)
  if (overlay && overlay.parentNode) {
    overlay.parentNode.removeChild(overlay)
    overlay = null
  }
  if (rafId) {
    cancelAnimationFrame(rafId)
    rafId = null
  }
}
