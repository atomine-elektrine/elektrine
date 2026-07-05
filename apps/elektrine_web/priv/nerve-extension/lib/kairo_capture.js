export function kairoSourceAttrs(capture) {
  const selectedText = normalizeSelection(capture.selectionText)
  const capturedAt = new Date().toISOString()
  const url = capture.url || ""
  const pageTitle = (capture.title || safeHost(url) || "Captured page").trim()

  if (selectedText) {
    return {
      source_type: "text",
      title: `Selection from ${pageTitle}`,
      url,
      content: selectedText,
      content_format: "text",
      tags: ["capture", "browser-extension"],
      metadata: {
        capture_type: "selection",
        captured_at: capturedAt,
        page_title: pageTitle,
        source: "nerve-extension"
      }
    }
  }

  return {
    source_type: "url",
    title: pageTitle,
    url,
    tags: ["capture", "browser-extension"],
    metadata: {
      capture_type: "page",
      captured_at: capturedAt,
      source: "nerve-extension"
    }
  }
}

export function kairoErrorMessage(error) {
  const message = error?.message || "Could not capture to Kairo."

  if (/scope|forbidden|unauthorized|write:kairo|403|401/i.test(message)) {
    return "Reconnect the extension in settings so it can capture to Kairo."
  }

  return message
}

function normalizeSelection(value) {
  return String(value || "").replace(/\s+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim()
}

function safeHost(value) {
  try {
    const url = new URL(value)
    return ["http:", "https:"].includes(url.protocol) ? url.hostname : ""
  } catch (_error) {
    return ""
  }
}
