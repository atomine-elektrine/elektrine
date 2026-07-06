import { FlashMessageManager } from '../flash_message_manager'
import './portal_dropdowns'

function postAnchorFromElement(card) {
  const postId = card?.dataset?.postId
  if (!postId) return null

  return { postId, top: card.getBoundingClientRect().top }
}

function findVisiblePostAnchor(root = document) {
  const viewportHeight = window.innerHeight || document.documentElement.clientHeight
  const viewportWidth = window.innerWidth || document.documentElement.clientWidth

  if (viewportHeight <= 0 || viewportWidth <= 0) return null

  const rootRect = root.getBoundingClientRect?.()
  const rootCenterX = rootRect ? rootRect.left + rootRect.width / 2 : viewportWidth / 2
  const sampleX = Math.max(0, Math.min(viewportWidth - 1, rootCenterX))
  const sampleYs = [
    Math.min(96, viewportHeight - 1),
    Math.floor(viewportHeight * 0.25),
    Math.floor(viewportHeight * 0.5),
    Math.floor(viewportHeight * 0.75)
  ].filter((y) => y >= 0 && y < viewportHeight)

  for (const sampleY of sampleYs) {
    const target = document.elementFromPoint(sampleX, sampleY)
    const card = target?.closest?.('[data-post-id]')
    if (card && root.contains(card)) {
      const anchor = postAnchorFromElement(card)
      if (anchor) return anchor
    }
  }

  const lowerBound = -Math.max(viewportHeight * 1.5, 1200)
  const belowBreak = viewportHeight + Math.max(viewportHeight, 1200)
  const postCards = root.querySelectorAll('[data-post-id]')

  for (const card of postCards) {
    const rect = card.getBoundingClientRect()
    if (rect.bottom <= lowerBound) continue
    if (rect.top >= belowBreak) break
    if (rect.bottom <= 0 || rect.top >= viewportHeight) continue

    const anchor = postAnchorFromElement(card)
    if (anchor) return anchor
  }

  return null
}

// General UI-related LiveView hooks
/**
 * UI Hooks
 * General-purpose UI hooks for common interactions like copying to clipboard,
 * focus management, flash messages, scrolling, and visual effects.
 */

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
    return findVisiblePostAnchor(this.el)
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
