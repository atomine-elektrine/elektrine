/**
 * Error Page Bundle
 * Lightweight JS for standalone error pages (404, 403, 413, 500).
 * These pages don't use LiveView, so they need a separate entry point.
 */

// Simple blinkenlights for error pages
function initErrorBlinkenlights() {
  const container = document.getElementById('blinkenlights-container')
  if (!container) return
  if (!window.matchMedia('(pointer: fine)').matches) return

  const spacing = 30
  const density = 0.5
  const fragment = document.createDocumentFragment()

  const w = window.innerWidth
  const h = window.innerHeight
  const cols = Math.ceil(w / spacing) + 1
  const rows = Math.ceil(h / spacing) + 1

  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      if (Math.random() > density) continue
      const light = document.createElement('div')
      light.className = 'blinkenlight'
      light.style.left = (c * spacing) + 'px'
      light.style.top = (r * spacing) + 'px'
      if (Math.random() < 0.15) {
        light.classList.add('active')
        light.style.setProperty('--duration', (2 + Math.random() * 4) + 's')
        light.style.setProperty('--delay', (Math.random() * 2) + 's')
      }
      fragment.appendChild(light)
    }
  }

  container.appendChild(fragment)
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
