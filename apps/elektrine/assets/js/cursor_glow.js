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
const BASE_RADIUS = 300
const RADIUS_BOOST = 110

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
  const radiusLerp = reducedMotion ? 1 : 0.18
  const opacityLerp = reducedMotion ? 1 : state.hovering ? 0.28 : 0.16

  // Keep the glow anchored to the pointer to avoid a trailing/laggy feel.
  if (state.targetX !== OFFSCREEN && state.targetY !== OFFSCREEN) {
    state.currentX = state.targetX
    state.currentY = state.targetY
  }

  const targetRadius = BASE_RADIUS + clamp(state.velocity * 2, 0, RADIUS_BOOST)
  state.radius += (targetRadius - state.radius) * radiusLerp
  state.velocity *= reducedMotion ? 0 : 0.82

  const targetOpacity = state.hovering ? 0.85 : 0
  state.opacity += (targetOpacity - state.opacity) * opacityLerp

  applyOverlayState()

  const isSettled =
    Math.abs(state.targetX - state.currentX) < 0.01 &&
    Math.abs(state.targetY - state.currentY) < 0.01 &&
    Math.abs(targetOpacity - state.opacity) < 0.01 &&
    Math.abs(targetRadius - state.radius) < 0.5

  if (isSettled) {
    if (!state.hovering) {
      state.currentX = OFFSCREEN
      state.currentY = OFFSCREEN
      state.targetX = OFFSCREEN
      state.targetY = OFFSCREEN
      state.velocity = 0
      state.radius = BASE_RADIUS
      state.opacity = 0
      applyOverlayState()
    }

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

function activateAt(x, y, velocity = 0) {
  if (!overlay) return

  if (state.targetX !== OFFSCREEN && state.targetY !== OFFSCREEN) {
    state.velocity = Math.max(velocity, Math.hypot(x - state.targetX, y - state.targetY))
  } else {
    state.velocity = velocity
  }

  state.targetX = x
  state.targetY = y
  state.hovering = true

  // Sync immediately so the glow never appears one frame behind the cursor.
  state.currentX = state.targetX
  state.currentY = state.targetY
  applyOverlayState()

  ensureAnimationFrame()
}

function updateCursorPosition(e) {
  if (!overlay) return

  const velocity =
    state.targetX !== OFFSCREEN && state.targetY !== OFFSCREEN
      ? Math.hypot(e.clientX - state.targetX, e.clientY - state.targetY)
      : 0

  activateAt(e.clientX, e.clientY, velocity)
}

function handleMouseLeave() {
  state.hovering = false
  ensureAnimationFrame()
}

function handleMouseEnter(e) {
  activateAt(e.clientX, e.clientY, 0)
}

function handleMouseDown(e) {
  // Keep glow active while clicking controls even if no move event follows.
  activateAt(e.clientX, e.clientY, 8)
}

function handleWindowBlur() {
  state.hovering = false
  ensureAnimationFrame()
}

function handleWindowFocus() {
  if (state.targetX !== OFFSCREEN && state.targetY !== OFFSCREEN) {
    activateAt(state.targetX, state.targetY, 0)
  }
}

export function initCursorGlow() {
  if (!window.matchMedia('(pointer: fine)').matches) return

  const nextOverlay = document.getElementById('cursor-glow-overlay')
  if (!nextOverlay) {
    destroyCursorGlow()
    return
  }

  overlay = nextOverlay

  if (initialized) {
    resetState()
    applyOverlayState()
    return
  }

  resetState()
  applyOverlayState()
  document.addEventListener('mousemove', updateCursorPosition, { passive: true })
  document.addEventListener('mouseleave', handleMouseLeave, { passive: true })
  document.addEventListener('mouseenter', handleMouseEnter, { passive: true })
  document.addEventListener('mousedown', handleMouseDown, { passive: true })
  window.addEventListener('blur', handleWindowBlur, { passive: true })
  window.addEventListener('focus', handleWindowFocus, { passive: true })
  initialized = true
}

export function destroyCursorGlow() {
  if (!initialized) return

  document.removeEventListener('mousemove', updateCursorPosition)
  document.removeEventListener('mouseleave', handleMouseLeave)
  document.removeEventListener('mouseenter', handleMouseEnter)
  document.removeEventListener('mousedown', handleMouseDown)
  window.removeEventListener('blur', handleWindowBlur)
  window.removeEventListener('focus', handleWindowFocus)

  overlay = null
  if (rafId) {
    cancelAnimationFrame(rafId)
    rafId = null
  }

  resetState()
  initialized = false
}
