/**
 * Timeline Hooks
 * Hooks for timeline/feed interactions including post clicks, infinite scroll,
 * dwell time tracking, hover cards, and image modals.
 */

// Dwell time tracking constants
const SCROLL_PAST_THRESHOLD_MS = 500;
const MIN_DWELL_TIME_MS = 1000;
const BATCH_INTERVAL_MS = 5000;

function currentScrollY() {
  return Math.max(
    window.scrollY || 0,
    window.pageYOffset || 0,
    document.documentElement?.scrollTop || 0,
    document.body?.scrollTop || 0,
  );
}

// Global state for batching dwell time updates
let dwellTimeBuffer = new Map();
let batchTimeout = null;
let navigationFlushInProgress = false;
const activeDwellTrackers = new Set();
let queuedPostsScrollSnapshot = null;
let infiniteScrollRestoreSnapshot = null;
let streamRestoreSnapshot = null;
const TIMELINE_LAST_VISIT_KEY = "timeline-last-visit-at";
const COMMUNITY_LAST_VISIT_KEY = "community-last-visit-at";
const COMMUNITY_PREFERENCES_KEY = "community-view-preferences";

function findVisiblePostAnchor(root = document) {
  const postCards = root.querySelectorAll("[data-post-id]");
  const viewportHeight =
    window.innerHeight || document.documentElement.clientHeight;

  for (const card of postCards) {
    const rect = card.getBoundingClientRect();
    if (rect.bottom <= 0 || rect.top >= viewportHeight) continue;

    const postId = card.dataset.postId;
    if (!postId) continue;

    return { postId, top: rect.top };
  }

  return null;
}

function findPostById(root, postId) {
  if (!postId) return null;

  const escapedPostId =
    typeof CSS !== "undefined" && CSS.escape ? CSS.escape(postId) : postId;
  return root.querySelector(`[data-post-id="${escapedPostId}"]`);
}

function restoreQueuedPostsScroll(root = document) {
  if (!queuedPostsScrollSnapshot) return;

  const { anchor, scrollY } = queuedPostsScrollSnapshot;

  if (anchor?.postId) {
    const anchorEl = findPostById(root, anchor.postId);

    if (anchorEl) {
      const delta = anchorEl.getBoundingClientRect().top - anchor.top;
      if (delta !== 0) window.scrollBy(0, delta);
      return;
    }
  }

  if (Number.isFinite(scrollY))
    window.scrollTo({ top: scrollY, behavior: "auto" });
}

if (typeof window !== "undefined") {
  window.addEventListener("phx:page-loading-start", () => {
    if (navigationFlushInProgress || activeDwellTrackers.size === 0) return;

    const firstTracker = activeDwellTrackers.values().next().value;
    if (firstTracker) void flushDwellBatchBeforeNavigation(firstTracker);
  });

  window.addEventListener("phx:page-loading-stop", () => {
    navigationFlushInProgress = false;
  });
}

function buildDwellPayload(state, dwellTimeMs) {
  if (!state.postId || dwellTimeMs < MIN_DWELL_TIME_MS) return null;

  return {
    post_id: state.postId,
    dwell_time_ms: dwellTimeMs,
    scroll_depth: state.maxScrollDepth,
    expanded: state.wasExpanded,
    source: state.source,
  };
}

function mergeDwellPayloads(existing, incoming) {
  if (!existing) return incoming;
  if (!incoming) return existing;

  return {
    post_id: incoming.post_id || existing.post_id,
    dwell_time_ms:
      (existing.dwell_time_ms || 0) + (incoming.dwell_time_ms || 0),
    scroll_depth: Math.max(
      existing.scroll_depth || 0,
      incoming.scroll_depth || 0,
    ),
    expanded: Boolean(existing.expanded || incoming.expanded),
    source: incoming.source || existing.source,
  };
}

function queueDwellPayload(postId, payload) {
  if (!postId || !payload) return;
  dwellTimeBuffer.set(
    postId,
    mergeDwellPayloads(dwellTimeBuffer.get(postId), payload),
  );
}

function takeQueuedDwellPayload(postId) {
  if (!postId) return null;

  const payload = dwellTimeBuffer.get(postId) || null;
  if (payload) dwellTimeBuffer.delete(postId);
  return payload;
}

function registerDwellTracker(hook) {
  if (hook?.postId) activeDwellTrackers.add(hook);
}

function unregisterDwellTracker(hook) {
  activeDwellTrackers.delete(hook);
}

async function flushDwellBatchBeforeNavigation(hook) {
  navigationFlushInProgress = true;

  activeDwellTrackers.forEach((tracker) => {
    tracker.pauseTracking?.();
  });

  if (batchTimeout) {
    clearTimeout(batchTimeout);
    batchTimeout = null;
  }

  if (dwellTimeBuffer.size === 0) return;

  const data = Array.from(dwellTimeBuffer.values());
  dwellTimeBuffer.clear();

  await Promise.race([
    safePushEvent(hook, "record_dwell_times", { views: data }),
    new Promise((resolve) => setTimeout(resolve, 150)),
  ]);
}

function isHookConnected(hook) {
  return Boolean(hook?.liveSocket?.isConnected?.() && hook?.el?.isConnected);
}

function safePushEvent(hook, event, payload) {
  if (!isHookConnected(hook)) return Promise.resolve(null);
  return Promise.resolve(hook.pushEvent(event, payload)).catch(() => null);
}

function firstElementInEventPath(event) {
  if (typeof event?.composedPath !== "function") return null;

  return event
    .composedPath()
    .find((node) => node instanceof Element) || null;
}

function eventPathContainsSelector(event, selector) {
  if (typeof event?.composedPath !== "function") return false;

  return event.composedPath().some((node) => {
    return node instanceof Element && node.matches(selector);
  });
}

const REMOTE_FOLLOW_BUTTON_CLASSES = [
  "btn-ghost",
  "btn-secondary",
  "btn-primary",
  "btn-disabled",
  "phx-click-loading:bg-base-200",
  "phx-click-loading:text-base-content",
];

const REMOTE_FOLLOW_BUTTON_VARIANTS = {
  timeline: {
    following: { add: ["btn-ghost"], disabled: false },
    pending: { add: ["btn-ghost"], disabled: false },
    none: {
      add: [
        "btn-secondary",
        "phx-click-loading:bg-base-200",
        "phx-click-loading:text-base-content",
      ],
      disabled: false,
    },
  },
  "hover-card": {
    following: { add: ["btn-ghost"], disabled: false },
    pending: { add: ["btn-disabled"], disabled: true },
    none: {
      add: [
        "btn-primary",
        "phx-click-loading:bg-base-200",
        "phx-click-loading:text-base-content",
      ],
      disabled: false,
    },
  },
};

/**
 * Post Click Hook
 * Handles navigation when clicking on posts and tracks dwell time
 */
export const PostClick = {
  mounted() {
    this.suppressNextClickFromPickerDismiss = false;

    this.handlePointerDown = (e) => {
      const openReactionPicker = this.el.querySelector(
        "[data-reaction-picker-root]:focus-within",
      );

      if (openReactionPicker && !e.target.closest("[data-reaction-picker-root]")) {
        this.suppressNextClickFromPickerDismiss = true;
      }
    };

    this.handleClick = async (e) => {
      const target =
        e.target instanceof Element
          ? e.target
          : e.target?.parentElement || firstElementInEventPath(e);

      if (this.suppressNextClickFromPickerDismiss) {
        this.suppressNextClickFromPickerDismiss = false;
        return;
      }

      if (!target) return;

      if (
        eventPathContainsSelector(
          e,
          "a, button, input, textarea, select, option, label, form, .dropdown, details",
        ) ||
        target.closest(
          "a, button, input, textarea, select, option, label, form, .dropdown, details",
        )
      )
        return;

      const nestedPostClick = target.closest('[phx-hook="PostClick"]');
      if (nestedPostClick && nestedPostClick !== this.el) return;

      const closestPhxClick = target.closest("[phx-click]");
      if (closestPhxClick && closestPhxClick !== this.el) return;

      const selection = window.getSelection();
      if (selection && selection.toString().length > 0) return;

      const navLink = this.el.querySelector("[data-post-nav-link]");

      if (navLink) {
        await flushDwellBatchBeforeNavigation(this);

        navLink.dispatchEvent(
          new MouseEvent("click", {
            bubbles: true,
            cancelable: true,
            metaKey: e.metaKey,
            ctrlKey: e.ctrlKey,
            shiftKey: e.shiftKey,
            altKey: e.altKey,
            button: e.button,
          }),
        );

        return;
      }
    };

    this.el.addEventListener("pointerdown", this.handlePointerDown);
    this.el.addEventListener("click", this.handleClick);

    // Dwell time tracking
    this.postId = this.el.dataset.postId;
    if (!this.postId) return;

    this.source = this.el.dataset.source || "timeline";
    this.startTime = null;
    this.totalDwellTime = 0;
    this.lastReportedDwellTime = 0;
    this.maxScrollDepth = 0;
    this.isVisible = false;
    this.wasExpanded = false;

    this.observer = new IntersectionObserver(
      (entries) => this.handleIntersection(entries),
      { root: null, rootMargin: "0px", threshold: [0, 0.25, 0.5, 0.75, 1.0] },
    );
    this.observer.observe(this.el);
    registerDwellTracker(this);

    this.handleVisibilityChange = () => {
      if (document.hidden && this.isVisible) this.pauseTracking();
      else if (!document.hidden && this.isVisible) this.resumeTracking();
    };
    document.addEventListener("visibilitychange", this.handleVisibilityChange);
  },

  destroyed() {
    if (this.handlePointerDown)
      this.el.removeEventListener("pointerdown", this.handlePointerDown);
    if (this.handleClick)
      this.el.removeEventListener("click", this.handleClick);
    if (this.observer) this.observer.disconnect();
    if (this.handleVisibilityChange) {
      document.removeEventListener(
        "visibilitychange",
        this.handleVisibilityChange,
      );
    }
    unregisterDwellTracker(this);
    if (this.postId && !navigationFlushInProgress) {
      this.pauseTracking();
      this.sendDwellData();
    }
  },

  handleIntersection(entries) {
    const entry = entries[0];
    if (entry.isIntersecting) {
      if (!this.isVisible) {
        this.isVisible = true;
        this.resumeTracking();
      }
      if (entry.intersectionRatio > this.maxScrollDepth) {
        this.maxScrollDepth = entry.intersectionRatio;
      }
    } else if (this.isVisible) {
      this.isVisible = false;
      this.pauseTracking();
      if (
        this.totalDwellTime < SCROLL_PAST_THRESHOLD_MS &&
        this.totalDwellTime > 0
      ) {
        this.recordScrollPast();
      }
    }
  },

  resumeTracking() {
    if (!this.startTime) this.startTime = Date.now();
  },

  pauseTracking() {
    if (this.startTime) {
      this.totalDwellTime += Date.now() - this.startTime;
      this.startTime = null;
      this.bufferDwellData();
    }
  },

  bufferDwellData() {
    const pendingDwellTime = this.totalDwellTime - this.lastReportedDwellTime;
    const payload = buildDwellPayload(this, pendingDwellTime);

    if (!payload) return;

    queueDwellPayload(this.postId, payload);
    this.lastReportedDwellTime = this.totalDwellTime;
    this.scheduleBatchSend();
  },

  scheduleBatchSend() {
    if (!batchTimeout) {
      batchTimeout = setTimeout(() => {
        this.sendBatch();
        batchTimeout = null;
      }, BATCH_INTERVAL_MS);
    }
  },

  sendBatch() {
    if (dwellTimeBuffer.size === 0) return;
    const data = Array.from(dwellTimeBuffer.values());
    dwellTimeBuffer.clear();
    void safePushEvent(this, "record_dwell_times", { views: data });
  },

  sendDwellData() {
    const queuedPayload = takeQueuedDwellPayload(this.postId);
    const pendingDwellTime = this.totalDwellTime - this.lastReportedDwellTime;
    const directPayload = buildDwellPayload(this, pendingDwellTime);
    const payload = mergeDwellPayloads(queuedPayload, directPayload);

    if (!payload) return;

    if (directPayload) this.lastReportedDwellTime = this.totalDwellTime;

    void safePushEvent(this, "record_dwell_time", payload);
  },

  recordScrollPast() {
    if (this.postId) {
      void safePushEvent(this, "record_dismissal", {
        post_id: this.postId,
        type: "scrolled_past",
        dwell_time_ms: this.totalDwellTime,
      });
    }
  },
};

/**
 * Remote Follow Button Hook
 * Updates follow buttons in streamed cards without re-inserting the entire post.
 */
export const RemoteFollowButton = {
  mounted() {
    this.remoteActorId = String(this.el.dataset.remoteActorId || "");

    this.handleEvent(
      "remote_follow_state_changed",
      ({ remote_actor_id, state }) => {
        if (String(remote_actor_id) !== this.remoteActorId) return;

        this.el.dataset.followState = state;
        this.syncState();
      },
    );

    this.syncState();
  },

  updated() {
    this.syncState();
  },

  syncState() {
    const state = this.el.dataset.followState || "none";
    const variantName = this.el.dataset.followVariant || "timeline";
    const variant =
      REMOTE_FOLLOW_BUTTON_VARIANTS[variantName] ||
      REMOTE_FOLLOW_BUTTON_VARIANTS.timeline;
    const config = variant[state] || variant.none;

    this.el.classList.remove(...REMOTE_FOLLOW_BUTTON_CLASSES);
    this.el.classList.add(...config.add);
    this.el.disabled = !!config.disabled;

    this.el.querySelectorAll("[data-follow-display]").forEach((display) => {
      display.classList.toggle(
        "hidden",
        display.dataset.followDisplay !== state,
      );
    });
  },
};

/**
 * Infinite Scroll Hook
 * Automatically loads more content when user scrolls near the bottom
 */
export const InfiniteScroll = {
  mounted() {
    this.pending = false;
    this.disabled =
      this.el.dataset.noMore === "true" ||
      this.el.dataset.loadingMore === "true";
    this.offset = parseInt(this.el.dataset.offset, 10) || 300;
    this.lastRequestTime = 0;
    this.minRequestInterval = 500;
    this.pendingResetTimeout = null;
    this.checkRAF = null;
    this.restoreRAF = null;
    this.restoreTimeouts = [];
    this.prePatchMode = null;
    this.sentinel = null;
    this.observer = null;
    this.loadingMore = this.el.dataset.loadingMore === "true";
    this.prePatchShouldPreserve = false;
    this.prePatchScrollY = null;
    this.prePatchAnchor = null;
    this.loadCycleStartY = null;
    this.lastKnownScrollY = currentScrollY();

    this.restoreFromGlobalSnapshotIfNeeded(true);

    this.setupObserver();
    this.requestCheck();

    this.handleScroll = () => {
      this.lastKnownScrollY = currentScrollY();
      this.cancelSettledRestore();
      if (!this.pending && !this.disabled) this.requestCheck();
    };
    window.addEventListener("scroll", this.handleScroll, { passive: true });
  },

  beforeUpdate() {
    this.prePatchMode = this.pending || this.loadingMore ? "load-cycle" : null;
    this.prePatchShouldPreserve = this.prePatchMode !== null;

    if (this.prePatchShouldPreserve) {
      this.prePatchScrollY = this.getStableScrollY();
      this.prePatchAnchor = this.findVisiblePostAnchor();
      this.storeGlobalRestoreSnapshot(this.prePatchAnchor, this.prePatchScrollY);
    } else {
      this.prePatchScrollY = null;
      this.prePatchAnchor = null;
    }
  },

  setupObserver() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }

    this.sentinel = this.el.querySelector("[data-infinite-scroll-sentinel]");
    if (!this.sentinel) return;

    this.observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        if (entry?.isIntersecting) this.loadMore();
      },
      {
        root: null,
        rootMargin: `0px 0px ${this.offset}px 0px`,
        threshold: 0,
      },
    );

    this.observer.observe(this.sentinel);
  },

  requestCheck() {
    if (this.checkRAF) cancelAnimationFrame(this.checkRAF);
    this.checkRAF = requestAnimationFrame(() => {
      this.checkRAF = null;
      this.checkViewportDistance();
    });
  },

  checkViewportDistance() {
    const viewportHeight =
      window.innerHeight || document.documentElement.clientHeight;
    const scrollBottom = currentScrollY() + viewportHeight;
    const documentHeight = Math.max(
      document.body?.scrollHeight || 0,
      document.documentElement?.scrollHeight || 0,
    );

    if (documentHeight > 0 && documentHeight - scrollBottom <= this.offset) {
      this.loadMore();
      return;
    }

    if (!this.sentinel) return;

    const sentinelTop = this.sentinel.getBoundingClientRect().top;
    const threshold = viewportHeight + this.offset;

    if (sentinelTop <= threshold) this.loadMore();
  },

  loadMore() {
    if (this.pending || this.disabled) return;

    const now = Date.now();
    if (now - this.lastRequestTime < this.minRequestInterval) return;

    this.lastRequestTime = now;
    this.beginLoadCycle();

    try {
      this.pushEvent("load-more", {});
    } catch (e) {
      this.pending = false;
      return;
    }

    if (this.pendingResetTimeout) clearTimeout(this.pendingResetTimeout);
    this.pendingResetTimeout = setTimeout(() => {
      this.pending = false;
      this.pendingResetTimeout = null;
    }, 3000);
  },

  beginLoadCycle() {
    this.pending = true;
    this.lastKnownScrollY = currentScrollY();
    this.loadCycleStartY = this.lastKnownScrollY;
    this.prePatchMode = "load-cycle";
    this.prePatchShouldPreserve = true;
    this.prePatchScrollY = this.lastKnownScrollY;
    this.prePatchAnchor = this.findVisiblePostAnchor();
    this.storeGlobalRestoreSnapshot(this.prePatchAnchor, this.prePatchScrollY);
    if (this.observer) this.observer.disconnect();
  },

  updated() {
    this.restoreFromGlobalSnapshotIfNeeded();

    this.loadingMore = this.el.dataset.loadingMore === "true";

    if (this.prePatchShouldPreserve) {
      this.restoreAnchorPosition(this.prePatchAnchor, this.prePatchScrollY);

      if (this.prePatchMode === "load-cycle") {
        this.scheduleSettledRestore(
          this.prePatchAnchor,
          this.prePatchScrollY,
          true,
        );
      }
    }

    this.prePatchMode = null;
    this.prePatchShouldPreserve = false;
    this.prePatchScrollY = null;
    this.prePatchAnchor = null;
    this.lastKnownScrollY = currentScrollY();
    this.clearGlobalRestoreSnapshot();
    if (!this.loadingMore) this.loadCycleStartY = null;
    this.pending = false;
    this.disabled =
      this.el.dataset.noMore === "true" ||
      this.el.dataset.loadingMore === "true";
    this.setupObserver();
    this.requestCheck();
  },

  findVisiblePostAnchor() {
    const postCards = this.el.querySelectorAll("[data-post-id]");
    const viewportHeight =
      window.innerHeight || document.documentElement.clientHeight;

    for (const card of postCards) {
      const rect = card.getBoundingClientRect();
      if (rect.bottom <= 0 || rect.top >= viewportHeight) continue;

      const postId = card.dataset.postId;
      if (!postId) continue;

      return { postId, top: rect.top };
    }

    return null;
  },

  getStableScrollY() {
    const scrollY = currentScrollY();

    if (scrollY === 0 && this.lastKnownScrollY > 0) {
      return this.lastKnownScrollY;
    }

    this.lastKnownScrollY = scrollY;
    return scrollY;
  },

  findPostById(postId) {
    if (!postId) return null;

    const escapedPostId =
      typeof CSS !== "undefined" && CSS.escape ? CSS.escape(postId) : postId;
    return this.el.querySelector(`[data-post-id="${escapedPostId}"]`);
  },

  restoreAnchorPosition(anchorSnapshot, fallbackScrollY) {
    let restored = false;
    const currentY = currentScrollY();

    if (anchorSnapshot?.postId) {
      const anchor = this.findPostById(anchorSnapshot.postId);

      if (anchor) {
        const newTop = anchor.getBoundingClientRect().top;
        const delta = newTop - anchorSnapshot.top;

        if (delta !== 0) window.scrollBy(0, delta);
        restored = true;
      }
    }

    const shouldUseFallbackScroll = (targetY) => {
      if (!Number.isFinite(targetY) || targetY <= 0) return false;

      return currentY === 0 || currentY + 120 < targetY;
    };

    if (!restored && shouldUseFallbackScroll(fallbackScrollY)) {
      window.scrollTo({ top: fallbackScrollY, behavior: "auto" });
      restored = true;
    } else if (!restored && shouldUseFallbackScroll(this.loadCycleStartY)) {
      window.scrollTo({ top: this.loadCycleStartY, behavior: "auto" });
      restored = true;
    }

    return restored;
  },

  cancelSettledRestore() {
    if (this.restoreRAF) cancelAnimationFrame(this.restoreRAF);
    this.restoreTimeouts.forEach((timeoutId) => clearTimeout(timeoutId));
    this.restoreRAF = null;
    this.restoreTimeouts = [];
  },

  scheduleSettledRestore(
    anchorSnapshot,
    fallbackScrollY,
    includeTimeout = false,
  ) {
    this.cancelSettledRestore();

    this.restoreRAF = requestAnimationFrame(() => {
      this.restoreRAF = null;
      this.restoreAnchorPosition(anchorSnapshot, fallbackScrollY);
    });

    if (includeTimeout) {
      [120, 280, 520].forEach((delay) => {
        const timeoutId = setTimeout(() => {
          this.restoreTimeouts = this.restoreTimeouts.filter(
            (id) => id !== timeoutId,
          );
          this.restoreAnchorPosition(anchorSnapshot, fallbackScrollY);
        }, delay);

        this.restoreTimeouts.push(timeoutId);
      });
    }
  },

  storeGlobalRestoreSnapshot(anchorSnapshot, fallbackScrollY) {
    infiniteScrollRestoreSnapshot = {
      rootId: this.el.id || null,
      anchorSnapshot: anchorSnapshot || null,
      fallbackScrollY,
      capturedAt: Date.now(),
    };
  },

  restoreFromGlobalSnapshotIfNeeded(fromMount = false) {
    const snapshot = infiniteScrollRestoreSnapshot;

    if (!snapshot) return;
    if (snapshot.rootId && this.el.id && snapshot.rootId !== this.el.id) return;
    if (Date.now() - snapshot.capturedAt > 5000) {
      this.clearGlobalRestoreSnapshot();
      return;
    }

    const shouldRestore =
      currentScrollY() === 0 &&
      Number.isFinite(snapshot.fallbackScrollY) &&
      snapshot.fallbackScrollY > 0;

    if (!shouldRestore) return;

    this.restoreAnchorPosition(snapshot.anchorSnapshot, snapshot.fallbackScrollY);

    if (!fromMount) {
      this.scheduleSettledRestore(
        snapshot.anchorSnapshot,
        snapshot.fallbackScrollY,
        true,
      );
    }
  },

  clearGlobalRestoreSnapshot() {
    if (!infiniteScrollRestoreSnapshot) return;
    if (
      infiniteScrollRestoreSnapshot.rootId &&
      this.el.id &&
      infiniteScrollRestoreSnapshot.rootId !== this.el.id
    ) {
      return;
    }

    infiniteScrollRestoreSnapshot = null;
  },

  destroyed() {
    if (this.pendingResetTimeout) clearTimeout(this.pendingResetTimeout);
    if (this.checkRAF) cancelAnimationFrame(this.checkRAF);
    this.cancelSettledRestore();
    if (this.handleScroll)
      window.removeEventListener("scroll", this.handleScroll);
    if (this.observer) this.observer.disconnect();
  },
};

/**
 * Stream Anchor Hook
 * Preserves the visible post position when stream patches prepend/update entries.
 */
export const PreserveStreamAnchor = {
  mounted() {
    this.prePatchAnchor = null;
    this.prePatchScrollY = null;
    this.restoreRAF = null;
    this.restoreTimeouts = [];
    this.lastKnownScrollY = currentScrollY();

    this.restoreFromGlobalSnapshotIfNeeded(true);

    this.handleScroll = () => {
      this.lastKnownScrollY = currentScrollY();
      this.cancelPendingRestore();
    };
    window.addEventListener("scroll", this.handleScroll, { passive: true });
  },

  beforeUpdate() {
    const stableScrollY = this.getStableScrollY();

    if (stableScrollY <= 0) {
      this.prePatchAnchor = null;
      this.prePatchScrollY = null;
      return;
    }

    this.prePatchAnchor = this.findVisiblePostAnchor();
    this.prePatchScrollY = stableScrollY;
    this.storeGlobalRestoreSnapshot(this.prePatchAnchor, this.prePatchScrollY);
  },

  updated() {
    this.restoreFromGlobalSnapshotIfNeeded();

    if (!this.prePatchAnchor?.postId && !Number.isFinite(this.prePatchScrollY)) return;

    this.restoreAnchorPosition(this.prePatchAnchor, this.prePatchScrollY);
    this.schedulePendingRestore(this.prePatchAnchor, this.prePatchScrollY);
    this.prePatchAnchor = null;
    this.prePatchScrollY = null;
    this.clearGlobalRestoreSnapshot();
  },

  findVisiblePostAnchor() {
    const postCards = this.el.querySelectorAll("[data-post-id]");
    const viewportHeight =
      window.innerHeight || document.documentElement.clientHeight;

    for (const card of postCards) {
      const rect = card.getBoundingClientRect();
      if (rect.bottom <= 0 || rect.top >= viewportHeight) continue;

      const postId = card.dataset.postId;
      if (!postId) continue;

      return { postId, top: rect.top };
    }

    return null;
  },

  getStableScrollY() {
    const scrollY = currentScrollY();

    if (scrollY === 0 && this.lastKnownScrollY > 0) {
      return this.lastKnownScrollY;
    }

    this.lastKnownScrollY = scrollY;
    return scrollY;
  },

  findPostById(postId) {
    if (!postId) return null;

    const escapedPostId =
      typeof CSS !== "undefined" && CSS.escape ? CSS.escape(postId) : postId;
    return this.el.querySelector(`[data-post-id="${escapedPostId}"]`);
  },

  restoreAnchorPosition(anchorSnapshot, fallbackScrollY) {
    if (anchorSnapshot?.postId) {
      const anchor = this.findPostById(anchorSnapshot.postId);

      if (anchor) {
        const delta = anchor.getBoundingClientRect().top - anchorSnapshot.top;
        if (delta !== 0) window.scrollBy(0, delta);
        return;
      }
    }

    if (
      Number.isFinite(fallbackScrollY) &&
      fallbackScrollY > 0 &&
      currentScrollY() === 0
    ) {
      window.scrollTo({ top: fallbackScrollY, behavior: "auto" });
    }
  },

  cancelPendingRestore() {
    if (this.restoreRAF) cancelAnimationFrame(this.restoreRAF);
    this.restoreTimeouts.forEach((timeoutId) => clearTimeout(timeoutId));
    this.restoreRAF = null;
    this.restoreTimeouts = [];
  },

  schedulePendingRestore(anchorSnapshot, fallbackScrollY) {
    this.cancelPendingRestore();

    this.restoreRAF = requestAnimationFrame(() => {
      this.restoreRAF = null;
      this.restoreAnchorPosition(anchorSnapshot, fallbackScrollY);
    });
    [120, 280, 520].forEach((delay) => {
      const timeoutId = setTimeout(() => {
        this.restoreTimeouts = this.restoreTimeouts.filter(
          (id) => id !== timeoutId,
        );
        this.restoreAnchorPosition(anchorSnapshot, fallbackScrollY);
      }, delay);

      this.restoreTimeouts.push(timeoutId);
    });
  },

  storeGlobalRestoreSnapshot(anchorSnapshot, fallbackScrollY) {
    streamRestoreSnapshot = {
      rootId: this.el.id || null,
      anchorSnapshot: anchorSnapshot || null,
      fallbackScrollY,
      capturedAt: Date.now(),
    };
  },

  restoreFromGlobalSnapshotIfNeeded(fromMount = false) {
    const snapshot = streamRestoreSnapshot;

    if (!snapshot) return;
    if (snapshot.rootId && this.el.id && snapshot.rootId !== this.el.id) return;
    if (Date.now() - snapshot.capturedAt > 5000) {
      this.clearGlobalRestoreSnapshot();
      return;
    }

    const shouldRestore =
      currentScrollY() === 0 &&
      Number.isFinite(snapshot.fallbackScrollY) &&
      snapshot.fallbackScrollY > 0;

    if (!shouldRestore) return;

    this.restoreAnchorPosition(snapshot.anchorSnapshot, snapshot.fallbackScrollY);

    if (!fromMount) {
      this.schedulePendingRestore(snapshot.anchorSnapshot, snapshot.fallbackScrollY);
    }
  },

  clearGlobalRestoreSnapshot() {
    if (!streamRestoreSnapshot) return;
    if (
      streamRestoreSnapshot.rootId &&
      this.el.id &&
      streamRestoreSnapshot.rootId !== this.el.id
    ) {
      return;
    }

    streamRestoreSnapshot = null;
  },

  destroyed() {
    this.cancelPendingRestore();
    this.clearGlobalRestoreSnapshot();
    if (this.handleScroll)
      window.removeEventListener("scroll", this.handleScroll);
  },
};

export const PreserveQueuedPostsButtonScroll = {
  mounted() {
    this.restoreRAF = null;
    this.restoreTimeouts = [];

    this.handleClick = () => {
      const stream =
        document.getElementById("timeline-posts-stream") || document;

      queuedPostsScrollSnapshot = {
        anchor: findVisiblePostAnchor(stream),
        scrollY: currentScrollY(),
      };
    };

    this.el.addEventListener("click", this.handleClick);
  },

  destroyed() {
    if (this.handleClick)
      this.el.removeEventListener("click", this.handleClick);
    if (!queuedPostsScrollSnapshot) return;

    this.restoreRAF = requestAnimationFrame(() => {
      this.restoreRAF = null;
      restoreQueuedPostsScroll();
    });
    [120, 280, 520].forEach((delay) => {
      const timeoutId = setTimeout(() => {
        this.restoreTimeouts = this.restoreTimeouts.filter(
          (id) => id !== timeoutId,
        );
        restoreQueuedPostsScroll();
      }, delay);

      this.restoreTimeouts.push(timeoutId);
    });

    setTimeout(() => {
      queuedPostsScrollSnapshot = null;
    }, 600);
  },
};

/**
 * User Hover Card Hook
 * Shows a profile preview card when hovering over usernames/avatars
 */
export const UserHoverCard = {
  mounted() {
    this.card = this.el.querySelector("[data-hover-card]");
    if (!this.card) return;

    this.showTimeout = null;
    this.hideTimeout = null;
    this.isCardHovered = false;

    this.handleMouseEnter = () => {
      clearTimeout(this.hideTimeout);
      this.showTimeout = setTimeout(() => this.showCard(), 400);
    };

    this.handleMouseLeave = () => {
      clearTimeout(this.showTimeout);
      this.hideTimeout = setTimeout(() => {
        if (!this.isCardHovered) this.hideCard();
      }, 200);
    };

    this.handleCardEnter = () => {
      this.isCardHovered = true;
      clearTimeout(this.hideTimeout);
    };

    this.handleCardLeave = () => {
      this.isCardHovered = false;
      this.hideTimeout = setTimeout(() => this.hideCard(), 200);
    };

    const trigger = this.el.querySelector("[data-hover-trigger]");
    if (trigger) {
      trigger.addEventListener("mouseenter", this.handleMouseEnter);
      trigger.addEventListener("mouseleave", this.handleMouseLeave);
    } else {
      this.el.addEventListener("mouseenter", this.handleMouseEnter);
      this.el.addEventListener("mouseleave", this.handleMouseLeave);
    }

    this.card.addEventListener("mouseenter", this.handleCardEnter);
    this.card.addEventListener("mouseleave", this.handleCardLeave);
  },

  showCard() {
    if (this.card) {
      this.card.classList.remove("opacity-0", "invisible", "scale-95");
      this.card.classList.add("opacity-100", "visible", "scale-100");
    }
  },

  hideCard() {
    if (this.card) {
      this.card.classList.remove("opacity-100", "visible", "scale-100");
      this.card.classList.add("opacity-0", "invisible", "scale-95");
    }
  },

  destroyed() {
    clearTimeout(this.showTimeout);
    clearTimeout(this.hideTimeout);
  },
};

/**
 * Image Modal Hook
 * Adds keyboard and scroll navigation support for image galleries
 */
export const ImageModal = {
  mounted() {
    this.handleKeyDown = (e) => {
      if (e.key === "Escape") this.pushEvent("close_image_modal", {});
      else if (e.key === "ArrowLeft") this.pushEvent("prev_image", {});
      else if (e.key === "ArrowRight") this.pushEvent("next_image", {});
      else if (e.key === "ArrowUp") {
        e.preventDefault();
        this.pushEvent("prev_media_post", {});
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        this.pushEvent("next_media_post", {});
      }
    };

    this.lastScrollTime = 0;
    this.scrollThrottle = 200;

    this.handleWheel = (e) => {
      if (!this.el.contains(e.target)) return;
      const now = Date.now();
      if (now - this.lastScrollTime < this.scrollThrottle) return;
      if (Math.abs(e.deltaY) < 10) return;

      this.lastScrollTime = now;
      e.preventDefault();

      if (e.deltaY < 0) this.pushEvent("prev_image", {});
      else this.pushEvent("next_image", {});
    };

    document.addEventListener("keydown", this.handleKeyDown);
    document.addEventListener("wheel", this.handleWheel, { passive: false });
  },

  destroyed() {
    document.removeEventListener("keydown", this.handleKeyDown);
    document.removeEventListener("wheel", this.handleWheel);
  },
};

function safeJsonParse(value, fallback) {
  if (!value) return fallback;

  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function readStorageMap(key) {
  return safeJsonParse(window.localStorage?.getItem(key), {});
}

function writeStorageMap(key, value) {
  try {
    window.localStorage?.setItem(key, JSON.stringify(value));
  } catch {
    // Ignore storage failures so LiveView stays functional.
  }
}

export const SessionContinuity = {
  mounted() {
    this.scope = this.el.dataset.scope || "timeline";
    this.userId = this.el.dataset.userId || null;

    if (!this.userId) return;

    if (this.scope === "timeline") this.restoreTimelineContinuity();
    if (this.scope === "community") this.restoreCommunityPreferences();

    this.handlePageHide = () => this.persistCurrentState();
    window.addEventListener("pagehide", this.handlePageHide);
  },

  updated() {
    if (!this.userId) return;
    if (this.scope === "community") this.persistCommunityPreferences();
  },

  destroyed() {
    this.persistCurrentState();
    window.removeEventListener("pagehide", this.handlePageHide);
  },

  persistCurrentState() {
    if (!this.userId) return;

    if (this.scope === "timeline") {
      try {
        window.localStorage?.setItem(
          TIMELINE_LAST_VISIT_KEY,
          String(Date.now()),
        );
      } catch {
        // Ignore storage failures.
      }
      return;
    }

    if (this.scope === "community") {
      const communityId = this.el.dataset.communityId;
      if (!communityId) return;

      const visits = readStorageMap(COMMUNITY_LAST_VISIT_KEY);
      visits[communityId] = Date.now();
      writeStorageMap(COMMUNITY_LAST_VISIT_KEY, visits);
      this.persistCommunityPreferences();
    }
  },

  restoreTimelineContinuity() {
    const lastTimelineVisitAt = window.localStorage?.getItem(
      TIMELINE_LAST_VISIT_KEY,
    );
    const communityLastVisitedAt = readStorageMap(COMMUNITY_LAST_VISIT_KEY);

    this.pushEvent("restore_session_continuity", {
      last_timeline_visit_at: lastTimelineVisitAt,
      community_last_visited_at: communityLastVisitedAt,
    });
  },

  restoreCommunityPreferences() {
    const communityId = this.el.dataset.communityId;
    if (!communityId) return;

    const preferences = readStorageMap(COMMUNITY_PREFERENCES_KEY);
    const communityPreferences = preferences[communityId];

    if (communityPreferences) {
      this.pushEvent("restore_community_preferences", communityPreferences);
    }
  },

  persistCommunityPreferences() {
    const communityId = this.el.dataset.communityId;
    if (!communityId) return;

    const preferences = readStorageMap(COMMUNITY_PREFERENCES_KEY);
    preferences[communityId] = {
      view: this.el.dataset.currentView || "posts",
      sort: this.el.dataset.sortBy || "hot",
    };
    writeStorageMap(COMMUNITY_PREFERENCES_KEY, preferences);
  },
};
