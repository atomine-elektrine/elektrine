const DEFAULT_THEME_VALUES = {
  color_primary: "#5f87b8",
  color_secondary: "#c9853f",
  color_accent: "#7d99bb",
  color_base_100: "#121214",
  color_base_200: "#1a1a1d",
  color_base_300: "#2a2a31",
  color_base_content: "#e5e2e1",
  color_info: "#6f95c4",
  color_success: "#6f8b74",
  color_warning: "#c99152",
  color_error: "#a56b68"
}

const CSS_VAR_BY_THEME_KEY = {
  color_primary: "--primary",
  color_secondary: "--secondary",
  color_accent: "--accent",
  color_base_100: "--bg",
  color_base_200: "--bg-elevated",
  color_base_300: "--bg-muted",
  color_base_content: "--text",
  color_info: "--info",
  color_success: "--success",
  color_warning: "--warning",
  color_error: "--error"
}

const HEX_COLOR_PATTERN = /^#[0-9a-f]{6}$/i

export function defaultTheme() {
  return { values: { ...DEFAULT_THEME_VALUES } }
}

export function normalizeTheme(theme) {
  const values = theme?.values && typeof theme.values === "object" ? theme.values : theme

  if (!values || typeof values !== "object") {
    return null
  }

  const normalized = {}

  for (const key of Object.keys(DEFAULT_THEME_VALUES)) {
    const value = values[key]

    if (typeof value === "string" && HEX_COLOR_PATTERN.test(value.trim())) {
      normalized[key] = value.trim().toLowerCase()
    }
  }

  return { values: normalized }
}

export function applyTheme(settings = {}) {
  const signedInTheme = settings.apiToken ? normalizeTheme(settings.theme) : null
  const values = {
    ...DEFAULT_THEME_VALUES,
    ...(signedInTheme?.values || {})
  }

  for (const [themeKey, cssVar] of Object.entries(CSS_VAR_BY_THEME_KEY)) {
    document.documentElement.style.setProperty(cssVar, values[themeKey])
  }

  document.documentElement.style.setProperty("--muted", `${values.color_base_content}b3`)
  document.documentElement.style.setProperty("--muted-strong", `${values.color_base_content}db`)
}
