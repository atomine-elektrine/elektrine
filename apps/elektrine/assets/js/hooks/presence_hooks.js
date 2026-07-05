/**
 * Presence-related LiveView hooks.
 *
 * ActivityTracker drives auto-away detection client-side: it pushes
 * "auto_away_timeout" after five idle minutes and "user_activity" with
 * clear_away when the user returns. Ordinary activity is handled entirely in
 * the browser (resetting the idle timer) and sends nothing to the server.
 *
 * Device info (type, browser, timezone) is sent once in the LiveSocket
 * connect params (see detectDevice below), not via events.
 */

// Auto-away timeout in milliseconds (5 minutes)
const AUTO_AWAY_TIMEOUT = 5 * 60 * 1000;

function isHookConnected(hook) {
  return Boolean(hook?.liveSocket?.isConnected?.() && hook?.el?.isConnected);
}

function safePushEvent(hook, event, payload) {
  if (!isHookConnected(hook)) return Promise.resolve(null);
  return Promise.resolve(hook.pushEvent(event, payload)).catch(() => null);
}

/**
 * Detects device type, browser, and timezone for presence metadata.
 * Called once at LiveSocket setup and sent as connect params.
 */
export function detectDevice() {
  const ua = navigator.userAgent;
  const isMobile = /iPhone|iPad|iPod|Android|webOS|BlackBerry|IEMobile|Opera Mini/i.test(ua);
  const isTablet = /iPad|Android/i.test(ua) && !/Mobile/i.test(ua);

  let deviceType = 'desktop';
  if (isTablet) {
    deviceType = 'tablet';
  } else if (isMobile) {
    deviceType = 'mobile';
  }

  let browser = 'unknown';
  if (ua.includes('Firefox')) browser = 'firefox';
  else if (ua.includes('Edg')) browser = 'edge';
  else if (ua.includes('Chrome')) browser = 'chrome';
  else if (ua.includes('Safari')) browser = 'safari';
  else if (ua.includes('Opera') || ua.includes('OPR')) browser = 'opera';

  return {
    device_type: deviceType,
    browser: browser,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone
  };
}

/**
 * ActivityTracker - Tracks user activity for auto-away detection.
 *
 * Attach to a root element (e.g., body or main container) to track mouse,
 * keyboard, touch, scroll, click, and visibility events.
 */
export const ActivityTracker = {
  mounted() {
    this.isAway = false;
    this.awayTimeout = null;
    this.boundHandleActivity = this.handleActivity.bind(this);

    const events = ['mousemove', 'keydown', 'touchstart', 'scroll', 'click', 'focus'];
    events.forEach(event => {
      document.addEventListener(event, this.boundHandleActivity, { passive: true });
    });

    this.boundHandleVisibilityChange = this.handleVisibilityChange.bind(this);
    document.addEventListener('visibilitychange', this.boundHandleVisibilityChange);

    this.resetAwayTimer();

    // Keep local state in sync with the server's view of auto-away.
    this.handleEvent("auto_away_set", ({ was_auto }) => {
      if (was_auto) {
        this.isAway = true;
      }
    });

    this.handleEvent("auto_away_cleared", () => {
      this.isAway = false;
    });
  },

  destroyed() {
    const events = ['mousemove', 'keydown', 'touchstart', 'scroll', 'click', 'focus'];
    events.forEach(event => {
      document.removeEventListener(event, this.boundHandleActivity);
    });

    if (this.boundHandleVisibilityChange) {
      document.removeEventListener('visibilitychange', this.boundHandleVisibilityChange);
    }

    if (this.awayTimeout) {
      clearTimeout(this.awayTimeout);
    }
  },

  handleActivity() {
    this.resetAwayTimer();

    // Only tell the server anything when there's a state change to make:
    // returning from auto-away.
    if (this.isAway) {
      this.isAway = false;
      void safePushEvent(this, "user_activity", { clear_away: true });
    }
  },

  handleVisibilityChange() {
    if (document.visibilityState === 'visible') {
      this.handleActivity();
    }
  },

  resetAwayTimer() {
    if (this.awayTimeout) {
      clearTimeout(this.awayTimeout);
    }

    this.awayTimeout = setTimeout(() => {
      if (!this.isAway) {
        this.isAway = true;
        void safePushEvent(this, "auto_away_timeout", {});
      }
    }, AUTO_AWAY_TIMEOUT);
  }
};
