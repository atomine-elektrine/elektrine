/**
 * Cursor Glow Effect
 *
 * Subtly brightens grid lines near the cursor position.
 * Uses smooth interpolation and fade to avoid abrupt snapping.
 */

let rafId = null
let overlay = null
let initialized = false

const OFFSCREEN = -1000
const BASE_RADIUS = 340
const RADIUS_BOOST = 140

const state = {
  targetX: OFFSCREEN,
  targetY: OFFSCREEN,
  currentX: OFFSCREEN,
  currentY: OFFSCREEN,
  velocity: 0,
  radius: BASE_RADIUS,
  opacity: 0,
  hovering: false
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

function resetState() {
  state.targetX = OFFSCREEN
  state.targetY = OFFSCREEN
  state.currentX = OFFSCREEN
  state.currentY = OFFSCREEN
  state.velocity = 0
  state.radius = BASE_RADIUS
  state.opacity = 0
  state.hovering = false
}

function applyOverlayState() {
  if (!overlay) return
  overlay.style.setProperty('--cursor-x', `${state.currentX.toFixed(2)}px`)
  overlay.style.setProperty('--cursor-y', `${state.currentY.toFixed(2)}px`)
  overlay.style.setProperty('--cursor-radius', `${state.radius.toFixed(2)}px`)
  overlay.style.setProperty('--cursor-opacity', state.opacity.toFixed(3))
}

function tick() {
  if (!overlay) {
    rafId = null
    return
  }

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  const positionLerp = reducedMotion ? 1 : 0.2
  const radiusLerp = reducedMotion ? 1 : 0.14
  const opacityLerp = reducedMotion ? 1 : state.hovering ? 0.22 : 0.12

  const dx = state.targetX - state.currentX
  const dy = state.targetY - state.currentY
  state.currentX += dx * positionLerp
  state.currentY += dy * positionLerp

  const targetRadius = BASE_RADIUS + clamp(state.velocity * 2, 0, RADIUS_BOOST)
  state.radius += (targetRadius - state.radius) * radiusLerp
  state.velocity *= reducedMotion ? 0 : 0.82

  const targetOpacity = state.hovering ? 1 : 0
  state.opacity += (targetOpacity - state.opacity) * opacityLerp

  applyOverlayState()

  const isSettled =
    Math.abs(dx) < 0.5 &&
    Math.abs(dy) < 0.5 &&
    Math.abs(targetOpacity - state.opacity) < 0.01 &&
    Math.abs(targetRadius - state.radius) < 0.5

  if (isSettled && !state.hovering) {
    state.currentX = OFFSCREEN
    state.currentY = OFFSCREEN
    state.targetX = OFFSCREEN
    state.targetY = OFFSCREEN
    state.velocity = 0
    state.radius = BASE_RADIUS
    state.opacity = 0
    applyOverlayState()
    rafId = null
    return
  }

  rafId = requestAnimationFrame(tick)
}

function ensureAnimationFrame() {
  if (!rafId) {
    rafId = requestAnimationFrame(tick)
  }
}

function updateCursorPosition(e) {
  if (!overlay) return

  if (state.targetX !== OFFSCREEN && state.targetY !== OFFSCREEN) {
    state.velocity = Math.hypot(e.clientX - state.targetX, e.clientY - state.targetY)
  } else {
    state.velocity = 0
  }

  state.targetX = e.clientX
  state.targetY = e.clientY
  state.hovering = true

  // Avoid sliding in from off-screen on first move.
  if (state.currentX === OFFSCREEN || state.currentY === OFFSCREEN) {
    state.currentX = state.targetX
    state.currentY = state.targetY
  }

  ensureAnimationFrame()
}

function handleMouseLeave() {
  state.hovering = false
  ensureAnimationFrame()
}

function handleWindowBlur() {
  state.hovering = false
  ensureAnimationFrame()
}

export function initCursorGlow() {
  if (!window.matchMedia('(pointer: fine)').matches || initialized) return

  overlay = document.getElementById('cursor-glow-overlay')
  if (!overlay) {
    overlay = document.createElement('div')
    overlay.id = 'cursor-glow-overlay'
    document.body.insertBefore(overlay, document.body.firstChild)
  }

  resetState()
  applyOverlayState()
  document.addEventListener('mousemove', updateCursorPosition, { passive: true })
  document.addEventListener('mouseleave', handleMouseLeave, { passive: true })
  window.addEventListener('blur', handleWindowBlur, { passive: true })
  initialized = true
}

export function destroyCursorGlow() {
  if (!initialized) return

  document.removeEventListener('mousemove', updateCursorPosition)
  document.removeEventListener('mouseleave', handleMouseLeave)
  window.removeEventListener('blur', handleWindowBlur)

  if (overlay && overlay.parentNode) {
    overlay.parentNode.removeChild(overlay)
    overlay = null
  }
  if (rafId) {
    cancelAnimationFrame(rafId)
    rafId = null
  }

  resetState()
  initialized = false
}
