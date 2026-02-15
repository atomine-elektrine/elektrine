// Blinkenlights - Functional status lights that respond to system activity
// Inspired by mainframe front panels - lights indicate actual system activity

let container = null
let lights = []
let resizeHandler = null
let activityLevel = 0  // 0 = idle, 1 = light activity, 2 = moderate, 3 = heavy
let sitePopularity = 0 // 0-100 based on active users

const GRID_SPACING = 30
const LIGHT_DENSITY = 0.5
const COLORS = ['color-red', 'color-green', 'color-blue', 'color-amber', 'color-purple']

// Deterministic hash for consistent "random" pattern
function hash(x, y) {
  const n = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453
  return n - Math.floor(n)
}

export function initBlinkenlights() {
  const path = window.location.pathname
  const showOnPages = ['/']

  if (!showOnPages.some(p => path === p || path.startsWith(p + '/'))) {
    destroyBlinkenlights()
    return
  }

  if (container) return
  if (!window.matchMedia('(pointer: fine)').matches) return

  document.body.classList.add('has-blinkenlights')

  container = document.createElement('div')
  container.id = 'blinkenlights-container'
  document.body.insertBefore(container, document.body.firstChild)

  createLights()

  let resizeTimeout
  resizeHandler = () => {
    clearTimeout(resizeTimeout)
    resizeTimeout = setTimeout(createLights, 300)
  }
  window.addEventListener('resize', resizeHandler)

  // Listen for site popularity updates
  window.addEventListener('phx:site-activity', handleSiteActivity)
  window.addEventListener('site:activity', handleSiteActivity)
}

function handleSiteActivity(event) {
  const activeUsers = event.detail?.active_users || 0
  const recentActions = event.detail?.recent_actions || 0

  // Calculate popularity (0-100) based on users and activity
  sitePopularity = Math.min(100, activeUsers * 5 + recentActions)

  // Update activity on existing lights (don't rebuild grid to avoid visual shift)
  updateActivityLights()

  // Flash some lights for recent actions
  if (recentActions > 0) {
    flashLights(Math.min(recentActions, 10), 'action')
  }
}

function setActivityLevel(level) {
  activityLevel = level
  updateActivityLights()
}

function updateActivityLights() {
  if (!lights.length) return

  // Base ratio from activity level
  const baseRatio = [0.02, 0.08, 0.15, 0.3][activityLevel] || 0.02

  // Add popularity bonus (0-100 maps to 0-0.3 additional ratio)
  const popularityBonus = (sitePopularity / 100) * 0.3

  // Combined ratio (cap at 0.6 so not every light is on)
  const activeRatio = Math.min(0.6, baseRatio + popularityBonus)

  lights.forEach((light, i) => {
    light.classList.remove('active', 'finding', 'action')

    // Deterministic activation based on light index
    if (hash(i, i * 7) < activeRatio) {
      light.classList.add('active')
      // Deterministic timing based on index
      const speedFactor = 1 - (sitePopularity / 200)
      const baseTime = hash(i * 3, i * 5)
      const duration = activityLevel >= 2 ? 0.5 + baseTime * 1.5 : (2 + baseTime * 4) * speedFactor
      light.style.setProperty('--blinken-duration', `${duration}s`)
      light.style.setProperty('--blinken-delay', `${hash(i * 11, i * 13) * 2}s`)
    }
  })
}

function flashLights(count, type = 'pulse') {
  if (!lights.length) return

  // Flash random lights briefly
  const toFlash = []
  for (let i = 0; i < count && i < lights.length; i++) {
    const idx = Math.floor(Math.random() * lights.length)
    toFlash.push(lights[idx])
  }

  toFlash.forEach(light => {
    light.classList.add(type)
    setTimeout(() => light.classList.remove(type), 300 + Math.random() * 400)
  })
}

function getPageHeight() {
  // Use viewport height + extra buffer to ensure lights reach the bottom
  return window.innerHeight + 100
}

function createLights() {
  if (!container) return

  const width = window.innerWidth
  const height = getPageHeight()
  const cols = Math.ceil(width / GRID_SPACING) + 1
  const rows = Math.ceil(height / GRID_SPACING) + 1
  const cacheKey = `blinkenlights_${cols}_${rows}`

  // Check cache for this viewport size
  const cached = localStorage.getItem(cacheKey)
  if (cached && container.dataset.cacheKey === cacheKey) {
    // Already showing correct grid
    return
  }

  container.innerHTML = ''
  lights = []
  container.dataset.cacheKey = cacheKey

  const fragment = document.createDocumentFragment()
  const positions = cached ? JSON.parse(cached) : []

  if (positions.length > 0) {
    // Restore from cache
    positions.forEach(([x, y]) => {
      const light = document.createElement('div')
      light.className = 'blinkenlight'
      light.style.left = `${x}px`
      light.style.top = `${y}px`
      fragment.appendChild(light)
      lights.push(light)
    })
  } else {
    // Generate and cache
    const newPositions = []
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < cols; col++) {
        if (hash(col, row) > LIGHT_DENSITY) continue

        const x = col * GRID_SPACING
        const y = row * GRID_SPACING
        newPositions.push([x, y])

        const light = document.createElement('div')
        light.className = 'blinkenlight'
        light.style.left = `${x}px`
        light.style.top = `${y}px`
        fragment.appendChild(light)
        lights.push(light)
      }
    }
    localStorage.setItem(cacheKey, JSON.stringify(newPositions))
  }

  container.appendChild(fragment)
  updateActivityLights()
}

export function destroyBlinkenlights() {
  if (resizeHandler) {
    window.removeEventListener('resize', resizeHandler)
    resizeHandler = null
  }
  window.removeEventListener('phx:site-activity', handleSiteActivity)
  window.removeEventListener('site:activity', handleSiteActivity)

  if (container && container.parentNode) {
    container.parentNode.removeChild(container)
    container = null
    lights = []
  }
  document.body.classList.remove('has-blinkenlights')
}

export function checkBlinkenlights() {
  const path = window.location.pathname
  const showOnPages = ['/']

  if (showOnPages.some(p => path === p || path.startsWith(p + '/'))) {
    if (!container) initBlinkenlights()
  } else {
    destroyBlinkenlights()
  }
}

// Expose API for manual control
window.blinkenlights = {
  flash: (count = 5, type = 'pulse') => flashLights(count, type),
  setActivity: (level) => setActivityLevel(level),
  setPopularity: (level) => { sitePopularity = Math.min(100, Math.max(0, level)); updateActivityLights() },
  finding: () => flashLights(8, 'finding'),
  action: () => flashLights(3, 'action'),
  simulate: (users) => handleSiteActivity({ detail: { active_users: users, recent_actions: Math.floor(users / 2) }})
}
