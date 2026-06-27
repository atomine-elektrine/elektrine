/**
 * Timeline Hooks
 * Hooks for timeline/feed interactions including post clicks, infinite scroll,
 * dwell time tracking and infinite scroll restoration.
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
let infiniteScrollRestoreSnapshot = null;
const ACTION_LOCK_MS = 700;
const actionLocks = new Map();

if (typeof window !== "undefined") {
  // js-check: allow-global-listener-singleton
  window.addEventListener(
    "click",
    (event) => {
      const target = event.target instanceof Element ? event.target : null;
      const actionEl = target?.closest?.("[data-action-lock-key]");
      if (!(actionEl instanceof HTMLButtonElement)) return;

      const key = actionEl.dataset.actionLockKey;
      if (!key) return;

      if (actionLocks.has(key)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        return;
      }

      actionLocks.set(key, window.setTimeout(() => actionLocks.delete(key), ACTION_LOCK_MS));
    },
    true,
  );
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

/**
 * Post Click Hook
 * Handles navigation when clicking on posts and tracks dwell time
 */
export const PostClick = {
  mounted() {
    this.suppressNextClickFromPickerDismiss = false;

    this.handlePointerDown = (e) => {
      const openReactionPicker = this.el.querySelector(
        "[data-reaction-picker-root][data-portal-dropdown-open='true'], [data-reaction-picker-root]:focus-within",
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

        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) {
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
        } else {
          navLink.click();
        }

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
    this.previousScrollRestoration = null;

    this.disableNativeScrollRestoration();
    this.resetReloadScrollPosition();
    this.clearGlobalRestoreSnapshot();

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

  disableNativeScrollRestoration() {
    if (!window.history || !("scrollRestoration" in window.history)) return;

    this.previousScrollRestoration = window.history.scrollRestoration;
    window.history.scrollRestoration = "manual";
  },

  resetReloadScrollPosition() {
    const navigation = performance.getEntriesByType?.("navigation")?.[0];
    const isReload = navigation?.type === "reload";

    if (isReload && currentScrollY() > 0) {
      window.scrollTo({ top: 0, behavior: "auto" });
      this.lastKnownScrollY = 0;
    }
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
    if (
      this.previousScrollRestoration &&
      window.history &&
      "scrollRestoration" in window.history
    ) {
      window.history.scrollRestoration = this.previousScrollRestoration;
    }
  },
};
