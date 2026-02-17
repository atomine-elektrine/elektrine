/**
 * Error Page Bundle
 * Lightweight JS for standalone error pages (404, 403, 413, 500).
 * These pages don't use LiveView, so they need a separate entry point.
 */

const GRID_SPACING = 40
const LIGHT_DENSITY = 0.5
const BASE_ACTIVE_RATIO = 0.02
const LIGHT_OFFSET = -1

let resizeHandler = null

// Deterministic hash for consistent "random" pattern.
function hash(x, y) {
  const n = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453
  return n - Math.floor(n)
}

function getPageHeight() {
  return window.innerHeight + 100
}

function createLights(container) {
  const width = window.innerWidth
  const height = getPageHeight()
  const cols = Math.ceil(width / GRID_SPACING) + 1
  const rows = Math.ceil(height / GRID_SPACING) + 1
  const cacheKey = `error_blinkenlights_${cols}_${rows}`

  container.innerHTML = ''

  const fragment = document.createDocumentFragment()
  let positions = []

  try {
    const cached = localStorage.getItem(cacheKey)
    if (cached) {
      positions = JSON.parse(cached)
    }
  } catch (_) {
    positions = []
  }

  if (!positions.length) {
    const generatedPositions = []
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < cols; col++) {
        if (hash(col, row) > LIGHT_DENSITY) continue
        generatedPositions.push([col * GRID_SPACING + LIGHT_OFFSET, row * GRID_SPACING + LIGHT_OFFSET])
      }
    }
    positions = generatedPositions
    try {
      localStorage.setItem(cacheKey, JSON.stringify(generatedPositions))
    } catch (_) {
      // Ignore storage errors (private mode/storage quotas).
    }
  }

  positions.forEach(([x, y], i) => {
    const light = document.createElement('div')
    light.className = 'blinkenlight'
    light.style.left = `${x}px`
    light.style.top = `${y}px`

    if (hash(i, i * 7) < BASE_ACTIVE_RATIO) {
      light.classList.add('active')
      const baseTime = hash(i * 3, i * 5)
      const duration = 2 + (baseTime * 4)
      light.style.setProperty('--blinken-duration', `${duration}s`)
      light.style.setProperty('--blinken-delay', `${hash(i * 11, i * 13) * 2}s`)
    }

    fragment.appendChild(light)
  })

  container.appendChild(fragment)
}

function initErrorBlinkenlights() {
  const container = document.getElementById('blinkenlights-container')
  if (!container) return
  if (!window.matchMedia('(pointer: fine)').matches) return

  document.body.classList.add('has-blinkenlights')
  createLights(container)

  if (!resizeHandler) {
    let resizeTimeout
    resizeHandler = () => {
      clearTimeout(resizeTimeout)
      resizeTimeout = setTimeout(() => createLights(container), 300)
    }
    window.addEventListener('resize', resizeHandler)
  }
}

// Button action handlers
function initErrorActions() {
  const goBack = document.querySelector('[data-action="go-back"]')
  if (goBack) goBack.addEventListener('click', () => history.back())

  const reload = document.querySelector('[data-action="reload-page"]')
  if (reload) reload.addEventListener('click', () => location.reload())
}

// Initialize
initErrorBlinkenlights()
initErrorActions()
