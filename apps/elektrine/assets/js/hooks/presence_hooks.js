/**
 * Presence-related LiveView hooks
 * Handles activity tracking for auto-away detection and device type detection
 */

// Auto-away timeout in milliseconds (5 minutes)
const AUTO_AWAY_TIMEOUT = 5 * 60 * 1000;

// Activity report throttle (only report activity every 30 seconds)
const ACTIVITY_THROTTLE = 30 * 1000;

/**
 * ActivityTracker - Tracks user activity for auto-away detection
 * 
 * Attach to a root element (e.g., body or main container) to track:
 * - Mouse movements
 * - Keyboard input
 * - Touch events
 * - Scroll events
 * - Click events
 * 
 * Reports activity to server which resets the auto-away timer.
 */
export const ActivityTracker = {
  mounted() {
    this.lastActivityReport = 0;
    this.isAway = false;
    this.awayTimeout = null;
    this.boundHandleActivity = this.handleActivity.bind(this);
    
    // Track various user activities
    const events = ['mousemove', 'keydown', 'touchstart', 'scroll', 'click', 'focus'];
    events.forEach(event => {
      document.addEventListener(event, this.boundHandleActivity, { passive: true });
    });
    
    // Also track visibility changes
    document.addEventListener('visibilitychange', this.handleVisibilityChange.bind(this));
    
    // Start the away timer
    this.resetAwayTimer();
    
    // Listen for status updates from server
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
    
    if (this.awayTimeout) {
      clearTimeout(this.awayTimeout);
    }
  },
  
  handleActivity() {
    const now = Date.now();
    
    // Reset the away timer on any activity
    this.resetAwayTimer();
    
    // If user was auto-away, clear it
    if (this.isAway) {
      this.isAway = false;
      this.pushEvent("user_activity", { clear_away: true });
      this.lastActivityReport = now;
      return;
    }
    
    // Throttle activity reports to reduce server load
    if (now - this.lastActivityReport >= ACTIVITY_THROTTLE) {
      this.lastActivityReport = now;
      this.pushEvent("user_activity", { timestamp: now });
    }
  },
  
  handleVisibilityChange() {
    if (document.visibilityState === 'visible') {
      // User returned to tab - treat as activity
      this.handleActivity();
    } else {
      // User left tab - could start a shorter away timer here if desired
    }
  },
  
  resetAwayTimer() {
    if (this.awayTimeout) {
      clearTimeout(this.awayTimeout);
    }
    
    this.awayTimeout = setTimeout(() => {
      // User has been inactive - notify server to set auto-away
      if (!this.isAway) {
        this.isAway = true;
        this.pushEvent("auto_away_timeout", {});
      }
    }, AUTO_AWAY_TIMEOUT);
  }
};

/**
 * DeviceDetector - Detects device type and reports to presence
 * 
 * Attach to root element to detect:
 * - Device type (desktop, tablet, mobile)
 * - Browser info
 * - Connection type (if available)
 */
export const DeviceDetector = {
  mounted() {
    const deviceInfo = this.detectDevice();
    
    // Report device info to server
    this.pushEvent("device_detected", deviceInfo);
    
    // Listen for connection changes
    if (navigator.connection) {
      navigator.connection.addEventListener('change', () => {
        this.pushEvent("connection_changed", {
          type: navigator.connection.effectiveType,
          downlink: navigator.connection.downlink
        });
      });
    }
  },
  
  detectDevice() {
    const ua = navigator.userAgent;
    const isMobile = /iPhone|iPad|iPod|Android|webOS|BlackBerry|IEMobile|Opera Mini/i.test(ua);
    const isTablet = /iPad|Android/i.test(ua) && !/Mobile/i.test(ua);
    
    let deviceType = 'desktop';
    if (isTablet) {
      deviceType = 'tablet';
    } else if (isMobile) {
      deviceType = 'mobile';
    }
    
    // Detect browser
    let browser = 'unknown';
    if (ua.includes('Firefox')) browser = 'firefox';
    else if (ua.includes('Edg')) browser = 'edge';
    else if (ua.includes('Chrome')) browser = 'chrome';
    else if (ua.includes('Safari')) browser = 'safari';
    else if (ua.includes('Opera') || ua.includes('OPR')) browser = 'opera';
    
    // Get connection info if available
    let connectionType = null;
    if (navigator.connection) {
      connectionType = navigator.connection.effectiveType;
    }
    
    return {
      device_type: deviceType,
      browser: browser,
      screen_width: window.screen.width,
      screen_height: window.screen.height,
      connection_type: connectionType,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone
    };
  }
};

/**
 * PresenceIndicator - Updates presence indicator UI
 * 
 * Listens for presence updates and updates the UI accordingly.
 * Can show device icons, connection quality, etc.
 */
export const PresenceIndicator = {
  mounted() {
    // Listen for presence updates
    this.handleEvent("presence_updated", ({ user_id, status, device_type, devices }) => {
      this.updateIndicator(user_id, status, device_type, devices);
    });
  },
  
  updateIndicator(userId, status, deviceType, devices) {
    // The actual UI update happens via LiveView assigns
    // This hook can be extended to add animations or tooltips
    const indicator = this.el.querySelector(`[data-user-id="${userId}"]`);
    if (indicator) {
      // Add animation class for status change
      indicator.classList.add('presence-updated');
      setTimeout(() => {
        indicator.classList.remove('presence-updated');
      }, 300);
    }
  }
};
