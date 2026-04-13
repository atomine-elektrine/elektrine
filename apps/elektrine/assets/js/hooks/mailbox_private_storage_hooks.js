import { scryptAsync } from "@noble/hashes/scrypt"
import { submitFormPreservingEvents } from "../utils/form_submission"

const WRAP_ALGORITHM = "AES-GCM"
const VERIFY_TEXT = "elektrine-private-mailbox-v1"
const MESSAGE_AAD = new TextEncoder().encode("ElektrineMailboxStorageV1")
const ATTACHMENT_AAD = new TextEncoder().encode("ElektrineMailboxAttachmentV1")
const DEFAULT_SCRYPT = { n: 16384, r: 8, p: 1 }
const encoder = new TextEncoder()
const decoder = new TextDecoder()
const importedPrivateKeys = new Map()
const decryptedAttachments = new WeakMap()

function randomBytes(length) {
  const bytes = new Uint8Array(length)
  crypto.getRandomValues(bytes)
  return bytes
}

function bytesToBase64(bytes) {
  let binary = ""

  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte)
  })

  return btoa(binary)
}

function base64ToBytes(value) {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }

  return bytes
}

function concatBytes(first, second) {
  const combined = new Uint8Array(first.length + second.length)
  combined.set(first, 0)
  combined.set(second, first.length)
  return combined
}

function parsePayload(raw) {
  if (!raw) return null

  try {
    return JSON.parse(raw)
  } catch (_error) {
    return null
  }
}

function isValidUnlockMode(value) {
  return value === "account_password" || value === "separate_passphrase"
}

function unlockModeFromPayload(...payloads) {
  for (const payload of payloads) {
    if (!payload || typeof payload !== "object") continue

    const unlockMode = payload.unlock_mode || payload.unlockMode
    if (isValidUnlockMode(unlockMode)) {
      return unlockMode
    }
  }

  return null
}

function notify(message, type = "error", title = "Mailbox") {
  if (typeof window.showNotification === "function") {
    window.showNotification(message, type, title)
  } else {
    console.error(`[Mailbox] ${message}`)
  }
}

function cacheLoginPassword(password) {
  void password
}

function clearCachedLoginPassword() {
  return null
}

function getCachedLoginPassword() {
  return null
}

function getStoredPrivateKey(mailboxId) {
  if (!mailboxId) return null
  return importedPrivateKeys.get(mailboxId) || null
}

function storePrivateKey(mailboxId, privateKey) {
  if (!mailboxId) return
  importedPrivateKeys.set(mailboxId, privateKey)
}

function clearPrivateKey(mailboxId) {
  if (!mailboxId) return
  importedPrivateKeys.delete(mailboxId)
}

function dispatchMailboxEvent(name, mailboxId) {
  window.dispatchEvent(
    new CustomEvent(name, {
      detail: { mailboxId }
    })
  )
}

function chunkString(value, size) {
  const parts = []

  for (let index = 0; index < value.length; index += size) {
    parts.push(value.slice(index, index + size))
  }

  return parts.join("\n")
}

function bytesToPem(bytes, label) {
  const body = chunkString(bytesToBase64(bytes), 64)
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----`
}

async function deriveWrappingKey(passphrase, salt, params) {
  const keyBytes = await scryptAsync(encoder.encode(passphrase), salt, {
    N: params.n,
    r: params.r,
    p: params.p,
    dkLen: 32
  })

  return crypto.subtle.importKey("raw", keyBytes, { name: WRAP_ALGORITHM }, false, [
    "encrypt",
    "decrypt"
  ])
}

async function wrapBytes(bytes, passphrase, unlockMode = null) {
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await deriveWrappingKey(passphrase, salt, DEFAULT_SCRYPT)
  const ciphertext = await crypto.subtle.encrypt({ name: WRAP_ALGORITHM, iv }, key, bytes)

  const payload = {
    version: 1,
    algorithm: WRAP_ALGORITHM,
    kdf: "scrypt",
    n: DEFAULT_SCRYPT.n,
    r: DEFAULT_SCRYPT.r,
    p: DEFAULT_SCRYPT.p,
    salt: bytesToBase64(salt),
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext))
  }

  if (isValidUnlockMode(unlockMode)) {
    payload.unlock_mode = unlockMode
  }

  return payload
}

async function unwrapBytes(payload, passphrase) {
  const salt = base64ToBytes(payload.salt)
  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const key = await deriveWrappingKey(passphrase, salt, payload)
  const plaintext = await crypto.subtle.decrypt({ name: WRAP_ALGORITHM, iv }, key, ciphertext)
  return new Uint8Array(plaintext)
}

async function generateMailboxKeypair() {
  const keypair = await crypto.subtle.generateKey(
    {
      name: "RSA-OAEP",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256"
    },
    true,
    ["encrypt", "decrypt"]
  )

  const publicKey = new Uint8Array(await crypto.subtle.exportKey("spki", keypair.publicKey))
  const privateKey = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keypair.privateKey))

  return {
    publicKeyPem: bytesToPem(publicKey, "PUBLIC KEY"),
    privateKey
  }
}

async function importStoredPrivateKey(mailboxId) {
  return getStoredPrivateKey(mailboxId)
}

function htmlToText(html) {
  if (!html) return ""

  const doc = new DOMParser().parseFromString(html, "text/html")
  return (doc.body?.textContent || "").replace(/\s+/g, " ").trim()
}

function previewText(payload) {
  const text = (payload.text_body || htmlToText(payload.html_body || "") || "").trim()
  if (!text) return "Encrypted mailbox content"
  return text.length > 160 ? `${text.slice(0, 160)}...` : text
}

function bodyText(payload) {
  const text = (payload.text_body || "").trim()
  if (text) return text

  const htmlText = htmlToText(payload.html_body || "")
  return htmlText || "Encrypted mailbox content"
}

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

function buildSandboxedEmailHtml(content) {
  const csp = [
    "default-src 'none'",
    "img-src data: cid:",
    "media-src data: cid:",
    "style-src 'unsafe-inline'",
    "font-src data:",
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

function isRemoteUrl(value) {
  if (typeof value !== "string") return false

  const normalized = value.trim().toLowerCase()
  return normalized.startsWith("http://") || normalized.startsWith("https://") || normalized.startsWith("//")
}

function scrubSrcset(value) {
  if (typeof value !== "string") return ""

  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => {
      const [candidate] = entry.split(/\s+/, 1)
      return candidate && !isRemoteUrl(candidate) && !isDangerousUrl(candidate)
    })
    .join(", ")
}

function sanitizeProtectedHtml(content) {
  if (typeof content !== "string" || content.trim() === "") return ""

  const doc = new DOMParser().parseFromString(content, "text/html")

  doc.querySelectorAll("script, iframe, frame, frameset, object, embed, applet, form, input, textarea, select, button, meta[http-equiv], base").forEach(removeUnsafeElement)

  doc.querySelectorAll("link").forEach((element) => {
    const href = element.getAttribute("href") || ""
    if (isRemoteUrl(href) || isDangerousUrl(href)) {
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

      if (["src", "poster"].includes(name) && isRemoteUrl(value)) {
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
          .replace(/url\(\s*(['"]?)(https?:|\/\/)[^)]+\1\s*\)/gi, "none")
          .replace(/url\(\s*(['"]?)javascript:[^)]+\1\s*\)/gi, "none")
          .replace(/expression\s*\([^)]*\)/gi, "")

        if (scrubbedStyle.trim() === "") {
          element.removeAttribute(attribute.name)
        } else {
          element.setAttribute(attribute.name, scrubbedStyle)
        }
      }
    })
  })

  return doc.body?.innerHTML || ""
}

function downloadBytes(filename, contentType, data) {
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

async function decryptEnvelope(envelope, mailboxId, aad) {
  const privateKey = await importStoredPrivateKey(mailboxId)
  if (!privateKey) return null

  const wrappedKey = base64ToBytes(envelope.encrypted_key)
  const contentKeyBytes = await crypto.subtle.decrypt({ name: "RSA-OAEP" }, privateKey, wrappedKey)
  const contentKey = await crypto.subtle.importKey(
    "raw",
    contentKeyBytes,
    { name: "AES-GCM" },
    false,
    ["decrypt"]
  )

  const ciphertext = base64ToBytes(envelope.ciphertext)
  const tag = base64ToBytes(envelope.tag)
  const iv = base64ToBytes(envelope.iv)

  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv, additionalData: aad },
    contentKey,
    concatBytes(ciphertext, tag)
  )

  return JSON.parse(decoder.decode(plaintext))
}

async function decryptMessagePayload(envelope, mailboxId) {
  return decryptEnvelope(envelope, mailboxId, MESSAGE_AAD)
}

async function decryptAttachmentPayload(envelope, mailboxId) {
  return decryptEnvelope(envelope, mailboxId, ATTACHMENT_AAD)
}

async function unwrapMailboxPrivateKey(wrappedKeyPayload, verifierPayload, passphrase) {
  const verifierBytes = await unwrapBytes(verifierPayload, passphrase)
  const verifierText = decoder.decode(verifierBytes)

  if (verifierText !== VERIFY_TEXT) {
    throw new Error("invalid-passphrase")
  }

  return unwrapBytes(wrappedKeyPayload, passphrase)
}

async function unlockMailbox(mailboxId, wrappedKeyPayload, verifierPayload, passphrase) {
  const privateKeyBytes = await unwrapMailboxPrivateKey(
    wrappedKeyPayload,
    verifierPayload,
    passphrase
  )
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    privateKeyBytes,
    { name: "RSA-OAEP", hash: "SHA-256" },
    false,
    ["decrypt"]
  )
  storePrivateKey(mailboxId, privateKey)
  dispatchMailboxEvent("elektrine:private-mailbox-unlocked", mailboxId)
}

function unlockSecretLabel(unlockMode) {
  return unlockMode === "account_password" ? "account password" : "mailbox passphrase"
}

function unlockSecretPlaceholder(unlockMode) {
  return unlockMode === "account_password" ? "Account password" : "Mailbox passphrase"
}

function formatAttachmentMeta(payload, sizeOverride = null) {
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

function prefixedSubject(mode, subject) {
  const original = typeof subject === "string" ? subject.trim() : ""

  if (mode === "forward") {
    return original.startsWith("Fwd: ") ? original : `Fwd: ${original}`
  }

  return original.startsWith("Re: ") ? original : `Re: ${original}`
}

function buildReplyBody(payload, metadata) {
  const dateText = formatDateForQuote(metadata.insertedAt)
  const senderText = metadata.status === "sent" ? "you" : metadata.from

  return `\n\nOn ${dateText}, ${senderText} wrote:\n${quoteMessageBody(bodyText(payload))}\n`
}

function buildForwardBody(payload, metadata, attachments) {
  const attachmentBlock =
    attachments.length === 0
      ? ""
      : `\nAttachments:\n${attachments
          .map((attachment) => `- ${attachment.filename} (${attachment.size || 0} bytes)`)
          .join("\n")}\n`

  return `\n\n---------- Forwarded message ----------\nFrom: ${metadata.from}\nTo: ${metadata.to}\nDate: ${formatDateForQuote(metadata.insertedAt)}\nSubject: ${payload.subject || ""}${attachmentBlock}\n${bodyText(payload)}\n`
}

function maybeSetValue(field, nextValue, matcher) {
  if (!field) return

  const currentValue = field.value || ""
  const shouldReplace =
    currentValue.trim() === "" ||
    currentValue === field.dataset.privateMailboxLastApplied ||
    (typeof matcher === "function" && matcher(currentValue))

  if (!shouldReplace) return

  field.value = nextValue
  field.dataset.privateMailboxLastApplied = nextValue
}

function restoreAttachmentPlaceholder(element) {
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

export const MailboxPrivateStorage = {
  mounted() {
    this.captureElements()
    this.bindEvents()
    this.renderLockState()
    this.renderSetupModeState()
    void this.maybeAutoUnlock()
  },

  updated() {
    this.captureElements()
    this.renderLockState()
    this.renderSetupModeState()
    void this.maybeAutoUnlock()
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.onChange) this.el.removeEventListener("change", this.onChange)
  },

  captureElements() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.configured = this.el.dataset.privateMailboxConfigured === "true"
    this.wrappedKeyPayload = parsePayload(this.el.dataset.privateMailboxWrappedKey)
    this.verifierPayload = parsePayload(this.el.dataset.privateMailboxVerifier)
    const datasetUnlockMode = this.el.dataset.privateMailboxUnlockMode

    this.unlockMode =
      (isValidUnlockMode(datasetUnlockMode) ? datasetUnlockMode : null) ||
      unlockModeFromPayload(this.wrappedKeyPayload, this.verifierPayload) ||
      "separate_passphrase"
    this.statusElements = Array.from(this.el.querySelectorAll("[data-private-mailbox-status]"))
    this.lockedContentElements = Array.from(
      this.el.querySelectorAll("[data-private-mailbox-locked-content]")
    )
    this.unlockedContentElements = Array.from(
      this.el.querySelectorAll("[data-private-mailbox-unlocked-content]")
    )
    this.passphraseInput = this.el.querySelector("[data-private-mailbox-passphrase]")
    this.setupForm = this.el.querySelector("[data-private-mailbox-setup-form]")
    this.setupModeInput = this.el.querySelector("[data-private-mailbox-setup-mode]")
    this.setupAccountPasswordInput = this.el.querySelector("[data-private-mailbox-account-password]")
    this.accountPasswordFields = this.el.querySelector("[data-private-mailbox-account-password-fields]")
    this.customPassphraseFields = this.el.querySelector(
      "[data-private-mailbox-custom-passphrase-fields]"
    )
    this.setupPassphraseInput = this.el.querySelector("[data-private-mailbox-setup-passphrase]")
    this.setupConfirmInput = this.el.querySelector("[data-private-mailbox-setup-passphrase-confirm]")
    this.wrappedKeyInput = this.el.querySelector("[data-private-mailbox-wrapped-key-input]")
    this.publicKeyInput = this.el.querySelector("[data-private-mailbox-public-key-input]")
    this.verifierInput = this.el.querySelector("[data-private-mailbox-verifier-input]")
    this.autoUnlockSuppressed = this.autoUnlockSuppressed === true

    if (this.passphraseInput) {
      this.passphraseInput.placeholder = unlockSecretPlaceholder(this.unlockMode)
    }
  },

  setStatusText(text) {
    this.statusElements.forEach((element) => {
      element.textContent = text
    })
  },

  renderUnlockPanels(unlocked) {
    this.lockedContentElements.forEach((element) => {
      element.classList.toggle("hidden", unlocked)
    })

    this.unlockedContentElements.forEach((element) => {
      element.classList.toggle("hidden", !unlocked)
    })
  },

  bindEvents() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.onChange) this.el.removeEventListener("change", this.onChange)

    this.onClick = async (event) => {
      const unlockButton = event.target.closest("[data-private-mailbox-unlock]")
      if (unlockButton) {
        event.preventDefault()
        await this.handleUnlock()
        return
      }

      const lockButton = event.target.closest("[data-private-mailbox-lock]")
      if (lockButton) {
        event.preventDefault()
        this.handleLock()
        return
      }

      const setupButton = event.target.closest("[data-private-mailbox-setup-submit]")
      if (setupButton) {
        event.preventDefault()
        await this.handleSetup()
      }
    }

    this.onChange = (event) => {
      const setupMode = event.target.closest("[data-private-mailbox-setup-mode]")
      if (!setupMode) return

      this.renderSetupModeState()
    }

    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("change", this.onChange)
  },

  currentSetupMode() {
    const selectedMode = this.setupModeInput?.value

    if (isValidUnlockMode(selectedMode)) {
      return selectedMode
    }

    return "account_password"
  },

  renderSetupModeState() {
    if (this.accountPasswordFields) {
      const hidden = this.currentSetupMode() !== "account_password"
      this.accountPasswordFields.classList.toggle("hidden", hidden)

      if (this.setupAccountPasswordInput) {
        this.setupAccountPasswordInput.toggleAttribute("required", !hidden)
      }
    }

    if (this.customPassphraseFields) {
      const hidden = this.currentSetupMode() !== "separate_passphrase"
      this.customPassphraseFields.classList.toggle("hidden", hidden)

      if (this.setupPassphraseInput) {
        this.setupPassphraseInput.toggleAttribute("required", !hidden)
      }

      if (this.setupConfirmInput) {
        this.setupConfirmInput.toggleAttribute("required", !hidden)
      }
    }
  },

  renderLockState() {
    const hasUnlockedKey = this.mailboxId && getStoredPrivateKey(this.mailboxId)

    if (hasUnlockedKey) {
      this.setStatusText("Mailbox unlocked in memory for this tab.")
      this.renderUnlockPanels(true)
      return
    }

    if (!this.configured) {
      this.setStatusText("Private storage not configured.")
      this.renderUnlockPanels(false)
      return
    }

    this.setStatusText(
      this.unlockMode === "account_password"
        ? "Mailbox locked. Enter your account password again to unlock it in this tab."
        : "Mailbox locked."
    )
    this.renderUnlockPanels(false)
  },

  async maybeAutoUnlock() {
    if (
      this.autoUnlockSuppressed ||
      !this.configured ||
      !this.mailboxId ||
      !this.wrappedKeyPayload ||
      !this.verifierPayload ||
      this.unlockMode !== "account_password" ||
      getStoredPrivateKey(this.mailboxId)
    ) {
      return
    }

    const cachedPassword = getCachedLoginPassword()
    if (!cachedPassword) return

    try {
      await unlockMailbox(
        this.mailboxId,
        this.wrappedKeyPayload,
        this.verifierPayload,
        cachedPassword
      )

      if (this.passphraseInput) {
        this.passphraseInput.value = ""
      }

      this.renderLockState()
    } catch (_error) {
      clearCachedLoginPassword()
      this.renderLockState()
    }
  },

  async handleUnlock() {
    const passphrase = this.passphraseInput?.value || ""

    if (!this.mailboxId || !this.wrappedKeyPayload || !this.verifierPayload) {
      notify("Private mailbox storage is not configured yet.")
      return
    }

    if (passphrase.trim() === "") {
      notify(`Enter your ${unlockSecretLabel(this.unlockMode)} first.`)
      return
    }

    try {
      await unlockMailbox(this.mailboxId, this.wrappedKeyPayload, this.verifierPayload, passphrase)
      if (this.unlockMode === "account_password") {
        cacheLoginPassword(passphrase)
      }

      this.autoUnlockSuppressed = false
      if (this.passphraseInput) this.passphraseInput.value = ""
      this.renderLockState()
      notify("Mailbox unlocked for this tab.", "success")
    } catch (_error) {
      notify(
        `Could not unlock the mailbox. Check your ${unlockSecretLabel(this.unlockMode)} and try again.`
      )
    }
  },

  handleLock() {
    if (!this.mailboxId) return

    clearPrivateKey(this.mailboxId)
    this.autoUnlockSuppressed = true
    dispatchMailboxEvent("elektrine:private-mailbox-locked", this.mailboxId)
    if (this.passphraseInput) this.passphraseInput.value = ""
    this.renderLockState()
  },

  async handleSetup() {
    const unlockMode = this.currentSetupMode()
    const accountPassword = this.setupAccountPasswordInput?.value || ""
    const passphrase = this.setupPassphraseInput?.value || ""
    const confirmation = this.setupConfirmInput?.value || ""

    if (!this.setupForm || !this.mailboxId) {
      notify("Mailbox setup is unavailable right now.")
      return
    }

    if (unlockMode === "account_password") {
      if (accountPassword.trim() === "") {
        notify("Enter your current account password to enable private mailbox storage.")
        return
      }
    } else {
      if (passphrase.length < 12) {
        notify("Use a mailbox passphrase with at least 12 characters.")
        return
      }

      if (passphrase !== confirmation) {
        notify("Mailbox passphrase confirmation does not match.")
        return
      }
    }

    try {
      const { publicKeyPem, privateKey } = await generateMailboxKeypair()
      const wrappingSecret = unlockMode === "account_password" ? accountPassword : passphrase
      const wrappedPrivateKey = await wrapBytes(privateKey, wrappingSecret, unlockMode)
      const verifier = await wrapBytes(encoder.encode(VERIFY_TEXT), wrappingSecret, unlockMode)

      this.wrappedKeyInput.value = JSON.stringify(wrappedPrivateKey)
      this.publicKeyInput.value = publicKeyPem
      this.verifierInput.value = JSON.stringify(verifier)

      if (unlockMode === "account_password") {
        cacheLoginPassword(accountPassword)
      }

      this.setupForm.requestSubmit()
    } catch (_error) {
      notify("Could not generate mailbox keys in this browser.")
    }
  }
}

export const PrivateMailboxMessages = {
  mounted() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.onMailboxChange = () => this.renderPrivateContent()
    this.onClick = (event) => this.handleClick(event)

    window.addEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.addEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)
    this.el.addEventListener("click", this.onClick)

    this.renderPrivateContent()
  },

  updated() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.renderPrivateContent()
  },

  destroyed() {
    window.removeEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.removeEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)
    this.el.removeEventListener("click", this.onClick)
  },

  async handleClick(event) {
    const downloadButton = event.target.closest("[data-private-attachment-download]")
    if (!downloadButton) return

    event.preventDefault()

    const attachmentElement = downloadButton.closest("[data-private-attachment='true']")
    if (!attachmentElement || !this.mailboxId || !getStoredPrivateKey(this.mailboxId)) {
      notify("Unlock your mailbox before downloading protected attachments.")
      return
    }

    try {
      const payload = await this.decryptAttachmentElement(attachmentElement)
      if (!payload?.data) {
        notify("This protected attachment could not be decrypted.")
        return
      }

      downloadBytes(payload.filename, payload.content_type, payload.data)
    } catch (_error) {
      notify("Failed to decrypt this protected attachment.")
    }
  },

  async decryptAttachmentElement(element) {
    const cached = decryptedAttachments.get(element)
    if (cached) return cached

    const envelope = parsePayload(element.dataset.privateAttachmentPayload)
    if (!envelope) return null

    const payload = await decryptAttachmentPayload(envelope, this.mailboxId)
    if (payload) {
      decryptedAttachments.set(element, payload)
    }

    return payload
  },

  async renderPrivateContent() {
    const messageElements = Array.from(this.el.querySelectorAll("[data-private-message='true']"))
    const attachmentElements = Array.from(
      this.el.querySelectorAll("[data-private-attachment='true']")
    )

    if (!this.mailboxId || !getStoredPrivateKey(this.mailboxId)) {
      this.restorePlaceholders(messageElements)
      attachmentElements.forEach((element) => restoreAttachmentPlaceholder(element))
      return
    }

    await Promise.all(
      messageElements.map(async (element) => {
        const envelope = parsePayload(element.dataset.privateMessagePayload)
        if (!envelope) return

        try {
          const payload = await decryptMessagePayload(envelope, this.mailboxId)
          if (!payload) return

          const subjectEl = element.querySelector("[data-private-subject]")
          if (subjectEl) {
            const subject = typeof payload.subject === "string" ? payload.subject.trim() : ""
            subjectEl.textContent = subject || "(No Subject)"
          }

          const previewEl = element.querySelector("[data-private-preview]")
          if (previewEl) {
            previewEl.textContent = previewText(payload)
          }

          const bodyEl = element.querySelector("[data-private-body]")
          const iframe = element.querySelector("[data-private-html-body-iframe]")
          const iframeContainer = element.querySelector("[data-private-html-body-container]")

          if (bodyEl) {
            bodyEl.textContent = bodyText(payload)
          }

          if (iframe && iframeContainer && typeof payload.html_body === "string" && payload.html_body.trim() !== "") {
             iframe.srcdoc = buildSandboxedEmailHtml(sanitizeProtectedHtml(payload.html_body))
            iframeContainer.classList.remove("hidden")

            if (bodyEl) {
              bodyEl.classList.add("hidden")
            }
          } else if (iframe && iframeContainer) {
            iframe.srcdoc = ""
            iframeContainer.classList.add("hidden")

            if (bodyEl) {
              bodyEl.classList.remove("hidden")
            }
          }
        } catch (_error) {
          this.restorePlaceholderForElement(element)
        }
      })
    )

    await Promise.all(
      attachmentElements.map(async (element) => {
        try {
          const payload = await this.decryptAttachmentElement(element)
          if (!payload) return

          const filenameEl = element.querySelector("[data-private-attachment-filename]")
          if (filenameEl) {
            filenameEl.textContent = payload.filename || "attachment"
          }

          const metaEl = element.querySelector("[data-private-attachment-meta]")
          if (metaEl) {
            metaEl.textContent = formatAttachmentMeta(payload)
          }

          const labelEl = element.querySelector("[data-private-attachment-download-label]")
          if (labelEl) {
            labelEl.textContent = "Download"
          }
        } catch (_error) {
          restoreAttachmentPlaceholder(element)
        }
      })
    )
  },

  restorePlaceholders(elements) {
    elements.forEach((element) => this.restorePlaceholderForElement(element))
  },

  restorePlaceholderForElement(element) {
    const subjectEl = element.querySelector("[data-private-subject]")
    if (subjectEl && subjectEl.dataset.privateSubjectPlaceholder) {
      subjectEl.textContent = subjectEl.dataset.privateSubjectPlaceholder
    }

    const previewEl = element.querySelector("[data-private-preview]")
    if (previewEl && previewEl.dataset.privatePreviewPlaceholder) {
      previewEl.textContent = previewEl.dataset.privatePreviewPlaceholder
    }

    const bodyEl = element.querySelector("[data-private-body]")
    if (bodyEl && bodyEl.dataset.privateBodyPlaceholder) {
      bodyEl.textContent = bodyEl.dataset.privateBodyPlaceholder
      bodyEl.classList.remove("hidden")
    }

    const iframe = element.querySelector("[data-private-html-body-iframe]")
    const iframeContainer = element.querySelector("[data-private-html-body-container]")
    if (iframe && iframeContainer) {
      iframe.srcdoc = ""
      iframeContainer.classList.add("hidden")
    }
  }
}

export const PrivateMailboxCompose = {
  mounted() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.mode = this.el.dataset.privateComposeMode
    this.messageEnvelope = parsePayload(this.el.dataset.privateOriginalPayload)
    this.attachments = parsePayload(this.el.dataset.privateOriginalAttachments) || {}
    this.metadata = {
      from: this.el.dataset.privateOriginalFrom || "",
      to: this.el.dataset.privateOriginalTo || "",
      status: this.el.dataset.privateOriginalStatus || "",
      insertedAt: this.el.dataset.privateOriginalInsertedAt || ""
    }

    this.onMailboxChange = () => this.applyPrefill()
    window.addEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.addEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)

    this.applyPrefill()
  },

  updated() {
    this.applyPrefill()
  },

  destroyed() {
    window.removeEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.removeEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)
  },

  get subjectInput() {
    return document.querySelector("input[name='email[subject]']")
  },

  get hiddenBodyInput() {
    return document.querySelector("[data-private-compose-hidden-body]")
  },

  get previewElement() {
    return document.querySelector("[data-private-compose-preview]")
  },

  get privateForwardAttachmentsInput() {
    return document.querySelector("#private-forward-attachments")
  },

  get attachmentsPreview() {
    return document.querySelector("[data-private-compose-attachments-preview]")
  },

  renderLockedAttachments() {
    if (!this.attachmentsPreview || this.mode !== "forward") return

    const hasPrivateAttachments = Object.values(this.attachments).some((attachment) =>
      Boolean(attachment?.private_encrypted_payload)
    )

    if (!hasPrivateAttachments) return

    this.attachmentsPreview.innerHTML = `
      <div class="rounded border border-base-300 bg-base-200 p-3 text-sm text-base-content/70">
        Unlock the mailbox in this tab to include protected attachments in the forwarded message.
      </div>
    `
  },

  async applyPrefill() {
    if (!this.mailboxId || !this.messageEnvelope) return

    if (!getStoredPrivateKey(this.mailboxId)) {
      this.renderLockedAttachments()
      if (this.privateForwardAttachmentsInput) {
        this.privateForwardAttachmentsInput.value = ""
      }
      return
    }

    try {
      const payload = await decryptMessagePayload(this.messageEnvelope, this.mailboxId)
      if (!payload) return

      const originalSubject = typeof payload.subject === "string" ? payload.subject : ""
      const subject = prefixedSubject(this.mode, originalSubject)

      maybeSetValue(this.subjectInput, subject, (currentValue) =>
        currentValue.includes("Encrypted message")
      )

      const decryptedAttachments = await this.decryptForwardAttachments()

      const body =
        this.mode === "forward"
          ? buildForwardBody(payload, this.metadata, decryptedAttachments)
          : buildReplyBody(payload, this.metadata)

      const protectedForwardAttachments = decryptedAttachments.filter((attachment) => attachment.data)

      if (this.hiddenBodyInput) {
        this.hiddenBodyInput.value = body
      }

      if (this.previewElement) {
        this.previewElement.textContent = body
      }

      if (this.privateForwardAttachmentsInput) {
        this.privateForwardAttachmentsInput.value = JSON.stringify(protectedForwardAttachments)
      }

      this.renderForwardAttachments(decryptedAttachments)
    } catch (_error) {
      this.renderLockedAttachments()
    }
  },

  async decryptForwardAttachments() {
    const attachments = Object.values(this.attachments || {})
    if (attachments.length === 0) return []

    const decrypted = await Promise.all(
      attachments.map(async (attachment) => {
        if (!attachment?.private_encrypted_payload) {
          return {
            filename: attachment.filename || "attachment",
            content_type: attachment.content_type || "application/octet-stream",
            size: attachment.size || 0
          }
        }

        const payload = await decryptAttachmentPayload(attachment.private_encrypted_payload, this.mailboxId)

        return {
          filename: payload.filename || "attachment",
          content_type: payload.content_type || "application/octet-stream",
          size: payload.size || 0,
          encoding: payload.encoding || "base64",
          data: payload.data || ""
        }
      })
    )

    return decrypted
  },

  renderForwardAttachments(attachments) {
    if (!this.attachmentsPreview || this.mode !== "forward") return

    if (attachments.length === 0) {
      this.attachmentsPreview.innerHTML = ""
      return
    }

    this.attachmentsPreview.innerHTML = attachments
      .map(
        (attachment) => `
          <div class="flex items-center justify-between p-2 bg-base-200 rounded border border-base-300">
            <div class="flex items-center gap-2">
              <div class="text-base-content/60">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 24 24" fill="currentColor"><path d="M19.5 8.25V18A2.25 2.25 0 0 1 17.25 20.25H6.75A2.25 2.25 0 0 1 4.5 18V6A2.25 2.25 0 0 1 6.75 3.75h7.5L19.5 8.25Z"/><path d="M14.25 3.75V8.25H18.75"/></svg>
              </div>
              <div>
                <p class="text-sm font-medium">${escapeHtml(attachment.filename || "attachment")}</p>
                <p class="text-xs text-base-content/60">${escapeHtml(formatAttachmentMeta(attachment))}</p>
              </div>
            </div>
            <div class="badge badge-success badge-sm">Will be forwarded</div>
          </div>
        `
      )
      .join("")
  }
}

function bindPrivateMailboxLoginForm(form) {
  if (!form || form.dataset.privateMailboxLoginBound === "true") return

  form.addEventListener("submit", () => {
    const passwordInput = form.querySelector("input[name='user[password]']")
    const password = passwordInput?.value || ""

    if (password.trim() !== "") {
      cacheLoginPassword(password)
    }
  })

  form.dataset.privateMailboxLoginBound = "true"
}

function bindPrivateMailboxPasswordForm(form) {
  if (!form || form.dataset.privateMailboxPasswordBound === "true") return

  form.addEventListener("submit", async (event) => {
    if (form.dataset.privateMailboxRewrapSubmitting === "true") {
      return
    }

    const configured = form.dataset.privateMailboxConfigured === "true"
    const unlockMode = form.dataset.privateMailboxUnlockMode || "separate_passphrase"

    if (!configured || unlockMode !== "account_password") {
      return
    }

    const currentPassword = form.querySelector("input[name='user[current_password]']")?.value || ""
    const newPassword = form.querySelector("input[name='user[password]']")?.value || ""

    if (currentPassword.trim() === "" || newPassword.trim() === "") {
      return
    }

    const wrappedKeyPayload = parsePayload(form.dataset.privateMailboxWrappedKey)
    const verifierPayload = parsePayload(form.dataset.privateMailboxVerifier)

    if (!wrappedKeyPayload || !verifierPayload) {
      event.preventDefault()
      notify("Private mailbox rewrap data is unavailable. Reload and try again.")
      return
    }

    const wrappedKeyField = form.querySelector(
      "input[name='user[private_mailbox_wrapped_private_key]']"
    )
    const verifierField = form.querySelector("input[name='user[private_mailbox_verifier]']")
    const unlockModeField = form.querySelector("input[name='user[private_mailbox_unlock_mode]']")

    if (!wrappedKeyField || !verifierField || !unlockModeField) {
      event.preventDefault()
      notify("Private mailbox password update fields are missing. Reload and try again.")
      return
    }

    try {
      event.preventDefault()

      const privateKeyBytes = await unwrapMailboxPrivateKey(
        wrappedKeyPayload,
        verifierPayload,
        currentPassword
      )
      const nextWrappedKey = await wrapBytes(privateKeyBytes, newPassword, "account_password")
      const nextVerifier = await wrapBytes(
        encoder.encode(VERIFY_TEXT),
        newPassword,
        "account_password"
      )

      wrappedKeyField.value = JSON.stringify(nextWrappedKey)
      verifierField.value = JSON.stringify(nextVerifier)
      unlockModeField.value = "account_password"
      cacheLoginPassword(newPassword)

      form.dataset.privateMailboxRewrapSubmitting = "true"
      submitFormPreservingEvents(form)
    } catch (_error) {
      notify(
        "Could not rewrap your private mailbox with the new password. Check your current password and try again."
      )
    }
  })

  form.dataset.privateMailboxPasswordBound = "true"
}

export function initPrivateMailboxAuthForms(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === "function" ? rootCandidate : document

  root
    .querySelectorAll("[data-private-mailbox-login-form='true']")
    .forEach((form) => bindPrivateMailboxLoginForm(form))

  root
    .querySelectorAll("[data-private-mailbox-password-form='true']")
    .forEach((form) => bindPrivateMailboxPasswordForm(form))
}
