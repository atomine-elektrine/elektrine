const STORAGE_KEY = "elektrine:theme"
const VALID_THEMES = new Set(["light", "dark"])
const VALID_MODES = new Set(["system", "light", "dark", "custom"])
const THEME_OVERRIDE_PROPERTIES = [
  "--theme-override-color-primary",
  "--theme-override-color-primary-content",
  "--theme-override-color-secondary",
  "--theme-override-color-secondary-content",
  "--theme-override-color-accent",
  "--theme-override-color-accent-content",
  "--theme-override-color-base-100",
  "--theme-override-color-base-200",
  "--theme-override-color-base-300",
  "--theme-override-color-base-content",
  "--theme-override-color-info",
  "--theme-override-color-info-content",
  "--theme-override-color-success",
  "--theme-override-color-success-content",
  "--theme-override-color-warning",
  "--theme-override-color-warning-content",
  "--theme-override-color-error",
  "--theme-override-color-error-content"
]

function currentTheme() {
  const theme = document.documentElement.dataset.theme
  return VALID_THEMES.has(theme) ? theme : "light"
}

// The server-stored mode for signed-in users; absent for anonymous visitors,
// whose light/dark choice lives in localStorage instead.
function themeMode() {
  const mode = document.documentElement.dataset.themeMode
  return VALID_MODES.has(mode) ? mode : null
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

function resolveTheme() {
  const mode = themeMode()
  if (mode === "light" || mode === "dark") return mode
  if (mode === "custom") return currentTheme()
  if (mode === "system") return systemTheme()
  return storedTheme() || systemTheme()
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

function persistThemeMode(mode) {
  const csrfToken =
    document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

  fetch("/api/preferences/theme", {
    method: "PUT",
    headers: { "content-type": "application/json", "x-csrf-token": csrfToken },
    body: JSON.stringify({ mode })
  }).catch(() => {
    // The theme still applies for this page; the preference syncs on the next save.
  })
}

function clearOverrideProperties() {
  THEME_OVERRIDE_PROPERTIES.forEach((property) => {
    document.documentElement.style.removeProperty(property)
  })
}

function applyThemeSettings({ style = "", mode = "system", theme = null } = {}) {
  const root = document.documentElement
  const parsedStyle = document.createElement("div").style
  parsedStyle.cssText = typeof style === "string" ? style : ""

  clearOverrideProperties()

  THEME_OVERRIDE_PROPERTIES.forEach((property) => {
    const value = parsedStyle.getPropertyValue(property).trim()
    if (value) root.style.setProperty(property, value)
  })

  root.dataset.themeMode = VALID_MODES.has(mode) ? mode : "system"
  applyTheme(VALID_THEMES.has(theme) ? theme : resolveTheme())
}

let initialized = false

export function initThemeToggle() {
  syncThemeControls()
  if (initialized) return

  initialized = true

  window.addEventListener("phx:apply-theme-settings", (event) => {
    applyThemeSettings(event.detail)
  })

  const colorScheme = window.matchMedia?.("(prefers-color-scheme: light)")
  colorScheme?.addEventListener?.("change", () => {
    const mode = themeMode()
    if (mode === "system" || (!mode && !storedTheme())) applyTheme(systemTheme())
  })

  document.addEventListener("click", (event) => {
    const toggle = event.target.closest("[data-theme-toggle]")
    if (!toggle) return

    event.preventDefault()
    const nextTheme = currentTheme() === "light" ? "dark" : "light"

    if (themeMode()) {
      // Signed in: the toggle pins an explicit day/night mode server-side,
      // moving off system or custom.
      if (themeMode() === "custom") clearOverrideProperties()
      document.documentElement.dataset.themeMode = nextTheme
      applyTheme(nextTheme)
      persistThemeMode(nextTheme)
    } else {
      applyTheme(nextTheme, true)
    }
  })
}
