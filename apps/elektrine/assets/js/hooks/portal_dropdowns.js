import { OverlayPortal } from '../utils/overlay_portal'

const activePortalDropdowns = new Set()
const portalDropdownStates = new WeakMap()
let portalDropdownGlobalListenersBound = false
let activePortalTooltip = null

function ensurePortalDropdownGlobalListeners() {
  if (portalDropdownGlobalListenersBound || typeof window === 'undefined') return

  portalDropdownGlobalListenersBound = true
  // js-check: allow-global-listener-singleton
  document.addEventListener('click', handlePortalDropdownDocumentClick)
  document.addEventListener('pointerdown', handlePortalDropdownDocumentPointerDown)
  document.addEventListener('keydown', handlePortalDropdownDocumentKeyDown)
  document.addEventListener('mouseover', handlePortalTooltipMouseOver)
  document.addEventListener('mouseout', handlePortalTooltipMouseOut)
  document.addEventListener('focusin', handlePortalTooltipFocusIn)
  document.addEventListener('focusout', handlePortalTooltipFocusOut)
  window.addEventListener('scroll', repositionActivePortalDropdowns, true)
  window.addEventListener('resize', repositionActivePortalDropdowns)
}

function handlePortalDropdownDocumentClick(event) {
  const target = event.target instanceof Element ? event.target : null
  const trigger = target?.closest?.('[data-portal-dropdown-trigger]')
  const root = trigger?.closest?.('[data-portal-dropdown-root]')

  if (root) {
    event.preventDefault()
    event.stopPropagation()
    togglePortalDropdown(root)
    return
  }

  const state = portalDropdownStateForTarget(target)
  if (state?.isOpen && target?.closest?.('button, a, [phx-click]')) {
    window.setTimeout(() => closePortalDropdown(state), 0)
  }
}

function handlePortalDropdownDocumentPointerDown(event) {
  if (activePortalDropdowns.size === 0) return

  const target = event.target instanceof Element ? event.target : null
  const path = typeof event.composedPath === 'function' ? event.composedPath() : []

  for (const state of activePortalDropdowns) {
    if (
      path.includes(state.root) ||
      path.includes(state.menu) ||
      (target && state.root.contains(target)) ||
      (target && state.menu.contains(target))
    ) {
      return
    }
  }

  closeAllPortalDropdowns()
}

function handlePortalDropdownDocumentKeyDown(event) {
  if (event.key !== 'Escape' || activePortalDropdowns.size === 0) return

  event.preventDefault()
  const opened = Array.from(activePortalDropdowns)
  const lastOpened = opened[opened.length - 1]
  closeAllPortalDropdowns()
  lastOpened?.trigger?.focus?.({ preventScroll: true })
}

function repositionActivePortalDropdowns() {
  for (const state of activePortalDropdowns) positionPortalDropdown(state)
  if (activePortalTooltip) positionPortalTooltip(activePortalTooltip)
}

function togglePortalDropdown(root) {
  const state = getPortalDropdownState(root)
  if (!state) return

  if (state.isOpen) closePortalDropdown(state)
  else openPortalDropdown(state)
}

function getPortalDropdownState(root) {
  const trigger = root.querySelector('[data-portal-dropdown-trigger]')
  const menu = root.querySelector('[data-portal-dropdown-menu]')

  if (!trigger || !menu) return null

  const existing = portalDropdownStates.get(root)
  if (existing?.trigger === trigger && existing?.menu === menu) return existing

  if (existing) closePortalDropdown(existing)

  const state = {
    root,
    trigger,
    menu,
    portal: new OverlayPortal(menu, {
      portalRoot: root.closest('[data-phx-main]') || document.body
    }),
    shouldPortal: root.dataset.portalDropdownMode !== 'anchored',
    isOpen: false
  }

  trigger.setAttribute('aria-expanded', 'false')
  menu.setAttribute('aria-hidden', 'true')
  applyPortalDropdownClosedStyles(menu)
  portalDropdownStates.set(root, state)

  return state
}

function openPortalDropdown(state) {
  closeAllPortalDropdowns(state)

  state.isOpen = true
  state.root.dataset.portalDropdownOpen = 'true'
  state.trigger.setAttribute('aria-expanded', 'true')
  state.menu.setAttribute('aria-hidden', 'false')
  if (state.shouldPortal) state.portal.mount()
  positionPortalDropdown(state)
  applyPortalDropdownOpenStyles(state.menu)
  activePortalDropdowns.add(state)
}

function closePortalDropdown(state) {
  state.isOpen = false
  delete state.root.dataset.portalDropdownOpen
  state.trigger?.setAttribute('aria-expanded', 'false')
  state.menu?.setAttribute('aria-hidden', 'true')
  applyPortalDropdownClosedStyles(state.menu)

  if (state.shouldPortal) state.portal?.restore()
  else state.portal?.clearPosition()

  activePortalDropdowns.delete(state)
}

function closeAllPortalDropdowns(exceptState = null) {
  for (const state of Array.from(activePortalDropdowns)) {
    if (state !== exceptState) closePortalDropdown(state)
  }
}

function positionPortalDropdown(state) {
  state.portal?.positionNear(state.trigger, {
    placement: state.root.dataset.portalPlacement || 'auto',
    align: state.root.dataset.portalAlign || 'start',
    margin: Number.parseInt(state.root.dataset.portalMargin || '8', 10) || 8,
    zIndex: Number.parseInt(state.root.dataset.portalZIndex || '10000', 10) || 10000
  })
}

function handlePortalTooltipMouseOver(event) {
  const target = event.target instanceof Element ? event.target : null
  const trigger = target?.closest?.('[data-portal-tooltip][data-tip]')
  const relatedTarget = event.relatedTarget instanceof Node ? event.relatedTarget : null

  if (!trigger || trigger.contains(relatedTarget)) return
  showPortalTooltip(trigger)
}

function handlePortalTooltipMouseOut(event) {
  const target = event.target instanceof Element ? event.target : null
  const trigger = target?.closest?.('[data-portal-tooltip][data-tip]')
  const relatedTarget = event.relatedTarget instanceof Node ? event.relatedTarget : null

  if (!trigger || trigger.contains(relatedTarget)) return
  hidePortalTooltip(trigger)
}

function handlePortalTooltipFocusIn(event) {
  const trigger = event.target instanceof Element
    ? event.target.closest('[data-portal-tooltip][data-tip]')
    : null

  if (trigger) showPortalTooltip(trigger)
}

function handlePortalTooltipFocusOut(event) {
  const trigger = event.target instanceof Element
    ? event.target.closest('[data-portal-tooltip][data-tip]')
    : null

  if (trigger) hidePortalTooltip(trigger)
}

function showPortalTooltip(trigger) {
  const content = trigger.dataset.tip
  if (!content) return

  if (activePortalTooltip?.trigger === trigger) {
    activePortalTooltip.tooltip.textContent = content
    positionPortalTooltip(activePortalTooltip)
    return
  }

  removePortalTooltip()

  const tooltip = document.createElement('div')
  tooltip.className = 'floating-panel portal-tooltip rounded-box px-2 py-1 text-xs font-medium text-base-content'
  tooltip.textContent = content
  tooltip.setAttribute('role', 'tooltip')
  tooltip.style.pointerEvents = 'none'
  tooltip.style.maxWidth = 'min(18rem, calc(100vw - 1rem))'
  tooltip.style.whiteSpace = 'normal'

  const portal = new OverlayPortal(tooltip, {
    portalRoot: trigger.closest('[data-phx-main]') || document.body
  })

  activePortalTooltip = { trigger, tooltip, portal }
  portal.mount()
  positionPortalTooltip(activePortalTooltip)
}

function hidePortalTooltip(trigger) {
  if (!activePortalTooltip || activePortalTooltip.trigger !== trigger) return
  removePortalTooltip()
}

function removePortalTooltip() {
  if (!activePortalTooltip) return

  activePortalTooltip.tooltip.remove()
  activePortalTooltip = null
}

function positionPortalTooltip(state) {
  state.portal.positionNear(state.trigger, {
    placement: state.trigger.dataset.portalTooltipPlacement || 'top',
    align: state.trigger.dataset.portalTooltipAlign || 'center',
    margin: Number.parseInt(state.trigger.dataset.portalTooltipMargin || '8', 10) || 8,
    zIndex: Number.parseInt(state.trigger.dataset.portalTooltipZIndex || '10001', 10) || 10001
  })
}

function applyPortalDropdownOpenStyles(menu) {
  if (!menu) return

  Object.assign(menu.style, {
    visibility: 'visible',
    opacity: '1',
    pointerEvents: 'auto',
    transform: 'translateY(0) scale(1)'
  })
}

function applyPortalDropdownClosedStyles(menu) {
  if (!menu) return

  Object.assign(menu.style, {
    visibility: 'hidden',
    opacity: '0',
    pointerEvents: 'none',
    transform: 'translateY(-4px) scale(0.98)'
  })
}

function portalDropdownStateForTarget(target) {
  if (!target) return null

  for (const state of activePortalDropdowns) {
    if (state.root.contains(target) || state.menu.contains(target)) return state
  }

  return null
}

ensurePortalDropdownGlobalListeners()
