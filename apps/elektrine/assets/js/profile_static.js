/**
 * Profile Static Page Handler
 * 
 * This module handles interactive functionality for static (non-LiveView) profile pages.
 * Used when profiles are accessed via subdomains (e.g., username.z.org) where LiveView
 * websockets don't work properly due to cross-origin restrictions.
 * 
 * Features:
 * - Followers/Following modals with async data fetching
 * - Follow/Unfollow functionality
 * - Friend request actions (send, accept, cancel, unfriend)
 * - Share modal with clipboard copy
 * - Timeline drawer toggle
 * - Profile hooks initialization (typewriter, video background)
 */

import { TypewriterHook, TabTitleTypewriter, VideoBackground } from "./hooks/profile_hooks"

// =============================================================================
// Constants
// =============================================================================

const SELECTORS = {
  container: "#profile-container",
  csrfToken: 'meta[name="csrf-token"]',
  
  // Modals (outside container, at document level)
  followersModal: '[data-modal="followers"]',
  followingModal: '[data-modal="following"]',
  shareModal: '[data-modal="share"]',
  widgetImageModal: '[data-modal="widget-image"]',
  
  // Modal content
  followersList: '[data-role="followers-list"]',
  followersEmpty: '[data-role="followers-empty"]',
  followingList: '[data-role="following-list"]',
  followingEmpty: '[data-role="following-empty"]',
  widgetImageContent: '[data-role="widget-image-content"]',
  
  // Buttons (inside container)
  showFollowers: '[data-action="show-followers"]',
  showFollowing: '[data-action="show-following"]',
  showShareModal: '[data-action="show-share-modal"]',
  toggleFollow: '[data-action="toggle-follow"]',
  toggleTimelineDrawer: '[data-action="toggle-timeline-drawer"]',
  openWidgetImage: '[data-action="open-widget-image"]',
  
  // Buttons (outside container, in modals)
  closeModal: '[data-action="close-modal"]',
  closeShareModal: '[data-action="close-share-modal"]',
  closeWidgetImage: '[data-action="close-widget-image"]',
  copyProfileUrl: '[data-action="copy-profile-url"]',
  profileShareUrl: "#profile-share-url",
  
  // Timeline drawer
  timelineDrawer: '[data-role="timeline-drawer"]'
}

const ICONS = {
  checkmark: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="m4.5 12.75 6 6 9-13.5" /></svg>',
  user: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632Z" /></svg>'
}

// Main domain for absolute URLs (handles subdomains like username.z.org -> z.org)
const MAIN_DOMAIN = getMainDomain()

const FRIEND_ACTIONS = [
  { selector: '[data-action="send-friend-request"]', method: "POST", endpoint: "friend-request" },
  { selector: '[data-action="accept-friend-request"]', method: "POST", endpoint: "friend-request/accept" },
  { selector: '[data-action="cancel-friend-request"]', method: "DELETE", endpoint: "friend-request" },
  { selector: '[data-action="unfriend"]', method: "DELETE", endpoint: "friend" }
]

const COPY_FEEDBACK_DURATION = 2000

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Get the main domain URL for absolute links.
 * Converts subdomain URLs (e.g., username.z.org) to main domain (z.org).
 * This ensures links in modals navigate to the main site, not the subdomain.
 */
function getMainDomain() {
  const host = window.location.host
  const protocol = window.location.protocol
  
  // Check if we're on a subdomain (e.g., username.z.org)
  // Main domain patterns: z.org, localhost:4000
  const parts = host.split('.')
  
  if (parts.length > 2 && host.endsWith('.z.org')) {
    // On subdomain like username.z.org -> return https://z.org
    return `${protocol}//z.org`
  }
  
  // On main domain or localhost, use current origin
  return window.location.origin
}

/**
 * Convert hex color to RGB object
 */
function hexToRgb(hex) {
  if (!hex || !hex.startsWith("#") || hex.length < 7) {
    return { r: 0, g: 0, b: 0 }
  }
  return {
    r: parseInt(hex.slice(1, 3), 16) || 0,
    g: parseInt(hex.slice(3, 5), 16) || 0,
    b: parseInt(hex.slice(5, 7), 16) || 0
  }
}

/**
 * Determine if a color is light (for contrast calculations)
 */
function isLightColor(hex) {
  const { r, g, b } = hexToRgb(hex)
  const luminance = 0.2126 * (r / 255) + 0.7152 * (g / 255) + 0.0722 * (b / 255)
  return luminance > 0.5
}

/**
 * Get CSRF token from meta tag
 */
function getCsrfToken() {
  return document.querySelector(SELECTORS.csrfToken)?.getAttribute("content") || ""
}

// =============================================================================
// Hook Initialization (for non-LiveView pages)
// =============================================================================

/**
 * Create a hook instance that mimics LiveView hook behavior
 */
function createHookInstance(hook, el) {
  const instance = { el }
  Object.keys(hook).forEach((key) => {
    instance[key] = typeof hook[key] === 'function' ? hook[key].bind(instance) : hook[key]
  })
  return instance
}

/**
 * Initialize a hook on all matching elements
 */
function initHook(hook, selector) {
  document.querySelectorAll(selector).forEach((el) => {
    const instance = createHookInstance(hook, el)
    if (instance.mounted) instance.mounted()
  })
}

/**
 * Initialize all profile-related hooks
 */
function initProfileHooks() {
  initHook(TypewriterHook, '[phx-hook="TypewriterHook"]')
  initHook(TabTitleTypewriter, '[phx-hook="TabTitleTypewriter"]')
  initHook(VideoBackground, '[phx-hook="VideoBackground"]')
}

// =============================================================================
// API Functions
// =============================================================================

/**
 * Fetch JSON from API with proper headers and error handling
 */
async function fetchJson(url, options = {}) {
  const headers = {
    "Accept": "application/json",
    ...options.headers
  }
  
  const response = await fetch(url, { ...options, headers })
  
  // Redirect to login if unauthorized
  if (response.status === 401) {
    window.location.href = "/login"
    return null
  }
  
  const data = await response.json().catch(() => ({}))
  
  if (!response.ok) {
    throw new Error(data.error || "Request failed")
  }
  
  return data
}

/**
 * Make an authenticated API request
 */
async function apiRequest(url, method = "GET") {
  return fetchJson(url, {
    method,
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": getCsrfToken()
    }
  })
}

// =============================================================================
// Modal Functions
// =============================================================================

function openModal(modal) {
  if (modal) modal.classList.add("modal-open")
}

function closeModal(modal) {
  if (modal) modal.classList.remove("modal-open")
}

// =============================================================================
// UI Component Builders
// =============================================================================

/**
 * Build an avatar element for a user entry
 */
function buildAvatar(entry) {
  const avatar = document.createElement("div")
  
  if (entry.avatar_url) {
    avatar.className = "w-10 h-10 rounded-full overflow-hidden bg-base-300 flex items-center justify-center"
    const img = document.createElement("img")
    img.src = entry.avatar_url
    img.alt = entry.display_name || entry.username
    img.className = "w-full h-full object-cover"
    avatar.appendChild(img)
  } else {
    // Match the placeholder_avatar component: purple gradient with hero-user icon
    avatar.className = "w-10 h-10 rounded-full flex items-center justify-center flex-shrink-0"
    avatar.style.background = "linear-gradient(to bottom right, #9333ea, #6b21a8)"
    const icon = document.createElement("div")
    icon.className = "w-6 h-6 text-white"
    icon.innerHTML = ICONS.user
    avatar.appendChild(icon)
  }

  return avatar
}

/**
 * Build a user row element for followers/following lists.
 * Uses absolute URLs to ensure links go to the main domain, not subdomains.
 */
function buildUserRow(entry) {
  const row = document.createElement("a")
  row.className = "flex items-center gap-3 p-2 hover:bg-base-200 rounded-lg"
  
  const isRemote = entry.type === "remote"
  const displayHandle = isRemote 
    ? `@${entry.username}@${entry.domain}`
    : `@${entry.handle || entry.username}@z.org`
  
  // Use absolute URLs to main domain so links work correctly from subdomains
  row.href = isRemote 
    ? `${MAIN_DOMAIN}/remote/${entry.username}@${entry.domain}`
    : `${MAIN_DOMAIN}/${entry.handle || entry.username}`
  
  row.appendChild(buildAvatar(entry))
  
  const text = document.createElement("div")
  text.className = "flex-1 min-w-0"
  
  const name = document.createElement("p")
  name.className = "font-medium truncate"
  name.textContent = entry.display_name || entry.username
  
  const handle = document.createElement("p")
  handle.className = "text-xs opacity-70 truncate"
  handle.textContent = displayHandle
  
  text.appendChild(name)
  text.appendChild(handle)
  row.appendChild(text)
  
  return row
}

/**
 * Render a list of followers/following into a container
 */
function renderFollowList(listEl, emptyEl, entries) {
  if (!listEl || !emptyEl) return
  
  listEl.innerHTML = ""
  emptyEl.classList.add("hidden")

  if (!entries || entries.length === 0) {
    emptyEl.classList.remove("hidden")
    return
  }

  const wrapper = document.createElement("div")
  wrapper.className = "space-y-2"
  
  entries.forEach((entry) => {
    wrapper.appendChild(buildUserRow(entry))
  })

  listEl.appendChild(wrapper)
}

// =============================================================================
// Button State Management
// =============================================================================

/**
 * Update follow button appearance based on follow state
 */
function updateFollowButton(button, isFollowing, accentColor) {
  if (!button) return
  
  const textColor = isLightColor(accentColor) ? "#000000" : "#ffffff"
  button.dataset.following = isFollowing ? "true" : "false"
  button.textContent = isFollowing ? "Following" : "Follow"

  if (isFollowing) {
    button.classList.add("btn-outline")
    button.style.borderColor = accentColor
    button.style.color = accentColor
    button.style.backgroundColor = ""
  } else {
    button.classList.remove("btn-outline")
    button.style.backgroundColor = accentColor
    button.style.color = textColor
    button.style.borderColor = ""
  }
}

/**
 * Show success feedback on copy button
 */
function showCopySuccess(button, originalHTML) {
  button.innerHTML = ICONS.checkmark
  button.classList.add("btn-success")
  button.classList.remove("btn-primary")
  
  setTimeout(() => {
    button.innerHTML = originalHTML
    button.classList.remove("btn-success")
    button.classList.add("btn-primary")
  }, COPY_FEEDBACK_DURATION)
}

// =============================================================================
// Event Handlers
// =============================================================================

/**
 * Set up timeline drawer toggle
 */
function setupTimelineDrawer(container) {
  const drawer = container.querySelector(SELECTORS.timelineDrawer)
  const toggle = container.querySelector(SELECTORS.toggleTimelineDrawer)
  
  if (!drawer || !toggle) return
  
  const closedClasses = (drawer.dataset.closedClass || "").split(" ").filter(Boolean)
  const openClasses = (drawer.dataset.openClass || "").split(" ").filter(Boolean)

  toggle.addEventListener("click", (e) => {
    e.preventDefault()
    const isOpen = openClasses.some(cls => drawer.classList.contains(cls))
    
    if (isOpen) {
      openClasses.forEach(cls => drawer.classList.remove(cls))
      closedClasses.forEach(cls => drawer.classList.add(cls))
    } else {
      closedClasses.forEach(cls => drawer.classList.remove(cls))
      openClasses.forEach(cls => drawer.classList.add(cls))
    }
  })
}

/**
 * Set up modal close buttons
 */
function setupModalCloseButtons(followersModal, followingModal, shareModal, widgetImageModal) {
  document.querySelectorAll(SELECTORS.closeModal).forEach((button) => {
    button.addEventListener("click", () => {
      closeModal(followersModal)
      closeModal(followingModal)
    })
  })

  document.querySelectorAll(SELECTORS.closeShareModal).forEach((button) => {
    button.addEventListener("click", () => closeModal(shareModal))
  })

  document.querySelectorAll(SELECTORS.closeWidgetImage).forEach((button) => {
    button.addEventListener("click", () => closeModal(widgetImageModal))
  })
}

/**
 * Set up widget image modal for viewing images in widgets
 */
function setupWidgetImageModal(container, modal) {
  if (!modal) return
  
  const imageContent = modal.querySelector(SELECTORS.widgetImageContent)
  if (!imageContent) return
  
  // Find all widget image triggers
  container.querySelectorAll(SELECTORS.openWidgetImage).forEach((trigger) => {
    trigger.addEventListener("click", (e) => {
      e.preventDefault()
      
      const imageUrl = trigger.dataset.imageUrl
      const imageAlt = trigger.dataset.imageAlt || "Widget image"
      
      if (imageUrl) {
        imageContent.src = imageUrl
        imageContent.alt = imageAlt
        openModal(modal)
      }
    })
  })
  
  // Close on Escape key
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && modal.classList.contains("modal-open")) {
      closeModal(modal)
    }
  })
}

/**
 * Set up followers modal
 */
function setupFollowersModal(container, modal, handle) {
  const button = container.querySelector(SELECTORS.showFollowers)
  if (!button || !modal) return
  
  button.addEventListener("click", async (e) => {
    e.preventDefault()
    openModal(modal)

    try {
      const data = await fetchJson(`/profiles/${handle}/followers`)
      if (!data) return
      
      renderFollowList(
        modal.querySelector(SELECTORS.followersList),
        modal.querySelector(SELECTORS.followersEmpty),
        data.followers || []
      )
    } catch (error) {
      console.error("Failed to load followers:", error)
    }
  })
}

/**
 * Set up following modal
 */
function setupFollowingModal(container, modal, handle) {
  const button = container.querySelector(SELECTORS.showFollowing)
  if (!button || !modal) return
  
  button.addEventListener("click", async (e) => {
    e.preventDefault()
    openModal(modal)

    try {
      const data = await fetchJson(`/profiles/${handle}/following`)
      if (!data) return
      
      renderFollowList(
        modal.querySelector(SELECTORS.followingList),
        modal.querySelector(SELECTORS.followingEmpty),
        data.following || []
      )
    } catch (error) {
      console.error("Failed to load following:", error)
    }
  })
}

/**
 * Set up share modal and copy functionality
 */
function setupShareModal(container, modal) {
  const shareButton = container.querySelector(SELECTORS.showShareModal)
  if (shareButton && modal) {
    shareButton.addEventListener("click", (e) => {
      e.preventDefault()
      openModal(modal)
    })
  }

  const copyButton = document.querySelector(SELECTORS.copyProfileUrl)
  if (!copyButton) return
  
  const originalHTML = copyButton.innerHTML
  
  copyButton.addEventListener("click", async (e) => {
    e.preventDefault()
    const input = document.querySelector(SELECTORS.profileShareUrl)
    const url = input?.value
    if (!url) return
    
    try {
      await navigator.clipboard.writeText(url)
      showCopySuccess(copyButton, originalHTML)
    } catch (_) {
      // Fallback for older browsers
      if (input) {
        input.select()
        document.execCommand("copy")
        showCopySuccess(copyButton, originalHTML)
      }
    }
  })
}

/**
 * Set up follow/unfollow button
 */
function setupFollowButton(container, handle, accentColor) {
  const button = container.querySelector(SELECTORS.toggleFollow)
  if (!button) return
  
  const followersButton = container.querySelector(SELECTORS.showFollowers)
  const currentUserId = container.dataset.currentUserId
  const profileUserId = container.dataset.profileUserId
  
  // Set initial state
  updateFollowButton(button, button.dataset.following === "true", accentColor)
  
  button.addEventListener("click", async (e) => {
    e.preventDefault()
    const isFollowing = button.dataset.following === "true"
    const method = isFollowing ? "DELETE" : "POST"

    try {
      const result = await apiRequest(`/profiles/${handle}/follow`, method)
      if (!result) return
      
      updateFollowButton(button, !isFollowing, accentColor)

      // Update follower count display
      const countEl = followersButton?.querySelector("span.font-bold")
      if (countEl && currentUserId !== profileUserId) {
        const count = parseInt(countEl.textContent, 10)
        if (!Number.isNaN(count)) {
          countEl.textContent = isFollowing ? count - 1 : count + 1
        }
      }
    } catch (error) {
      console.error("Follow action failed:", error)
    }
  })
}

/**
 * Set up friend action buttons (add friend, accept, cancel, unfriend)
 */
function setupFriendActions(container, handle) {
  FRIEND_ACTIONS.forEach(({ selector, method, endpoint }) => {
    const button = container.querySelector(selector)
    if (!button) return
    
    button.addEventListener("click", async (e) => {
      e.preventDefault()
      
      try {
        const result = await apiRequest(`/profiles/${handle}/${endpoint}`, method)
        if (!result) return
        window.location.reload()
      } catch (error) {
        console.error("Friend action failed:", error)
      }
    })
  })
}

// =============================================================================
// Main Initialization
// =============================================================================

/**
 * Initialize all static profile functionality
 * 
 * This function is called on page load for static profile pages.
 * It sets up all event handlers and initializes hooks that would
 * normally be handled by LiveView.
 */
export function initProfileStatic() {
  const container = document.querySelector(SELECTORS.container)
  if (!container) return
  
  // Skip if this is a LiveView page or already initialized
  if (container.dataset.profileStatic === "false") return
  if (container.dataset.profileStaticInit === "true") return
  container.dataset.profileStaticInit = "true"

  // Initialize profile hooks (typewriter effects, video background)
  initProfileHooks()

  // Get profile data from container attributes
  const handle = container.dataset.profileHandle
  const accentColor = container.dataset.profileAccent || "#22d3ee"

  // Get modals (they're outside the container for z-index reasons)
  const followersModal = document.querySelector(SELECTORS.followersModal)
  const followingModal = document.querySelector(SELECTORS.followingModal)
  const shareModal = document.querySelector(SELECTORS.shareModal)
  const widgetImageModal = document.querySelector(SELECTORS.widgetImageModal)

  // Set up all interactive features
  setupTimelineDrawer(container)
  setupModalCloseButtons(followersModal, followingModal, shareModal, widgetImageModal)
  setupFollowersModal(container, followersModal, handle)
  setupFollowingModal(container, followingModal, handle)
  setupShareModal(container, shareModal)
  setupWidgetImageModal(container, widgetImageModal)
  setupFollowButton(container, handle, accentColor)
  setupFriendActions(container, handle)
}
