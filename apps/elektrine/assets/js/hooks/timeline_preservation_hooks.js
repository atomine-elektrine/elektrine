function currentScrollY() {
  return Math.max(
    window.scrollY || 0,
    window.pageYOffset || 0,
    document.documentElement?.scrollTop || 0,
    document.body?.scrollTop || 0,
  );
}

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
