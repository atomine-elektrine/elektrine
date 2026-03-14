/**
 * Timeline Hooks
 * Hooks for timeline/feed interactions including post clicks, infinite scroll,
 * dwell time tracking, hover cards, and image modals.
 */

// Dwell time tracking constants
const SCROLL_PAST_THRESHOLD_MS = 500
const MIN_DWELL_TIME_MS = 1000
const BATCH_INTERVAL_MS = 5000

// Global state for batching dwell time updates
let dwellTimeBuffer = new Map()
let batchTimeout = null

const REMOTE_FOLLOW_BUTTON_CLASSES = [
  'btn-ghost',
  'btn-secondary',
  'btn-primary',
  'btn-disabled',
  'phx-click-loading:bg-base-200',
  'phx-click-loading:text-base-content'
]

const REMOTE_FOLLOW_BUTTON_VARIANTS = {
  timeline: {
    following: { add: ['btn-ghost'], disabled: false },
    pending: { add: ['btn-ghost'], disabled: false },
    none: {
      add: ['btn-secondary', 'phx-click-loading:bg-base-200', 'phx-click-loading:text-base-content'],
      disabled: false
    }
  },
  'hover-card': {
    following: { add: ['btn-ghost'], disabled: false },
    pending: { add: ['btn-disabled'], disabled: true },
    none: {
      add: ['btn-primary', 'phx-click-loading:bg-base-200', 'phx-click-loading:text-base-content'],
      disabled: false
    }
  }
}

/**
 * Post Click Hook
 * Handles navigation when clicking on posts and tracks dwell time
 */
export const PostClick = {
  mounted() {
    this.handleClick = (e) => {
      if (e.target.closest('a, button, label, .dropdown, details')) return

      const closestPhxClick = e.target.closest('[phx-click]')
      if (closestPhxClick && closestPhxClick !== this.el) return

      const selection = window.getSelection()
      if (selection && selection.toString().length > 0) return

      const { clickEvent, url, id, community, slug } = this.el.dataset

      if (clickEvent === "open_external_link" && url) {
        this.pushEvent(clickEvent, { url })
      } else if (clickEvent === "navigate_to_post" && id) {
        this.pushEvent(clickEvent, { id })
      } else if (clickEvent === "navigate_to_gallery_post" && id) {
        this.pushEvent(clickEvent, { id, url: url || "" })
      } else if (clickEvent === "navigate_to_embedded_post" && (id || url)) {
        if (url) {
          this.pushEvent(clickEvent, { url })
        } else {
          this.pushEvent(clickEvent, { id })
        }
      } else if (clickEvent === "navigate_to_remote_post" && (id || url)) {
        this.pushEvent(clickEvent, { id, url: url || "" })
      } else if (clickEvent === "navigate_to_discussion" && community && slug) {
        this.pushEvent(clickEvent, { community, slug })
      }
    }

    this.el.addEventListener('click', this.handleClick)

    // Dwell time tracking
    this.postId = this.el.dataset.postId
    if (!this.postId) return

    this.source = this.el.dataset.source || 'timeline'
    this.startTime = null
    this.totalDwellTime = 0
    this.maxScrollDepth = 0
    this.isVisible = false
    this.wasExpanded = false

    this.observer = new IntersectionObserver(
      (entries) => this.handleIntersection(entries),
      { root: null, rootMargin: '0px', threshold: [0, 0.25, 0.5, 0.75, 1.0] }
    )
    this.observer.observe(this.el)

    this.handleVisibilityChange = () => {
      if (document.hidden && this.isVisible) this.pauseTracking()
      else if (!document.hidden && this.isVisible) this.resumeTracking()
    }
    document.addEventListener('visibilitychange', this.handleVisibilityChange)
  },

  destroyed() {
    if (this.handleClick) this.el.removeEventListener('click', this.handleClick)
    if (this.observer) this.observer.disconnect()
    if (this.handleVisibilityChange) {
      document.removeEventListener('visibilitychange', this.handleVisibilityChange)
    }
    if (this.postId) {
      this.pauseTracking()
      this.sendDwellData()
    }
  },

  handleIntersection(entries) {
    const entry = entries[0]
    if (entry.isIntersecting) {
      if (!this.isVisible) {
        this.isVisible = true
        this.resumeTracking()
      }
      if (entry.intersectionRatio > this.maxScrollDepth) {
        this.maxScrollDepth = entry.intersectionRatio
      }
    } else if (this.isVisible) {
      this.isVisible = false
      this.pauseTracking()
      if (this.totalDwellTime < SCROLL_PAST_THRESHOLD_MS && this.totalDwellTime > 0) {
        this.recordScrollPast()
      }
    }
  },

  resumeTracking() {
    if (!this.startTime) this.startTime = Date.now()
  },

  pauseTracking() {
    if (this.startTime) {
      this.totalDwellTime += Date.now() - this.startTime
      this.startTime = null
      this.bufferDwellData()
    }
  },

  bufferDwellData() {
    if (this.totalDwellTime >= MIN_DWELL_TIME_MS && this.postId) {
      dwellTimeBuffer.set(this.postId, {
        post_id: this.postId,
        dwell_time_ms: this.totalDwellTime,
        scroll_depth: this.maxScrollDepth,
        expanded: this.wasExpanded,
        source: this.source
      })
      this.scheduleBatchSend()
    }
  },

  scheduleBatchSend() {
    if (!batchTimeout) {
      batchTimeout = setTimeout(() => {
        this.sendBatch()
        batchTimeout = null
      }, BATCH_INTERVAL_MS)
    }
  },

  sendBatch() {
    if (dwellTimeBuffer.size === 0) return
    const data = Array.from(dwellTimeBuffer.values())
    dwellTimeBuffer.clear()
    try { this.pushEvent('record_dwell_times', { views: data }) } catch (e) {}
  },

  sendDwellData() {
    if (this.totalDwellTime >= MIN_DWELL_TIME_MS && this.postId) {
      try {
        this.pushEvent('record_dwell_time', {
          post_id: this.postId,
          dwell_time_ms: this.totalDwellTime,
          scroll_depth: this.maxScrollDepth,
          expanded: this.wasExpanded,
          source: this.source
        })
      } catch (e) {}
    }
  },

  recordScrollPast() {
    if (this.postId) {
      try {
        this.pushEvent('record_dismissal', {
          post_id: this.postId,
          type: 'scrolled_past',
          dwell_time_ms: this.totalDwellTime
        })
      } catch (e) {}
    }
  }
}

/**
 * Remote Follow Button Hook
 * Updates follow buttons in streamed cards without re-inserting the entire post.
 */
export const RemoteFollowButton = {
  mounted() {
    this.remoteActorId = String(this.el.dataset.remoteActorId || '')

    this.handleEvent('remote_follow_state_changed', ({ remote_actor_id, state }) => {
      if (String(remote_actor_id) !== this.remoteActorId) return

      this.el.dataset.followState = state
      this.syncState()
    })

    this.syncState()
  },

  updated() {
    this.syncState()
  },

  syncState() {
    const state = this.el.dataset.followState || 'none'
    const variantName = this.el.dataset.followVariant || 'timeline'
    const variant =
      REMOTE_FOLLOW_BUTTON_VARIANTS[variantName] || REMOTE_FOLLOW_BUTTON_VARIANTS.timeline
    const config = variant[state] || variant.none

    this.el.classList.remove(...REMOTE_FOLLOW_BUTTON_CLASSES)
    this.el.classList.add(...config.add)
    this.el.disabled = !!config.disabled

    this.el.querySelectorAll('[data-follow-display]').forEach((display) => {
      display.classList.toggle('hidden', display.dataset.followDisplay !== state)
    })
  }
}

/**
 * Infinite Scroll Hook
 * Automatically loads more content when user scrolls near the bottom
 */
export const InfiniteScroll = {
  mounted() {
    this.pending = false
    this.disabled =
      this.el.dataset.noMore === 'true' || this.el.dataset.loadingMore === 'true'
    this.offset = parseInt(this.el.dataset.offset, 10) || 300
    this.lastRequestTime = 0
    this.minRequestInterval = 500
    this.pendingResetTimeout = null
    this.checkRAF = null
    this.sentinel = null
    this.observer = null
    this.loadingMore = this.el.dataset.loadingMore === 'true'
    this.prePatchLoadingMore = false
    this.prePatchScrollY = null
    this.prePatchAnchor = null
    this.loadCycleStartY = null

    this.setupObserver()
    this.requestCheck()
  },

  beforeUpdate() {
    this.prePatchLoadingMore = this.loadingMore

    if (this.prePatchLoadingMore) {
      this.prePatchScrollY = window.scrollY
      this.prePatchAnchor = this.findVisiblePostAnchor()
    } else {
      this.prePatchScrollY = null
      this.prePatchAnchor = null
    }
  },

  setupObserver() {
    if (this.observer) {
      this.observer.disconnect()
      this.observer = null
    }

    this.sentinel = this.el.querySelector('[data-infinite-scroll-sentinel]')
    if (!this.sentinel) return

    this.observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0]
        if (entry?.isIntersecting) this.loadMore()
      },
      {
        root: null,
        rootMargin: `0px 0px ${this.offset}px 0px`,
        threshold: 0
      }
    )

    this.observer.observe(this.sentinel)
  },

  requestCheck() {
    if (this.checkRAF) cancelAnimationFrame(this.checkRAF)
    this.checkRAF = requestAnimationFrame(() => {
      this.checkRAF = null
      this.checkViewportDistance()
    })
  },

  checkViewportDistance() {
    if (!this.sentinel) return

    const sentinelTop = this.sentinel.getBoundingClientRect().top
    const threshold = (window.innerHeight || document.documentElement.clientHeight) + this.offset

    if (sentinelTop <= threshold) this.loadMore()
  },

  loadMore() {
    if (this.pending || this.disabled) return

    const now = Date.now()
    if (now - this.lastRequestTime < this.minRequestInterval) return

    this.pending = true
    this.lastRequestTime = now
    this.loadCycleStartY = window.scrollY
    if (this.observer) this.observer.disconnect()

    try {
      this.pushEvent("load-more", {})
    } catch (e) {
      this.pending = false
      return
    }

    if (this.pendingResetTimeout) clearTimeout(this.pendingResetTimeout)
    this.pendingResetTimeout = setTimeout(() => {
      this.pending = false
      this.pendingResetTimeout = null
    }, 3000)
  },

  updated() {
    this.loadingMore = this.el.dataset.loadingMore === 'true'

    if (this.prePatchLoadingMore && !this.loadingMore) {
      let restored = false

      if (this.prePatchAnchor?.postId) {
        const anchor = this.findPostById(this.prePatchAnchor.postId)

        if (anchor) {
          const newTop = anchor.getBoundingClientRect().top
          const delta = newTop - this.prePatchAnchor.top

          if (delta !== 0) window.scrollBy(0, delta)
          restored = true
        }
      }

      if (!restored && Number.isFinite(this.prePatchScrollY)) {
        window.scrollTo({ top: this.prePatchScrollY, behavior: "auto" })
      } else if (!restored && Number.isFinite(this.loadCycleStartY)) {
        window.scrollTo({ top: this.loadCycleStartY, behavior: "auto" })
      }
    }

    this.prePatchLoadingMore = false
    this.prePatchScrollY = null
    this.prePatchAnchor = null
    if (!this.loadingMore) this.loadCycleStartY = null
    this.pending = false
    this.disabled =
      this.el.dataset.noMore === 'true' || this.el.dataset.loadingMore === 'true'
    this.setupObserver()
    this.requestCheck()
  },

  findVisiblePostAnchor() {
    const postCards = this.el.querySelectorAll('[data-post-id]')
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight

    for (const card of postCards) {
      const rect = card.getBoundingClientRect()
      if (rect.bottom <= 0 || rect.top >= viewportHeight) continue

      const postId = card.dataset.postId
      if (!postId) continue

      return { postId, top: rect.top }
    }

    return null
  },

  findPostById(postId) {
    if (!postId) return null

    const escapedPostId = typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(postId) : postId
    return this.el.querySelector(`[data-post-id="${escapedPostId}"]`)
  },

  destroyed() {
    if (this.pendingResetTimeout) clearTimeout(this.pendingResetTimeout)
    if (this.checkRAF) cancelAnimationFrame(this.checkRAF)
    if (this.observer) this.observer.disconnect()
  }
}

/**
 * User Hover Card Hook
 * Shows a profile preview card when hovering over usernames/avatars
 */
export const UserHoverCard = {
  mounted() {
    this.card = this.el.querySelector('[data-hover-card]')
    if (!this.card) return

    this.showTimeout = null
    this.hideTimeout = null
    this.isCardHovered = false

    this.handleMouseEnter = () => {
      clearTimeout(this.hideTimeout)
      this.showTimeout = setTimeout(() => this.showCard(), 400)
    }

    this.handleMouseLeave = () => {
      clearTimeout(this.showTimeout)
      this.hideTimeout = setTimeout(() => {
        if (!this.isCardHovered) this.hideCard()
      }, 200)
    }

    this.handleCardEnter = () => {
      this.isCardHovered = true
      clearTimeout(this.hideTimeout)
    }

    this.handleCardLeave = () => {
      this.isCardHovered = false
      this.hideTimeout = setTimeout(() => this.hideCard(), 200)
    }

    const trigger = this.el.querySelector('[data-hover-trigger]')
    if (trigger) {
      trigger.addEventListener('mouseenter', this.handleMouseEnter)
      trigger.addEventListener('mouseleave', this.handleMouseLeave)
    } else {
      this.el.addEventListener('mouseenter', this.handleMouseEnter)
      this.el.addEventListener('mouseleave', this.handleMouseLeave)
    }

    this.card.addEventListener('mouseenter', this.handleCardEnter)
    this.card.addEventListener('mouseleave', this.handleCardLeave)
  },

  showCard() {
    if (this.card) {
      this.card.classList.remove('opacity-0', 'invisible', 'scale-95')
      this.card.classList.add('opacity-100', 'visible', 'scale-100')
    }
  },

  hideCard() {
    if (this.card) {
      this.card.classList.remove('opacity-100', 'visible', 'scale-100')
      this.card.classList.add('opacity-0', 'invisible', 'scale-95')
    }
  },

  destroyed() {
    clearTimeout(this.showTimeout)
    clearTimeout(this.hideTimeout)
  }
}

/**
 * Image Modal Hook
 * Adds keyboard and scroll navigation support for image galleries
 */
export const ImageModal = {
  mounted() {
    this.handleKeyDown = (e) => {
      if (e.key === 'Escape') this.pushEvent('close_image_modal', {})
      else if (e.key === 'ArrowLeft') this.pushEvent('prev_image', {})
      else if (e.key === 'ArrowRight') this.pushEvent('next_image', {})
      else if (e.key === 'ArrowUp') { e.preventDefault(); this.pushEvent('prev_media_post', {}) }
      else if (e.key === 'ArrowDown') { e.preventDefault(); this.pushEvent('next_media_post', {}) }
    }

    this.lastScrollTime = 0
    this.scrollThrottle = 200

    this.handleWheel = (e) => {
      if (!this.el.contains(e.target)) return
      const now = Date.now()
      if (now - this.lastScrollTime < this.scrollThrottle) return
      if (Math.abs(e.deltaY) < 10) return

      this.lastScrollTime = now
      e.preventDefault()
      e.stopPropagation()

      if (e.deltaY < 0) this.pushEvent('prev_image', {})
      else this.pushEvent('next_image', {})
    }

    document.addEventListener('keydown', this.handleKeyDown)
    document.addEventListener('wheel', this.handleWheel, { passive: false })
  },

  destroyed() {
    document.removeEventListener('keydown', this.handleKeyDown)
    document.removeEventListener('wheel', this.handleWheel)
  }
}

/**
 * Dwell Time Tracker Hook
 * Standalone tracker for posts (alternative to PostClick)
 */
export const DwellTimeTracker = {
  mounted() {
    this.postId = this.el.dataset.postId
    this.source = this.el.dataset.source || 'feed'
    this.startTime = null
    this.totalDwellTime = 0
    this.maxScrollDepth = 0
    this.isVisible = false
    this.wasExpanded = false

    this.observer = new IntersectionObserver(
      (entries) => this.handleIntersection(entries),
      { root: null, rootMargin: '0px', threshold: [0, 0.25, 0.5, 0.75, 1.0] }
    )
    this.observer.observe(this.el)

    this.el.addEventListener('click', (e) => this.handleClick(e))

    this.handleVisibilityChange = () => {
      if (document.hidden && this.isVisible) this.pauseTracking()
      else if (!document.hidden && this.isVisible) this.resumeTracking()
    }
    document.addEventListener('visibilitychange', this.handleVisibilityChange)
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    if (this.handleVisibilityChange) {
      document.removeEventListener('visibilitychange', this.handleVisibilityChange)
    }
    if (this.postId) {
      this.pauseTracking()
      this.sendDwellData()
    }
  },

  handleIntersection(entries) {
    const entry = entries[0]
    if (entry.isIntersecting) {
      if (!this.isVisible) {
        this.isVisible = true
        this.resumeTracking()
      }
      if (entry.intersectionRatio > this.maxScrollDepth) {
        this.maxScrollDepth = entry.intersectionRatio
      }
    } else if (this.isVisible) {
      this.isVisible = false
      this.pauseTracking()
      if (this.totalDwellTime < SCROLL_PAST_THRESHOLD_MS && this.totalDwellTime > 0) {
        this.recordScrollPast()
      }
    }
  },

  handleClick(e) {
    const isExpandClick = e.target.closest('[data-expand]') ||
                          e.target.closest('.read-more') ||
                          e.target.closest('.expand-post')
    if (isExpandClick) this.wasExpanded = true
  },

  resumeTracking() {
    if (!this.startTime) this.startTime = Date.now()
  },

  pauseTracking() {
    if (this.startTime) {
      this.totalDwellTime += Date.now() - this.startTime
      this.startTime = null
      this.bufferDwellData()
    }
  },

  bufferDwellData() {
    if (this.totalDwellTime >= MIN_DWELL_TIME_MS) {
      dwellTimeBuffer.set(this.postId, {
        post_id: this.postId,
        dwell_time_ms: this.totalDwellTime,
        scroll_depth: this.maxScrollDepth,
        expanded: this.wasExpanded,
        source: this.source
      })
      this.scheduleBatchSend()
    }
  },

  scheduleBatchSend() {
    if (!batchTimeout) {
      batchTimeout = setTimeout(() => {
        this.sendBatch()
        batchTimeout = null
      }, BATCH_INTERVAL_MS)
    }
  },

  sendBatch() {
    if (dwellTimeBuffer.size === 0) return
    const data = Array.from(dwellTimeBuffer.values())
    dwellTimeBuffer.clear()
    try { this.pushEvent('record_dwell_times', { views: data }) } catch (e) {}
  },

  sendDwellData() {
    if (this.totalDwellTime >= MIN_DWELL_TIME_MS) {
      try {
        this.pushEvent('record_dwell_time', {
          post_id: this.postId,
          dwell_time_ms: this.totalDwellTime,
          scroll_depth: this.maxScrollDepth,
          expanded: this.wasExpanded,
          source: this.source
        })
      } catch (e) {}
    }
  },

  recordScrollPast() {
    try {
      this.pushEvent('record_dismissal', {
        post_id: this.postId,
        type: 'scrolled_past',
        dwell_time_ms: this.totalDwellTime
      })
    } catch (e) {}
  }
}

/**
 * Not Interested Button Hook
 * Handles explicit "not interested" actions from users
 */
export const NotInterestedButton = {
  mounted() {
    this.el.addEventListener('click', () => {
      const postId = this.el.dataset.postId
      this.pushEvent('record_dismissal', { post_id: postId, type: 'not_interested' })

      const postElement = document.getElementById(`post-${postId}`)
      if (postElement) {
        postElement.style.opacity = '0'
        postElement.style.transition = 'opacity 0.3s'
        setTimeout(() => { postElement.style.display = 'none' }, 300)
      }
    })
  }
}

/**
 * Hide Post Button Hook
 * Handles explicit "hide" actions from users
 */
export const HidePostButton = {
  mounted() {
    this.el.addEventListener('click', () => {
      const postId = this.el.dataset.postId
      this.pushEvent('record_dismissal', { post_id: postId, type: 'hidden' })

      const postElement = document.getElementById(`post-${postId}`)
      if (postElement) {
        postElement.style.opacity = '0'
        postElement.style.transition = 'opacity 0.3s'
        setTimeout(() => { postElement.style.display = 'none' }, 300)
      }
    })
  }
}

/**
 * Session Context Tracker
 * Tracks session-level engagement for real-time feed adaptation
 */
export const SessionContextTracker = {
  mounted() {
    this.sessionData = {
      liked_hashtags: [],
      liked_creators: [],
      liked_local_creators: [],
      liked_remote_creators: [],
      viewed_posts: [],
      total_interactions: 0,
      total_views: 0
    }

    this.handleEvent('post_liked', (data) => {
      this.sessionData.total_interactions++
      if (data.hashtags) {
        this.sessionData.liked_hashtags.push(...data.hashtags)
        this.sessionData.liked_hashtags = [...new Set(this.sessionData.liked_hashtags)]
      }

      const localCreatorId =
        data.sender_id || (data.creator_type === 'local' ? data.creator_id : null)
      const remoteCreatorId =
        data.remote_actor_id || (data.creator_type === 'remote' ? data.creator_id : null)

      if (localCreatorId && !this.sessionData.liked_local_creators.includes(localCreatorId)) {
        this.sessionData.liked_local_creators.push(localCreatorId)
      }
      if (remoteCreatorId && !this.sessionData.liked_remote_creators.includes(remoteCreatorId)) {
        this.sessionData.liked_remote_creators.push(remoteCreatorId)
      }

      // Legacy field for LiveViews that still read liked_creators.
      this.sessionData.liked_creators = this.sessionData.liked_local_creators
      this.updateEngagementRate()
    })

    this.handleEvent('post_viewed', (data) => {
      this.sessionData.total_views++
      if (data.post_id && !this.sessionData.viewed_posts.includes(data.post_id)) {
        this.sessionData.viewed_posts.push(data.post_id)
      }
      this.updateEngagementRate()
    })
  },

  updateEngagementRate() {
    const engagementRate = this.sessionData.total_views > 0
      ? this.sessionData.total_interactions / this.sessionData.total_views
      : 0

    this.pushEvent('update_session_context', {
      liked_hashtags: this.sessionData.liked_hashtags.slice(-20),
      liked_creators: this.sessionData.liked_creators.slice(-10),
      liked_local_creators: this.sessionData.liked_local_creators.slice(-10),
      liked_remote_creators: this.sessionData.liked_remote_creators.slice(-10),
      viewed_posts: this.sessionData.viewed_posts.slice(-50),
      engagement_rate: engagementRate
    })
  }
}
