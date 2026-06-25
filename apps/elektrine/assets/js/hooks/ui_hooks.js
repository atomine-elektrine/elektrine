import { copyToClipboard } from '../utils/clipboard'
import { FlashMessageManager } from '../flash_message_manager'
import { OverlayPortal } from '../utils/overlay_portal'

// General UI-related LiveView hooks
/**
 * UI Hooks
 * General-purpose UI hooks for common interactions like copying to clipboard,
 * focus management, flash messages, scrolling, and visual effects.
 */

const activePortalDropdowns = new Set()
const portalDropdownStates = new WeakMap()
let portalDropdownGlobalListenersBound = false
let activePortalTooltip = null

function ensurePortalDropdownGlobalListeners() {
  if (portalDropdownGlobalListenersBound || typeof window === 'undefined') return

  portalDropdownGlobalListenersBound = true
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

/**
 * Copy Email Hook
 * Copies email address to clipboard with visual feedback.
 */
export const CopyEmail = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      e.preventDefault()
      const email = this.el.dataset.email

      if (email) {
        copyToClipboard(email, 'email').then(copied => {
          if (!copied) return

          // Show success by changing icon temporarily
          const icon = this.el.querySelector('span')
          if (icon) {
            const originalClass = icon.className
            icon.className = 'hero-check w-3 h-3'

            setTimeout(() => {
              icon.className = originalClass
            }, 2000)
          }
        }).catch(() => {})
      }
    })
  }
}

export const PreserveFocus = {
  mounted() {
    this.focusedId = null

    this.handleEvent("restore_focus", () => {
      // Try to restore focus to the previously focused element
      if (this.focusedId) {
        const element = document.getElementById(this.focusedId)
        if (element) {
          element.focus()
        }
      }
    })

    // Track focus changes
    this.focusInHandler = (e) => {
      if (e.target.id) {
        this.focusedId = e.target.id
      }
    }

    document.addEventListener('focusin', this.focusInHandler)
  },

  destroyed() {
    if (this.focusInHandler) {
      document.removeEventListener('focusin', this.focusInHandler)
    }
  }
}

export const PreserveSearchFocus = {
  mounted() {
    this.snapshot = null
  },

  beforeUpdate() {
    const active = document.activeElement

    if (!(active instanceof HTMLInputElement) || !this.el.contains(active)) {
      this.snapshot = null
      return
    }

    this.snapshot = {
      id: active.id,
      name: active.name,
      value: active.value,
      selectionStart: active.selectionStart,
      selectionEnd: active.selectionEnd
    }
  },

  updated() {
    if (!this.snapshot) return

    const { id, name, value, selectionStart, selectionEnd } = this.snapshot
    const selector = id ? `#${CSS.escape(id)}` : `input[name="${CSS.escape(name)}"]`
    const input = this.el.querySelector(selector)

    if (!(input instanceof HTMLInputElement)) return


    input.value = value
    input.focus({ preventScroll: true })

    if (selectionStart !== null && selectionEnd !== null) {
      input.setSelectionRange(selectionStart, selectionEnd)
    }
  }
}

export const FlashAutoDismiss = {
  mounted() {
    this.schedule()
  },

  updated() {
    this.schedule()
  },

  schedule() {
    if (window.initAutoDismissFlashes) {
      window.initAutoDismissFlashes(this.el)
    }
  }
}

function resolveCopyText(el) {
  if (el.dataset.content) {
    return el.dataset.content
  }

  if (el.dataset.copyTarget) {
    const target = document.getElementById(el.dataset.copyTarget)
    if (target) {
      if ('value' in target && typeof target.value === 'string') {
        return target.value
      }

      return target.textContent
    }
  }

  const emailElement = document.getElementById('email-address')
  if (emailElement) {
    return emailElement.textContent
  }

  return ''
}

function showTemporaryCopySuccess(el, onDone = null) {
  el.classList.add('btn-success')
  el.dataset.copied = 'true'

  return setTimeout(() => {
    el.classList.remove('btn-success')
    delete el.dataset.copied
    if (typeof onDone === 'function') onDone()
  }, 2000)
}

export const FlashMessage = {
  mounted() {
    // Initialize flash message manager if not exists
    if (!window.flashManager) {
      window.flashManager = new FlashMessageManager()
    }

    // Reset any previous state to ensure clean mounting
    if (this.el.dataset.hiding) {
      delete this.el.dataset.hiding
    }

    // Reset element styles to ensure it can be shown
    this.el.style.display = ''
    this.el.style.opacity = ''
    this.el.style.transform = ''
    this.el.style.transition = ''

    // Add this message to the manager and get the ID
    this.messageId = window.flashManager.addMessage(this.el, this)

    // Set up auto-hide timer - trigger LiveView clear instead of hiding
    this.autoHideTimer = setTimeout(() => {
      this.clearFlash()
    }, 5000)

  },

  destroyed() {
    // Clear all timeouts
    if (this.autoHideTimer) clearTimeout(this.autoHideTimer)
    if (this.fadeOutTimeout) clearTimeout(this.fadeOutTimeout)

    // Remove from manager
    if (window.flashManager) {
      window.flashManager.removeMessage(this.el)
    }
  },

  clearFlash() {
    if (this.autoHideTimer) {
      clearTimeout(this.autoHideTimer)
      this.autoHideTimer = null
    }

    // Trigger the LiveView clear-flash event
    // This will properly clear the flash from LiveView's state
    const flashKey = this.el.getAttribute('phx-value-key')
    if (flashKey) {
      // Trigger a click event on the element which has phx-click="lv:clear-flash"
      this.el.click()
    }
  }
}

export const CopyToClipboard = {
  mounted() {
    this.onClick = e => {
      e.preventDefault()

      const textToCopy = resolveCopyText(this.el)

      if (textToCopy) {
        copyToClipboard(textToCopy).then(copied => {
          if (copied) {
            if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
            this.copySuccessTimer = showTemporaryCopySuccess(this.el, () => {
              this.copySuccessTimer = null
            })
          }
        }).catch(() => {})
      }
    }

    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
  }
}

export const FileExplorer = {
  mounted() {
    this.searchInput = this.el.querySelector('#file-explorer-search')
    this.interactiveSelector = 'a, button, input, select, textarea, summary, label, [data-row-ignore]'
    this.treeLayout = this.el.querySelector('[data-tree-layout]')
    this.treePane = this.el.querySelector('[data-tree-pane]')
    this.treeResizer = this.el.querySelector('[data-tree-resizer]')
    this.activeRowIndex = -1
    this.anchorRowIndex = null
    this.draggingTokens = null
    this.draggingRow = null
    this.lastDropTarget = null

    this.applyTreeWidth = (width) => {
      if (!this.treeLayout) return
      const clamped = Math.max(224, Math.min(width, 480))
      this.treeLayout.style.setProperty('--files-tree-width', `${clamped}px`)
      window.localStorage?.setItem('files-tree-width', String(clamped))
    }

    this.restoreTreeWidth = () => {
      const savedWidth = window.localStorage?.getItem('files-tree-width')
      if (!savedWidth) return

      const parsed = Number(savedWidth)
      if (Number.isFinite(parsed)) this.applyTreeWidth(parsed)
    }

    this.refreshRows = () => {
      this.rows = Array.from(this.el.querySelectorAll('[data-row-token]'))

      this.rows.forEach((row, index) => {
        row.dataset.rowIndex = String(index)
        row.tabIndex = index === this.activeRowIndex ? 0 : -1
      })

      if (this.rows.length === 0) {
        this.activeRowIndex = -1
        this.anchorRowIndex = null
      } else if (this.activeRowIndex < 0 || this.activeRowIndex >= this.rows.length) {
        this.setActiveRow(0, false)
      }
    }

    this.setActiveRow = (index, focus = true) => {
      if (!this.rows || this.rows.length === 0) return

      const boundedIndex = Math.max(0, Math.min(index, this.rows.length - 1))
      this.activeRowIndex = boundedIndex

      this.rows.forEach((row, rowIndex) => {
        row.tabIndex = rowIndex === boundedIndex ? 0 : -1
      })

      if (focus) {
        this.rows[boundedIndex].focus()
      }
    }

    this.setSelection = (tokens) => {
      this.pushEvent('set_selection', { tokens })
    }

    this.getSelectedTokens = () => {
      return this.rows
        .filter(row => row.dataset.rowSelected === 'true')
        .map(row => row.dataset.rowToken)
    }

    this.openRow = (row) => {
      if (!row || !row.dataset.rowOpenEvent) return

      const payload = {}
      if (row.dataset.rowOpenPath) payload.path = row.dataset.rowOpenPath
      if (row.dataset.rowOpenId) payload.id = row.dataset.rowOpenId
      this.pushEvent(row.dataset.rowOpenEvent, payload)
    }

    this.selectRangeTo = (targetIndex) => {
      if (!this.rows || this.rows.length === 0) return

      const anchor = this.anchorRowIndex == null ? this.activeRowIndex : this.anchorRowIndex
      const start = Math.min(anchor, targetIndex)
      const end = Math.max(anchor, targetIndex)
      const tokens = this.rows.slice(start, end + 1).map(row => row.dataset.rowToken)
      this.setSelection(tokens)
    }

    this.onClick = (event) => {
      const row = event.target.closest('[data-row-token]')
      if (!row || row.contains(event.target.closest(this.interactiveSelector))) return

      const rowIndex = Number(row.dataset.rowIndex || 0)
      this.setActiveRow(rowIndex)

      if (event.shiftKey) {
        this.selectRangeTo(rowIndex)
      } else if (event.metaKey || event.ctrlKey) {
        this.anchorRowIndex = rowIndex
        this.pushEvent('toggle_select', { token: row.dataset.rowToken })
      } else {
        this.anchorRowIndex = rowIndex
        this.setSelection([row.dataset.rowToken])
      }
    }

    this.onDoubleClick = (event) => {
      const row = event.target.closest('[data-row-token]')
      if (!row || row.contains(event.target.closest(this.interactiveSelector))) return

      this.openRow(row)
    }

    this.clearDropTarget = () => {
      if (!this.lastDropTarget) return
      this.lastDropTarget.classList.remove('bg-primary/15', 'ring-1', 'ring-primary/30')
      this.lastDropTarget = null
    }

    this.onDragStart = (event) => {
      const row = event.target.closest('[draggable="true"][data-row-token]')
      if (!row || event.target.closest(this.interactiveSelector)) {
        event.preventDefault()
        return
      }

      const rowToken = row.dataset.rowToken
      const selectedTokens = row.dataset.rowSelected === 'true' ? this.getSelectedTokens() : []
      this.draggingTokens = selectedTokens.length > 0 ? selectedTokens : [rowToken]
      this.draggingRow = row
      row.classList.add('opacity-60')

      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = 'move'
        event.dataTransfer.setData('text/plain', this.draggingTokens.join(','))
      }
    }

    this.onDragEnd = () => {
      if (this.draggingRow) this.draggingRow.classList.remove('opacity-60')
      this.draggingTokens = null
      this.draggingRow = null
      this.clearDropTarget()
    }

    this.onDragOver = (event) => {
      if (!this.draggingTokens || this.draggingTokens.length === 0) return
      const target = event.target.closest('[data-tree-folder-drop-path]')
      if (!target) return

      event.preventDefault()
      if (this.lastDropTarget && this.lastDropTarget !== target) this.clearDropTarget()
      this.lastDropTarget = target
      target.classList.add('bg-primary/15', 'ring-1', 'ring-primary/30')
    }

    this.onDragLeave = (event) => {
      const target = event.target.closest('[data-tree-folder-drop-path]')
      if (!target || target !== this.lastDropTarget) return

      const related = event.relatedTarget
      if (related instanceof HTMLElement && target.contains(related)) return
      this.clearDropTarget()
    }

    this.onDrop = (event) => {
      if (!this.draggingTokens || this.draggingTokens.length === 0) return
      const target = event.target.closest('[data-tree-folder-drop-path]')
      if (!target) return

      event.preventDefault()
      const folderPath = target.dataset.treeFolderDropPath || ''
      this.pushEvent('drag_move_items', { tokens: this.draggingTokens, folder: folderPath })
      this.onDragEnd()
    }

    this.onResizeStart = (event) => {
      if (!this.treeLayout || !this.treeResizer) return

      event.preventDefault()
      const startX = event.clientX
      const startWidth = this.treePane?.getBoundingClientRect().width || 288

      const onPointerMove = moveEvent => {
        const nextWidth = startWidth + (moveEvent.clientX - startX)
        this.applyTreeWidth(nextWidth)
      }

      const onPointerUp = () => {
        window.removeEventListener('pointermove', onPointerMove)
        window.removeEventListener('pointerup', onPointerUp)
        document.body.classList.remove('select-none', 'cursor-col-resize')
      }

      document.body.classList.add('select-none', 'cursor-col-resize')
      window.addEventListener('pointermove', onPointerMove)
      window.addEventListener('pointerup', onPointerUp)
    }

    this.onKeyDown = (event) => {
      const target = event.target
      const isTypingTarget =
        target instanceof HTMLElement &&
          (target.tagName === 'INPUT' ||
            target.tagName === 'TEXTAREA' ||
            target.tagName === 'SELECT' ||
            target.isContentEditable)

      if (event.key === '/' && !isTypingTarget && !event.metaKey && !event.ctrlKey && !event.altKey) {
        event.preventDefault()
        this.focusSearch()
        return
      }

      if ((event.key.toLowerCase() === 'f' && (event.metaKey || event.ctrlKey)) && !event.altKey) {
        event.preventDefault()
        this.focusSearch()
        return
      }

      if (event.key.toLowerCase() === 'n' && !isTypingTarget && !event.metaKey && !event.ctrlKey && !event.altKey) {
        event.preventDefault()
        this.pushEvent('toggle_new_folder', {})
        return
      }

      if (event.key === 'Escape' && !isTypingTarget) {
        this.pushEvent('cancel_new_folder', {})
        return
      }

      if (isTypingTarget || !this.rows || this.rows.length === 0) return

      if (event.key === 'ArrowDown') {
        event.preventDefault()
        const nextIndex = this.activeRowIndex < 0 ? 0 : this.activeRowIndex + 1

        if (event.shiftKey) {
          this.setActiveRow(nextIndex)
          this.selectRangeTo(this.activeRowIndex)
        } else {
          this.anchorRowIndex = Math.max(0, Math.min(nextIndex, this.rows.length - 1))
          this.setActiveRow(nextIndex)
        }

        return
      }

      if (event.key === 'ArrowUp') {
        event.preventDefault()
        const nextIndex = this.activeRowIndex < 0 ? 0 : this.activeRowIndex - 1

        if (event.shiftKey) {
          this.setActiveRow(nextIndex)
          this.selectRangeTo(this.activeRowIndex)
        } else {
          this.anchorRowIndex = Math.max(0, nextIndex)
          this.setActiveRow(nextIndex)
        }

        return
      }

      if (event.key === 'Home') {
        event.preventDefault()
        this.anchorRowIndex = 0
        this.setActiveRow(0)
        return
      }

      if (event.key === 'End') {
        event.preventDefault()
        this.anchorRowIndex = this.rows.length - 1
        this.setActiveRow(this.rows.length - 1)
        return
      }

      if (event.key === 'Enter') {
        event.preventDefault()
        this.openRow(this.rows[this.activeRowIndex])
        return
      }

      if (event.key === 'F2') {
        event.preventDefault()
        const row = this.rows[this.activeRowIndex]
        if (!row) return

        if (row.dataset.rowKind === 'folder') {
          this.pushEvent('open_manage_folder', { path: row.dataset.rowOpenPath })
          this.pushEvent('start_rename', { type: 'folder', path: row.dataset.rowOpenPath })
        } else {
          this.pushEvent('open_manage_file', { id: row.dataset.rowOpenId })
          this.pushEvent('start_rename', { type: 'file', id: row.dataset.rowOpenId })
        }

        return
      }

      if (event.key === ' ') {
        event.preventDefault()
        const row = this.rows[this.activeRowIndex]
        if (row) {
          this.anchorRowIndex = this.activeRowIndex
          this.pushEvent('toggle_select', { token: row.dataset.rowToken })
        }
      }
    }

    this.el.addEventListener('click', this.onClick)
    this.el.addEventListener('dblclick', this.onDoubleClick)
    this.el.addEventListener('dragstart', this.onDragStart)
    this.el.addEventListener('dragend', this.onDragEnd)
    this.el.addEventListener('dragover', this.onDragOver)
    this.el.addEventListener('dragleave', this.onDragLeave)
    this.el.addEventListener('drop', this.onDrop)
    if (this.treeResizer) this.treeResizer.addEventListener('pointerdown', this.onResizeStart)
    window.addEventListener('keydown', this.onKeyDown)
    this.restoreTreeWidth()
    this.refreshRows()
  },

  updated() {
    this.searchInput = this.el.querySelector('#file-explorer-search')
    this.refreshRows()
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener('click', this.onClick)
    if (this.onDoubleClick) this.el.removeEventListener('dblclick', this.onDoubleClick)
    if (this.onDragStart) this.el.removeEventListener('dragstart', this.onDragStart)
    if (this.onDragEnd) this.el.removeEventListener('dragend', this.onDragEnd)
    if (this.onDragOver) this.el.removeEventListener('dragover', this.onDragOver)
    if (this.onDragLeave) this.el.removeEventListener('dragleave', this.onDragLeave)
    if (this.onDrop) this.el.removeEventListener('drop', this.onDrop)
    if (this.treeResizer && this.onResizeStart) this.treeResizer.removeEventListener('pointerdown', this.onResizeStart)
    if (this.onKeyDown) window.removeEventListener('keydown', this.onKeyDown)
  },

  focusSearch() {
    if (!this.searchInput) return

    this.searchInput.focus()
    const length = this.searchInput.value.length
    this.searchInput.setSelectionRange(length, length)
  }
}

/**
 * Copy Button Hook
 * Provides visual feedback when copying to clipboard via LiveView events.
 * Changes button to checkmark icon with success color, then reverts after 2 seconds.
 * Used for share modals and other copy-to-clipboard buttons.
 */
export const CopyButton = {
  mounted() {
    // Listen for the copy_to_clipboard event from LiveView
    this.handleEvent("copy_to_clipboard", ({ text }) => {
      copyToClipboard(text).then(copied => {
        if (copied) {
          this.showSuccess()
        }
      }).catch(() => {})
    })
  },
  
  showSuccess() {
    if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
    this.el.classList.remove('btn-primary')
    this.el.classList.add('btn-success')
    this.el.dataset.copied = 'true'
    
    // Reset after 2 seconds
    this.copySuccessTimer = setTimeout(() => {
      this.el.classList.remove('btn-success')
      this.el.classList.add('btn-primary')
      delete this.el.dataset.copied
      this.copySuccessTimer = null
    }, 2000)
  },

  destroyed() {
    if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
  }
}

export const TimelineReply = {
  mounted() {
    this.replyFocusPending = false
    this.queuedAnchor = null
    this.pendingInteractionAnchor = null
    this.pendingInteractionScrollY = null
    this.prePatchAnchor = null
    this.prePatchScrollY = null
    this.prePatchShouldPreserve = false

    this.handleFeedClick = (event) => {
      const queuedBtn = event.target.closest('[data-load-queued-posts]')
      if (queuedBtn) {
        this.queuedAnchor = this.findVisiblePostAnchor()
        return
      }

      const interactiveTarget = event.target.closest('[phx-click]')
      if (!this.shouldTrackFeedInteraction(interactiveTarget)) return

      this.pendingInteractionAnchor = this.findVisiblePostAnchor()
      this.pendingInteractionScrollY = window.scrollY
    }

    this.el.addEventListener('click', this.handleFeedClick)

    // Focus and gently scroll active reply form into view without jumping around.
    this.handleEvent("focus_reply_form", ({ textarea_id, container_id }) => {
      this.replyFocusPending = true
      setTimeout(() => {
        const textarea = document.getElementById(textarea_id)
        const container = container_id ? document.getElementById(container_id) : null

        if (container) {
          const rect = container.getBoundingClientRect()
          const topGuard = 96
          const bottomGuard = 24
          const needsScroll =
            rect.top < topGuard || rect.bottom > (window.innerHeight - bottomGuard)

          if (needsScroll) {
            container.scrollIntoView({ behavior: 'smooth', block: 'center' })
          }
        }

        if (textarea) {
          textarea.focus()
          if (textarea.value) {
            textarea.setSelectionRange(textarea.value.length, textarea.value.length)
          }
        }
      }, 100)
    })
  },

  beforeUpdate() {
    this.prePatchShouldPreserve = this.shouldPreserveFeedPatch()

    if (this.prePatchShouldPreserve) {
      this.prePatchAnchor = this.pendingInteractionAnchor || this.findVisiblePostAnchor()
      this.prePatchScrollY =
        typeof this.pendingInteractionScrollY === 'number'
          ? this.pendingInteractionScrollY
          : window.scrollY
    } else {
      this.prePatchAnchor = null
      this.prePatchScrollY = null
    }
  },

  updated() {
    if (this.queuedAnchor) {
      this.restoreAnchorPosition(this.queuedAnchor, null)

      this.queuedAnchor = null
      this.pendingInteractionAnchor = null
      this.pendingInteractionScrollY = null
      this.prePatchAnchor = null
      this.prePatchScrollY = null
      this.prePatchShouldPreserve = false
      this.replyFocusPending = false
      return
    }

    if (this.prePatchShouldPreserve) {
      this.restoreAnchorPosition(this.prePatchAnchor, this.prePatchScrollY)
    }

    this.pendingInteractionAnchor = null
    this.pendingInteractionScrollY = null
    this.prePatchAnchor = null
    this.prePatchScrollY = null
    this.prePatchShouldPreserve = false
    this.replyFocusPending = false
  },

  findVisiblePostAnchor() {
    const postCards = this.el.querySelectorAll('[data-post-id]')
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight

    for (const card of postCards) {
      const rect = card.getBoundingClientRect()
      if (rect.bottom <= 0 || rect.top >= viewportHeight) continue

      const postId = card.dataset.postId
      if (!postId) continue

      return {
        postId,
        top: rect.top
      }
    }

    return null
  },

  restoreAnchorPosition(anchorSnapshot, fallbackScrollY) {
    if (anchorSnapshot?.postId) {
      const anchor = this.findPostById(anchorSnapshot.postId)

      if (anchor) {
        const newTop = anchor.getBoundingClientRect().top
        const delta = newTop - anchorSnapshot.top
        if (delta !== 0) window.scrollBy(0, delta)
        return
      }
    }

    if (typeof fallbackScrollY === 'number') {
      window.scrollTo({ top: fallbackScrollY, behavior: 'auto' })
    }
  },

  findPostById(postId) {
    if (!postId) return null

    const escapedPostId = typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(postId) : postId
    return this.el.querySelector(`[data-post-id="${escapedPostId}"]`)
  },

  shouldPreserveFeedPatch() {
    if (this.timelineLoadMoreActive()) return false

    if (this.pendingInteractionScrollY == null || this.pendingInteractionScrollY < 200) return false

    return this.pendingInteractionAnchor !== null
  },

  shouldTrackFeedInteraction(target) {
    if (!target || !target.closest('[data-post-id]')) return false

    return [
      'like_post',
      'unlike_post',
      'boost_post',
      'unboost_post',
      'save_post',
      'unsave_post',
      'react_to_post',
      'vote',
      'vote_post',
      'vote_comment'
    ].includes(target.getAttribute('phx-click'))
  },

  timelineLoadMoreActive() {
    const infiniteScrollRoot = this.el.querySelector('#timeline-infinite-scroll')
    return infiniteScrollRoot?.dataset?.loadingMore === 'true'
  },

  destroyed() {
    this.el.removeEventListener('click', this.handleFeedClick)
  }
}

export function initBackupCodesPrinter(element) {
  if (!element || element.dataset.backupCodesPrinterInitialized === 'true') return

  const printButton = element.querySelector('[data-action="print"]')
  if (!printButton) return

  const handlePrint = () => {
    const codes = JSON.parse(element.dataset.codes || '[]')
    printBackupCodes(codes)
  }

  printButton.addEventListener('click', handlePrint)

  element._backupCodesPrinterCleanup = () => {
    printButton.removeEventListener('click', handlePrint)
  }

  element.dataset.backupCodesPrinterInitialized = 'true'
}

export function destroyBackupCodesPrinter(element) {
  if (!element) return

  if (typeof element._backupCodesPrinterCleanup === 'function') {
    element._backupCodesPrinterCleanup()
    delete element._backupCodesPrinterCleanup
  }

  delete element.dataset.backupCodesPrinterInitialized
}

export function initBackupCodesPrinters(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === 'function' ? rootCandidate : document

  root.querySelectorAll('[data-backup-codes-printer]').forEach((element) => {
    initBackupCodesPrinter(element)
  })
}

function printBackupCodes(codes) {
  const printWindow = window.open('', '_blank')

  const printContent = `
    <html>
    <head>
      <title>Elektrine Backup Codes</title>
      <style>
        body { font-family: Arial, sans-serif; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .codes-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; }
        .code { padding: 10px; border: 1px solid #ccc; text-align: center; font-family: monospace; font-size: 14px; }
        .warning { background-color: #fff3cd; border: 1px solid #ffeaa7; padding: 15px; margin-bottom: 20px; }
      </style>
    </head>
    <body>
      <div class="header">
        <h1>Elektrine Two-Factor Authentication</h1>
        <h2>Backup Codes</h2>
        <p>Generated on: ${new Date().toLocaleDateString()}</p>
      </div>

      <div class="warning">
        <strong>Important:</strong> Keep these codes safe and secure. Each code can only be used once to access your account if you lose your authenticator device.
      </div>

      <div class="codes-grid">
        ${codes.map(code => `<div class="code">${escapeHtml(String(code))}</div>`).join('')}
      </div>
    </body>
    </html>
  `

  printWindow.document.write(printContent)
  printWindow.document.close()
  printWindow.print()
}

function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}

// Scroll to top button that appears when scrolled down
export const ScrollToTop = {
  mounted() {
    this.scrollThreshold = 400
    this.scrollContainer = this.getScrollContainer()
    this.scrollTarget = this.scrollContainer === window ? window : this.scrollContainer
    this.ticking = false

    this.handleScroll = () => {
      if (this.ticking) return

      this.ticking = true
      window.requestAnimationFrame(() => {
        this.ticking = false
        this.syncVisibility()
      })
    }

    this.handleClick = () => {
      const target = this.scrollContainer === window
        ? window
        : (this.scrollContainer || document.scrollingElement || document.documentElement)

      target.scrollTo({
        top: 0,
        behavior: 'smooth'
      })
    }

    this.el.addEventListener('click', this.handleClick)
    this.scrollTarget.addEventListener('scroll', this.handleScroll, { passive: true })
    window.addEventListener('resize', this.handleScroll, { passive: true })
    this.syncVisibility()
  },

  updated() {
    const nextScrollContainer = this.getScrollContainer()

    if (nextScrollContainer === this.scrollContainer) {
      this.syncVisibility()
      return
    }

    this.scrollTarget?.removeEventListener('scroll', this.handleScroll)
    this.scrollContainer = nextScrollContainer
    this.scrollTarget = this.scrollContainer === window ? window : this.scrollContainer
    this.scrollTarget.addEventListener('scroll', this.handleScroll, { passive: true })
    this.syncVisibility()
  },

  destroyed() {
    this.scrollTarget?.removeEventListener('scroll', this.handleScroll)
    window.removeEventListener('resize', this.handleScroll)
    this.el.removeEventListener('click', this.handleClick)
  },

  getScrollContainer() {
    const rootId = this.el.dataset.scrollRoot
    const root = rootId ? document.getElementById(rootId) : this.el.parentElement
    let current = root

    while (current && current !== document.body) {
      if (this.isScrollable(current)) return current
      current = current.parentElement
    }

    return window
  },

  isScrollable(element) {
    if (!element) return false

    const styles = window.getComputedStyle(element)
    const canScroll = ['auto', 'scroll', 'overlay'].includes(styles.overflowY)

    return canScroll && element.scrollHeight > element.clientHeight + 1
  },

  getScrollTop() {
    if (this.scrollContainer === window) {
      return window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0
    }

    return this.scrollContainer?.scrollTop || 0
  },

  syncVisibility() {
    if (this.getScrollTop() > this.scrollThreshold) {
      this.el.classList.remove('opacity-0', 'pointer-events-none')
      this.el.classList.add('opacity-100', 'pointer-events-auto')
    } else {
      this.el.classList.remove('opacity-100', 'pointer-events-auto')
      this.el.classList.add('opacity-0', 'pointer-events-none')
    }
  }
}

export const RemoteProfileStickyFollow = {
  mounted() {
    this.panel = this.el.querySelector('.remote-user-sticky-follow-panel') || this.el
    this.target = this.resolveTarget()
    this.ticking = false

    this.syncVisibility = this.syncVisibility.bind(this)
    this.scheduleSync = this.scheduleSync.bind(this)

    window.addEventListener('scroll', this.scheduleSync, { passive: true })
    window.addEventListener('resize', this.scheduleSync, { passive: true })

    if (this.target && 'IntersectionObserver' in window) {
      this.observer = new IntersectionObserver(this.scheduleSync, { threshold: 0 })
      this.observer.observe(this.target)
    }

    this.syncVisibility()
  },

  updated() {
    const nextTarget = this.resolveTarget()

    if (nextTarget !== this.target) {
      if (this.observer && this.target) this.observer.unobserve(this.target)
      this.target = nextTarget
      if (this.observer && this.target) this.observer.observe(this.target)
    }

    this.panel = this.el.querySelector('.remote-user-sticky-follow-panel') || this.el
    this.syncVisibility()
  },

  destroyed() {
    window.removeEventListener('scroll', this.scheduleSync)
    window.removeEventListener('resize', this.scheduleSync)
    if (this.observer) this.observer.disconnect()
  },

  resolveTarget() {
    const targetId = this.el.dataset.followTarget
    return targetId ? document.getElementById(targetId) : null
  },

  scheduleSync() {
    if (this.ticking) return

    this.ticking = true
    window.requestAnimationFrame(() => {
      this.ticking = false
      this.syncVisibility()
    })
  },

  syncVisibility() {
    if (!this.target || !this.panel) return

    const targetRect = this.target.getBoundingClientRect()
    const showOffset = Number.parseInt(this.el.dataset.showOffset || '0', 10) || 0
    const shouldShow = targetRect.bottom <= -showOffset

    this.el.setAttribute('aria-hidden', shouldShow ? 'false' : 'true')

    if (shouldShow) {
      this.panel.classList.remove('hidden', 'opacity-0', 'pointer-events-none')
      this.panel.classList.add('flex', 'opacity-100', 'pointer-events-auto')
    } else {
      this.panel.classList.remove('flex', 'opacity-100', 'pointer-events-auto')
      this.panel.classList.add('hidden', 'opacity-0', 'pointer-events-none')
    }
  }
}

/**
 * ImageFallback - Handles image load errors without inline event handlers
 * Hides the image and shows a fallback element when image fails to load
 *
 * Usage:
 *   <img src="..." phx-hook="ImageFallback" />
 *   <img src="..." phx-hook="ImageFallback" data-hide-target="parent" />
 *   <img src="..." phx-hook="ImageFallback" data-hide-target="closest" data-hide-selector="button" />
 *   <div data-fallback-icon class="hidden">Fallback content</div>
 *
 * The hook will hide the configured target and show the next sibling with [data-fallback-icon]
 */
export const ImageFallback = {
  mounted() {
    this.onError = () => {
      const hideTarget = this.resolveHideTarget()
      if (hideTarget) {
        hideTarget.style.display = 'none'
      }

      const fallback = this.el.nextElementSibling
      if (fallback && fallback.hasAttribute('data-fallback-icon')) {
        fallback.style.display = 'flex'
        fallback.classList.remove('hidden')
      }
    }

    this.el.addEventListener('error', this.onError)

    // Also handle case where image is already broken (cached error)
    if (this.el.complete && this.el.naturalHeight === 0) {
      this.el.dispatchEvent(new Event('error'))
    }
  },

  destroyed() {
    if (this.onError) {
      this.el.removeEventListener('error', this.onError)
    }
  },

  resolveHideTarget() {
    const hideTarget = this.el.dataset.hideTarget || 'self'

    if (hideTarget === 'parent') {
      return this.el.parentElement
    }

    if (hideTarget === 'closest') {
      const selector = this.el.dataset.hideSelector
      return selector ? this.el.closest(selector) : this.el
    }

    return this.el
  }
}
