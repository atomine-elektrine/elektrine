const STORAGE_KEY = "elektrine:theme"
const VALID_THEMES = new Set(["light", "dark"])
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

function applyThemeOverrides({ style = "", preference = "system" } = {}) {
  const root = document.documentElement
  const parsedStyle = document.createElement("div").style
  parsedStyle.cssText = typeof style === "string" ? style : ""

  THEME_OVERRIDE_PROPERTIES.forEach((property) => {
    root.style.removeProperty(property)

    const value = parsedStyle.getPropertyValue(property).trim()
    if (value) root.style.setProperty(property, value)
  })

  root.dataset.themePreference = VALID_THEMES.has(preference) ? preference : "system"
  applyTheme(storedTheme() || customThemePreference() || systemTheme())
}

let initialized = false

export function initThemeToggle() {
  syncThemeControls()
  if (initialized) return

  initialized = true

  window.addEventListener("phx:apply-theme-overrides", (event) => {
    applyThemeOverrides(event.detail)
  })

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
