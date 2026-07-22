function currentScrollY() {
  return Math.max(
    window.scrollY || 0,
    window.pageYOffset || 0,
    document.documentElement?.scrollTop || 0,
    document.body?.scrollTop || 0,
  );
}

function postAnchorFromElement(card) {
  const postId = card?.dataset?.postId;
  if (!postId) return null;

  return { postId, top: card.getBoundingClientRect().top };
}

function findVisiblePostAnchor(root = document) {
  const viewportHeight =
    window.innerHeight || document.documentElement.clientHeight;
  const viewportWidth =
    window.innerWidth || document.documentElement.clientWidth;

  if (viewportHeight <= 0 || viewportWidth <= 0) return null;

  const rootRect = root.getBoundingClientRect?.();
  const rootCenterX = rootRect
    ? rootRect.left + rootRect.width / 2
    : viewportWidth / 2;
  const sampleX = Math.max(0, Math.min(viewportWidth - 1, rootCenterX));
  const sampleYs = [
    Math.min(96, viewportHeight - 1),
    Math.floor(viewportHeight * 0.25),
    Math.floor(viewportHeight * 0.5),
    Math.floor(viewportHeight * 0.75),
  ].filter((y) => y >= 0 && y < viewportHeight);

  for (const sampleY of sampleYs) {
    const target = document.elementFromPoint(sampleX, sampleY);
    const card = target?.closest?.("[data-post-id]");
    if (card && root.contains(card)) {
      const anchor = postAnchorFromElement(card);
      if (anchor) return anchor;
    }
  }

  const lowerBound = -Math.max(viewportHeight * 1.5, 1200);
  const belowBreak = viewportHeight + Math.max(viewportHeight, 1200);
  const postCards = root.querySelectorAll("[data-post-id]");

  for (const card of postCards) {
    const rect = card.getBoundingClientRect();
    if (rect.bottom <= lowerBound) continue;
    if (rect.top >= belowBreak) break;
    if (rect.bottom <= 0 || rect.top >= viewportHeight) continue;

    const anchor = postAnchorFromElement(card);
    if (anchor) return anchor;
  }

  return null;
}

function findPostById(root, postId) {
  if (!postId) return null;

  const escapedPostId =
    typeof CSS !== "undefined" && CSS.escape ? CSS.escape(postId) : postId;
  return root.querySelector(`[data-post-id="${escapedPostId}"]`);
}

let queuedPostsScrollSnapshot = null;
let streamRestoreSnapshot = null;

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
    this.clearGlobalRestoreSnapshot();

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
    return findVisiblePostAnchor(this.el);
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
    return findPostById(this.el, postId);
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

/**
 * "Show N new posts" — Twitter-style: after the stream prepends, jump to the
 * top of the feed so the newly inserted posts are actually visible.
 * (Previously preserved scroll, which left new posts above the viewport.)
 */
export const PreserveQueuedPostsButtonScroll = {
  mounted() {
    this.restoreRAF = null;
    this.restoreTimeouts = [];
    this.pendingScrollTop = false;

    this.handleClick = () => {
      // Clear any preserve-scroll snapshot so stream patches don't pin us mid-feed.
      queuedPostsScrollSnapshot = null;
      this.pendingScrollTop = true;
    };

    this.el.addEventListener("click", this.handleClick);
  },

  updated() {
    if (!this.pendingScrollTop) return;
    this.pendingScrollTop = false;
    this.scrollFeedToTop();
  },

  destroyed() {
    if (this.handleClick)
      this.el.removeEventListener("click", this.handleClick);

    // Button unmounts once the queue is empty — still scroll so new posts show.
    if (this.pendingScrollTop) {
      this.pendingScrollTop = false;
      this.scrollFeedToTop();
    }

    this.restoreTimeouts.forEach((id) => clearTimeout(id));
    this.restoreTimeouts = [];
    if (this.restoreRAF) cancelAnimationFrame(this.restoreRAF);
  },

  scrollFeedToTop() {
    const scrollTop = () => {
      const target =
        document.getElementById("timeline-posts-stream") ||
        document.getElementById("portal-posts-list") ||
        document.getElementById("timeline-infinite-scroll") ||
        document.getElementById("portal-infinite-scroll");

      if (target && typeof target.scrollIntoView === "function") {
        target.scrollIntoView({ behavior: "smooth", block: "start" });
      }

      window.scrollTo({ top: 0, behavior: "smooth" });
    };

    this.restoreRAF = requestAnimationFrame(() => {
      this.restoreRAF = null;
      scrollTop();
    });

    // Stream patches can lag a frame; re-assert a couple times.
    [80, 200].forEach((delay) => {
      const timeoutId = setTimeout(() => {
        this.restoreTimeouts = this.restoreTimeouts.filter(
          (id) => id !== timeoutId,
        );
        scrollTop();
      }, delay);
      this.restoreTimeouts.push(timeoutId);
    });
  },
};
