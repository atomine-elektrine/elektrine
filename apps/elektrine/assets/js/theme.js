const STORAGE_KEY = "elektrine:theme"
const VALID_THEMES = new Set(["light", "dark"])

function currentTheme() {
  const theme = document.documentElement.dataset.theme
  return VALID_THEMES.has(theme) ? theme : "light"
}

function storedTheme() {
  try {
    const theme = window.localStorage.getItem(STORAGE_KEY)
    return VALID_THEMES.has(theme) ? theme : null
  } catch (_error) {
    return null
  }
}

function systemTheme() {
  return window.matchMedia?.("(prefers-color-scheme: light)")?.matches ? "light" : "dark"
}

function customThemePreference() {
  const theme = document.documentElement.dataset.themePreference
  return VALID_THEMES.has(theme) ? theme : null
}

function syncThemeColor() {
  const themeColor = document.querySelector('meta[name="theme-color"]')
  if (!themeColor) return

  const baseColor = getComputedStyle(document.documentElement)
    .getPropertyValue("--color-base-100")
    .trim()

  if (baseColor) themeColor.setAttribute("content", baseColor)
}

export function syncThemeControls() {
  const theme = currentTheme()
  const nextTheme = theme === "light" ? "dark" : "light"
  const label = `Use ${nextTheme} theme`

  document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
    button.setAttribute("aria-label", label)
    button.setAttribute("title", label)
  })

  window.requestAnimationFrame(syncThemeColor)
}

function applyTheme(theme, persist = false) {
  const resolvedTheme = VALID_THEMES.has(theme) ? theme : "light"
  document.documentElement.dataset.theme = resolvedTheme

  if (persist) {
    try {
      window.localStorage.setItem(STORAGE_KEY, resolvedTheme)
    } catch (_error) {
      // The selected theme still applies for this page when storage is unavailable.
    }
  }

  syncThemeControls()
  window.dispatchEvent(
    new CustomEvent("elektrine:theme-changed", { detail: { theme: resolvedTheme } })
  )
}

let initialized = false

export function initThemeToggle() {
  syncThemeControls()
  if (initialized) return

  initialized = true

  const colorScheme = window.matchMedia?.("(prefers-color-scheme: light)")
  colorScheme?.addEventListener?.("change", () => {
    if (!storedTheme() && !customThemePreference()) applyTheme(systemTheme())
  })

  document.addEventListener("click", (event) => {
    const toggle = event.target.closest("[data-theme-toggle]")
    if (!toggle) return

    event.preventDefault()
    applyTheme(currentTheme() === "light" ? "dark" : "light", true)
  })
}
