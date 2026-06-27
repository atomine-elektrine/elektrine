const TIMELINE_LAST_VISIT_KEY = "timeline-last-visit-at";
const COMMUNITY_LAST_VISIT_KEY = "community-last-visit-at";
const COMMUNITY_PREFERENCES_KEY = "community-view-preferences";

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
