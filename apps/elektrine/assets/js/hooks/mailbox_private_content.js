function htmlToText(html) {
  if (!html) return ""

  const doc = new DOMParser().parseFromString(html, "text/html")
  return (doc.body?.textContent || "").replace(/\s+/g, " ").trim()
}

export function previewText(payload) {
  const text = (payload.text_body || htmlToText(payload.html_body || "") || "").trim()
  if (!text) return "Encrypted mailbox content"
  return text.length > 160 ? `${text.slice(0, 160)}...` : text
}

export function bodyText(payload) {
  const text = (payload.text_body || "").trim()
  if (text) return text

  const htmlText = htmlToText(payload.html_body || "")
  return htmlText || "Encrypted mailbox content"
}

export function payloadString(payload, field) {
  const value = payload?.[field]
  return typeof value === "string" ? value : ""
}

export function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

export function buildSandboxedEmailHtml(content) {
  const csp = [
    "default-src 'none'",
    "img-src data: cid: https:",
    "media-src data: cid: https:",
    "style-src 'unsafe-inline' https:",
    "font-src data: https:",
    "connect-src 'none'",
    "frame-src 'none'",
    "child-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'"
  ].join("; ")

  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="referrer" content="no-referrer">
  <meta http-equiv="Content-Security-Policy" content="${csp}">
  <style>
    body {
      margin: 0;
      padding: 16px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 14px;
      line-height: 1.5;
      color: #222;
      background: #fff;
      overflow-wrap: anywhere;
    }
    img {
      max-width: 100%;
      height: auto;
    }
    table {
      max-width: 100%;
    }
  </style>
</head>
<body>${content || ""}</body>
</html>`
}

const HTML_FRAGMENT_PATTERN =
  /<\/?(?:html|head|body|table|thead|tbody|tfoot|tr|th|td|div|p|span|br|a|img|style|section|article|h[1-6])\b/i
const ENCODED_HTML_FRAGMENT_PATTERN =
  /&lt;\s*(?:!doctype\b|\/?\s*(?:html|head|body|table|thead|tbody|tfoot|tr|th|td|div|p|span|br|a|img|style|section|article|h[1-6])\b)/gi

function maybeDecodeEntityEncodedHtml(content) {
  if (HTML_FRAGMENT_PATTERN.test(content)) return content

  const matches = content.match(ENCODED_HTML_FRAGMENT_PATTERN) || []
  if (matches.length < 2) return content

  const textarea = document.createElement("textarea")
  textarea.innerHTML = content
  return textarea.value
}

function removeUnsafeElement(element) {
  if (element && typeof element.remove === "function") {
    element.remove()
  }
}

function isDangerousUrl(value) {
  if (typeof value !== "string") return false

  const normalized = value.replace(/[\u0000-\u001F\u007F\s]+/g, "").toLowerCase()
  return (
    normalized.startsWith("javascript:") ||
    normalized.startsWith("vbscript:") ||
    normalized.startsWith("data:text/html")
  )
}

function scrubSrcset(value) {
  if (typeof value !== "string") return ""

  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => {
      const [candidate] = entry.split(/\s+/, 1)
      return candidate && !isDangerousUrl(candidate)
    })
    .join(", ")
}

export function sanitizeProtectedHtml(content) {
  if (typeof content !== "string" || content.trim() === "") return ""

  const doc = new DOMParser().parseFromString(
    maybeDecodeEntityEncodedHtml(content),
    "text/html"
  )

  doc
    .querySelectorAll(
      "script, iframe, frame, frameset, object, embed, applet, form, input, textarea, select, button, meta[http-equiv], base"
    )
    .forEach(removeUnsafeElement)

  doc.querySelectorAll("link").forEach((element) => {
    const href = element.getAttribute("href") || ""
    const rel = (element.getAttribute("rel") || "").toLowerCase()
    const blockedRel =
      /(?:^|\s)(?:dns-prefetch|import|modulepreload|preconnect|prefetch|preload)(?:\s|$)/.test(
        rel
      )

    if (isDangerousUrl(href) || blockedRel) {
      removeUnsafeElement(element)
    }
  })

  doc.querySelectorAll("*").forEach((element) => {
    Array.from(element.attributes).forEach((attribute) => {
      const name = attribute.name.toLowerCase()
      const value = attribute.value || ""

      if (name.startsWith("on")) {
        element.removeAttribute(attribute.name)
        return
      }

      if ((name === "src" || name === "href" || name === "poster") && isDangerousUrl(value)) {
        element.removeAttribute(attribute.name)
        return
      }

      if (name === "srcset") {
        const scrubbed = scrubSrcset(value)
        if (scrubbed) {
          element.setAttribute(attribute.name, scrubbed)
        } else {
          element.removeAttribute(attribute.name)
        }
        return
      }

      if (name === "style") {
        const scrubbedStyle = value
          .replace(/url\(\s*(['"]?)\s*javascript\s*:[^;>]*\1\s*\)/gi, "none")
          .replace(/url\(\s*(['"]?)\s*vbscript\s*:[^;>]*\1\s*\)/gi, "none")
          .replace(/url\(\s*(['"]?)\s*data\s*:\s*text\/html[^;>]*\1\s*\)/gi, "none")
          .replace(/expression\s*\([^)]*\)/gi, "")

        if (scrubbedStyle.trim() === "") {
          element.removeAttribute(attribute.name)
        } else {
          element.setAttribute(attribute.name, scrubbedStyle)
        }
      }
    })
  })

  const headStyles = Array.from(doc.head?.querySelectorAll("style") || [])
    .map((element) => element.outerHTML)
    .join("\n")

  return [headStyles, doc.body?.innerHTML || ""].filter(Boolean).join("\n")
}

export function downloadBytes(filename, contentType, data) {
  const binaryString = atob(data)
  const bytes = new Uint8Array(binaryString.length)

  for (let index = 0; index < binaryString.length; index += 1) {
    bytes[index] = binaryString.charCodeAt(index)
  }

  const blob = new Blob([bytes], { type: contentType || "application/octet-stream" })
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")

  link.href = url
  link.download = filename || "attachment"
  link.style.display = "none"
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

function formatBytes(size) {
  const value = Number(size || 0)
  if (value < 1024) return `${value} bytes`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

export function formatAttachmentMeta(payload, sizeOverride = null) {
  const size = Number.isFinite(sizeOverride) ? sizeOverride : payload.size || 0
  const formattedSize = formatBytes(Math.max(size, 0))
  return `${formattedSize} • ${payload.content_type || "application/octet-stream"}`
}

function formatDateForQuote(rawValue) {
  const value = rawValue ? new Date(rawValue) : null
  if (!value || Number.isNaN(value.getTime())) return ""

  return value.toLocaleString(undefined, {
    weekday: "short",
    month: "short",
    day: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  })
}

function quoteMessageBody(body) {
  return (body || "")
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n")
}

export function prefixedSubject(mode, subject) {
  const original = typeof subject === "string" ? subject.trim() : ""

  if (mode === "forward") {
    return original.startsWith("Fwd: ") ? original : `Fwd: ${original}`
  }

  return original.startsWith("Re: ") ? original : `Re: ${original}`
}

export function buildReplyBody(payload, metadata) {
  const dateText = formatDateForQuote(metadata.insertedAt)
  const senderText = metadata.status === "sent" ? "you" : metadata.from

  return `\n\nOn ${dateText}, ${senderText} wrote:\n${quoteMessageBody(bodyText(payload))}\n`
}

export function buildForwardBody(payload, metadata, attachments) {
  const attachmentBlock =
    attachments.length === 0
      ? ""
      : `\nAttachments:\n${attachments
          .map((attachment) => `- ${attachment.filename} (${attachment.size || 0} bytes)`)
          .join("\n")}\n`

  return `\n\n---------- Forwarded message ----------\nFrom: ${metadata.from}\nTo: ${metadata.to}\nDate: ${formatDateForQuote(metadata.insertedAt)}\nSubject: ${payload.subject || ""}${attachmentBlock}\n${bodyText(payload)}\n`
}

export function restoreAttachmentPlaceholder(element) {
  const filenameEl = element.querySelector("[data-private-attachment-filename]")
  if (filenameEl?.dataset.privateAttachmentFilenamePlaceholder) {
    filenameEl.textContent = filenameEl.dataset.privateAttachmentFilenamePlaceholder
  }

  const metaEl = element.querySelector("[data-private-attachment-meta]")
  if (metaEl?.dataset.privateAttachmentMetaPlaceholder) {
    metaEl.textContent = metaEl.dataset.privateAttachmentMetaPlaceholder
  }

  const labelEl = element.querySelector("[data-private-attachment-download-label]")
  if (labelEl?.dataset.privateAttachmentDownloadLabelPlaceholder) {
    labelEl.textContent = labelEl.dataset.privateAttachmentDownloadLabelPlaceholder
  }
}
