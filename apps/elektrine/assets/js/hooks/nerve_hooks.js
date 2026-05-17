/**
 * Nerve Hooks
 * Client-side encryption/decryption for zero-knowledge nerve entries.
 */

const ITERATIONS = 600000
const VERSION = 2
const ALGORITHM = "AES-GCM"
const KDF = "PBKDF2-SHA256"
const PASSWORD_LENGTH = 24
const MIN_PASSPHRASE_LENGTH = 14
const VERIFIER_TEXT = "elektrine-nerve-verifier-v1"

const encoder = new TextEncoder()
const decoder = new TextDecoder()

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

  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i)
  }

  return bytes
}

async function deriveAesKey(passphrase, salt, iterations) {
  const passphraseKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(passphrase),
    { name: "PBKDF2" },
    false,
    ["deriveKey"]
  )

  return crypto.subtle.deriveKey(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
    passphraseKey,
    { name: ALGORITHM, length: 256 },
    false,
    ["encrypt", "decrypt"]
  )
}

function stableJson(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return JSON.stringify(value)

  return JSON.stringify(
    Object.keys(value)
      .sort()
      .reduce((acc, key) => {
        acc[key] = value[key]
        return acc
      }, {})
  )
}

function aesGcmParams(iv, associatedData) {
  if (!associatedData) return { name: ALGORITHM, iv }

  return {
    name: ALGORITHM,
    iv,
    additionalData: encoder.encode(stableJson(associatedData))
  }
}

async function encryptValue(plaintext, passphrase, associatedData = null) {
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await deriveAesKey(passphrase, salt, ITERATIONS)
  const ciphertextBuffer = await crypto.subtle.encrypt(
    aesGcmParams(iv, associatedData),
    key,
    encoder.encode(plaintext)
  )

  return {
    version: VERSION,
    algorithm: ALGORITHM,
    kdf: KDF,
    iterations: ITERATIONS,
    salt: bytesToBase64(salt),
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertextBuffer))
  }
}

async function decryptValue(payload, passphrase, associatedData = null) {
  const iv = base64ToBytes(payload.iv)
  const salt = base64ToBytes(payload.salt)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const key = await deriveAesKey(passphrase, salt, payload.iterations)
  const plaintextBuffer = await crypto.subtle.decrypt(
    Number(payload.version) >= 2 ? aesGcmParams(iv, associatedData) : { name: ALGORITHM, iv },
    key,
    ciphertext
  )

  return decoder.decode(plaintextBuffer)
}

function createPassword() {
  const lowercase = "abcdefghijklmnopqrstuvwxyz"
  const uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  const digits = "0123456789"
  const symbols = "!@#$%^&*()-_=+"
  const all = lowercase + uppercase + digits + symbols

  const randomInt = (max) => {
    const values = new Uint32Array(1)
    const limit = Math.floor(0x100000000 / max) * max

    do {
      crypto.getRandomValues(values)
    } while (values[0] >= limit)

    return values[0] % max
  }

  const pick = (characters) => {
    return characters[randomInt(characters.length)]
  }

  const required = [
    pick(lowercase),
    pick(uppercase),
    pick(digits),
    pick(symbols)
  ]

  while (required.length < PASSWORD_LENGTH) {
    required.push(pick(all))
  }

  for (let i = required.length - 1; i > 0; i -= 1) {
    const swapIndex = randomInt(i + 1)
    ;[required[i], required[swapIndex]] = [required[swapIndex], required[i]]
  }

  return required.join("")
}

function parsePayload(raw) {
  if (!raw) return null

  try {
    return JSON.parse(raw)
  } catch (_error) {
    return null
  }
}

function isClientPayload(parsed) {
  return (
    parsed &&
    parsed.algorithm === ALGORITHM &&
    parsed.kdf === KDF &&
    typeof parsed.iterations === "number" &&
    typeof parsed.salt === "string" &&
    typeof parsed.iv === "string" &&
    typeof parsed.ciphertext === "string"
  )
}

function nerveEntryAssociatedData(metadata, field) {
  return {
    purpose: "elektrine-nerve-entry",
    field,
    title: (metadata.title || "").trim(),
    login_username: (metadata.login_username || "").trim(),
    website: (metadata.website || "").trim()
  }
}

function nerveMetadataAssociatedData() {
  return { purpose: "elektrine-nerve-metadata" }
}

function notify(message, type = "error", title = "Bridge") {
  if (typeof window.showNotification === "function") {
    window.showNotification(message, type, title)
  } else {
    console.error(`[Bridge] ${message}`)
  }
}

function setButtonState(button, revealed) {
  if (!button) return

  const revealLabel = button.dataset.revealLabel || "Reveal"
  const hideLabel = button.dataset.hideLabel || "Hide"
  button.textContent = revealed ? hideLabel : revealLabel
  button.dataset.revealed = revealed ? "true" : "false"
  button.classList.toggle("btn-outline", revealed)
  button.classList.toggle("btn-primary", !revealed)
}

export const Nerve = {
  mounted() {
    this.passphrase = null
    this.captureElements()
    this.bindEvents()
    this.renderLockState()
  },

  updated() {
    const wasConfigured = this.nerveConfigured
    this.captureElements()

    if (wasConfigured && !this.nerveConfigured) {
      this.clearUnlockedState()
    }

    this.renderLockState()

    if (this.passphrase) {
      this.decryptEntryMetadataRows().catch(() => null)
    }
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.onKeydown) this.el.removeEventListener("keydown", this.onKeydown)
  },

  captureElements() {
    this.nerveConfigured = this.el.dataset.nerveConfigured === "true"
    this.nerveVerifierPayload = parsePayload(this.el.dataset.nerveVerifier)
    this.form = this.el.querySelector("[data-nerve-form]")
    this.setupForm = this.el.querySelector("[data-nerve-setup-form]")
    this.setupPassphraseInput = this.el.querySelector("[data-nerve-setup-passphrase]")
    this.setupPassphraseConfirmInput = this.el.querySelector("[data-nerve-setup-passphrase-confirm]")
    this.setupEncryptedVerifierInput = this.el.querySelector("[data-nerve-setup-encrypted-verifier]")
    this.passphraseInput = this.el.querySelector("[data-nerve-passphrase-input]")
    this.status = this.el.querySelector("[data-nerve-status]")
    this.titleInput = this.el.querySelector('[name="entry[title]"]')
    this.loginUsernameInput = this.el.querySelector('[name="entry[login_username]"]')
    this.websiteInput = this.el.querySelector('[name="entry[website]"]')
    this.passwordInput = this.el.querySelector("[data-nerve-password-input]")
    this.notesInput = this.el.querySelector("[data-nerve-notes-input]")
    this.encryptedPasswordInput = this.el.querySelector("[data-nerve-encrypted-password]")
    this.encryptedNotesInput = this.el.querySelector("[data-nerve-encrypted-notes]")
    this.encryptedMetadataInput = this.el.querySelector("[data-nerve-encrypted-metadata]")
  },

  entryFormMetadata() {
    return {
      title: this.titleInput?.value || "",
      login_username: this.loginUsernameInput?.value || "",
      website: this.websiteInput?.value || ""
    }
  },

  async entryRowMetadata(entryRow) {
    const cached = parsePayload(entryRow.dataset.decryptedMetadata)
    if (cached) return cached

    const encryptedMetadata = parsePayload(entryRow.dataset.encryptedMetadata)

    if (isClientPayload(encryptedMetadata) && this.passphrase) {
      const decrypted = await decryptValue(encryptedMetadata, this.passphrase, nerveMetadataAssociatedData())
      const metadata = JSON.parse(decrypted)

      this.applyEntryRowMetadata(entryRow, metadata)
      return metadata
    }

    return {
      title: entryRow.dataset.nerveTitle || "",
      login_username: entryRow.dataset.nerveLoginUsername || "",
      website: entryRow.dataset.nerveWebsite || ""
    }
  },

  applyEntryRowMetadata(entryRow, metadata) {
    const normalized = {
      title: metadata.title || "",
      login_username: metadata.login_username || "",
      website: metadata.website || ""
    }

    entryRow.dataset.decryptedMetadata = JSON.stringify(normalized)
    entryRow.dataset.nerveTitle = normalized.title
    entryRow.dataset.nerveLoginUsername = normalized.login_username
    entryRow.dataset.nerveWebsite = normalized.website

    const titleOutput = entryRow.querySelector("[data-nerve-title-output]")
    const usernameOutput = entryRow.querySelector("[data-nerve-username-output]")
    const websiteOutput = entryRow.querySelector("[data-nerve-website-output]")

    if (titleOutput) titleOutput.textContent = normalized.title || "Encrypted entry"
    if (usernameOutput) usernameOutput.textContent = normalized.login_username || "-"
    if (websiteOutput) websiteOutput.textContent = normalized.website || "-"
  },

  bindEvents() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.onKeydown) this.el.removeEventListener("keydown", this.onKeydown)

    this.onClick = async (event) => {
      const unlockButton = event.target.closest("[data-nerve-unlock]")
      if (unlockButton) {
        event.preventDefault()
        await this.unlockNerve()
        return
      }

      const lockButton = event.target.closest("[data-nerve-lock]")
      if (lockButton) {
        event.preventDefault()
        this.lockNerve()
        return
      }

      const generateButton = event.target.closest("[data-nerve-generate]")
      if (generateButton) {
        event.preventDefault()
        this.generatePassword()
        return
      }

      const revealButton = event.target.closest("[data-nerve-reveal]")
      if (revealButton) {
        event.preventDefault()
        await this.toggleReveal(revealButton)
        return
      }

      const setupSubmitButton = event.target.closest("[data-nerve-setup-submit]")
      if (setupSubmitButton) {
        event.preventDefault()
        await this.submitSetupEncrypted()
        return
      }

      const entrySubmitButton = event.target.closest("[data-nerve-entry-submit]")
      if (entrySubmitButton) {
        event.preventDefault()
        await this.submitEncrypted()
      }
    }

    this.onKeydown = async (event) => {
      if (event.key !== "Enter") return
      if (event.target?.tagName === "TEXTAREA") return

      if (event.target.closest("[data-nerve-setup-form]")) {
        event.preventDefault()
        await this.submitSetupEncrypted()
        return
      }

      if (event.target.closest("[data-nerve-form]")) {
        event.preventDefault()
        await this.submitEncrypted()
      }
    }

    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKeydown)
  },

  async unlockNerve() {
    if (!this.nerveConfigured) {
      notify("Set up Bridge before unlocking.", "warning")
      return
    }

    const passphrase = this.passphraseInput?.value?.trim()

    if (!passphrase) {
      notify("Enter a Bridge passphrase first.", "warning")
      return
    }

    if (isClientPayload(this.nerveVerifierPayload)) {
      try {
        const verifier = await decryptValue(this.nerveVerifierPayload, passphrase)

        if (verifier !== VERIFIER_TEXT) {
          notify("Incorrect Bridge passphrase.", "error")
          return
        }
      } catch (_error) {
        notify("Incorrect Bridge passphrase.", "error")
        return
      }
    }

    this.passphrase = passphrase
    if (this.passphraseInput) this.passphraseInput.value = ""
    await this.decryptEntryMetadataRows()
    this.renderLockState()
    notify("Bridge unlocked in this browser session.", "success", "Bridge")
  },

  lockNerve() {
    this.clearUnlockedState()
    this.renderLockState()
    notify("Bridge locked.", "info", "Bridge")
  },

  clearUnlockedState() {
    this.passphrase = null
    if (this.passphraseInput) this.passphraseInput.value = ""
    this.hideAllSecrets()
  },

  renderLockState() {
    if (!this.status) return

    if (!this.nerveConfigured) {
      this.status.textContent = "Set up your Bridge passphrase to continue."
      this.status.classList.remove("text-error")
      return
    }

    if (this.passphrase) {
      this.status.textContent = "Bridge unlocked in this browser session."
      this.status.classList.remove("text-error")
    } else {
      this.status.textContent = "Bridge locked."
      this.status.classList.remove("text-error")
    }
  },

  ensureUnlocked() {
    if (!this.nerveConfigured) {
      notify("Set up Bridge first.", "warning")
      return false
    }

    if (this.passphrase) return true

    notify("Unlock Bridge before encrypting or revealing entries.", "warning")

    if (this.status) {
      this.status.textContent = "Bridge is locked."
      this.status.classList.add("text-error")
    }

    return false
  },

  generatePassword() {
    if (!this.passwordInput) return
    this.passwordInput.value = createPassword()
  },

  async submitSetupEncrypted() {
    if (
      !this.setupForm ||
      !this.setupPassphraseInput ||
      !this.setupPassphraseConfirmInput ||
      !this.setupEncryptedVerifierInput
    ) {
      return
    }

    const passphrase = this.setupPassphraseInput.value.trim()
    const confirmation = this.setupPassphraseConfirmInput.value.trim()

    if (!passphrase || passphrase.length < MIN_PASSPHRASE_LENGTH) {
      notify(`Use a Bridge passphrase with at least ${MIN_PASSPHRASE_LENGTH} characters.`, "warning")
      return
    }

    if (passphrase !== confirmation) {
      notify("Passphrase confirmation does not match.", "warning")
      return
    }

    try {
      const encryptedVerifier = await encryptValue(VERIFIER_TEXT, passphrase)
      this.setupEncryptedVerifierInput.value = JSON.stringify(encryptedVerifier)

      this.passphrase = passphrase
      this.setupPassphraseInput.value = ""
      this.setupPassphraseConfirmInput.value = ""
      this.setupForm.requestSubmit()
    } catch (_error) {
      notify("Unable to create Bridge verifier in the browser.", "error")
    }
  },

  async submitEncrypted() {
    if (!this.ensureUnlocked()) return
    if (
      !this.passwordInput ||
      !this.encryptedPasswordInput ||
      !this.encryptedNotesInput ||
      !this.encryptedMetadataInput
    ) {
      return
    }

    const password = this.passwordInput.value
    const notes = this.notesInput?.value || ""

    if (!password) {
      notify("Password is required before saving an entry.", "warning")
      return
    }

    try {
      const metadata = this.entryFormMetadata()
      const encryptedMetadata = await encryptValue(
        JSON.stringify(metadata),
        this.passphrase,
        nerveMetadataAssociatedData()
      )
      const encryptedPassword = await encryptValue(
        password,
        this.passphrase,
        nerveEntryAssociatedData(metadata, "password")
      )
      const encryptedNotes = notes
        ? await encryptValue(notes, this.passphrase, nerveEntryAssociatedData(metadata, "notes"))
        : null

      this.encryptedMetadataInput.value = JSON.stringify(encryptedMetadata)
      this.encryptedPasswordInput.value = JSON.stringify(encryptedPassword)
      this.encryptedNotesInput.value = encryptedNotes ? JSON.stringify(encryptedNotes) : ""

      // Minimize plaintext lifetime in the DOM before the LiveView submit.
      if (this.titleInput) this.titleInput.value = "Encrypted entry"
      if (this.loginUsernameInput) this.loginUsernameInput.value = ""
      if (this.websiteInput) this.websiteInput.value = ""
      this.passwordInput.value = ""
      if (this.notesInput) this.notesInput.value = ""
      this.form.requestSubmit()
    } catch (_error) {
      notify("Unable to encrypt entry in the browser.", "error")
    }
  },

  async toggleReveal(button) {
    const entryId = button.dataset.nerveReveal
    if (!entryId) return

    const entryRow = this.el.querySelector(`[data-nerve-entry-id="${entryId}"]`)
    const secretRow = this.el.querySelector(`[data-nerve-secret-row="${entryId}"]`)
    if (!entryRow || !secretRow) return

    const alreadyRevealed = button.dataset.revealed === "true"

    if (alreadyRevealed) {
      this.hideSecret(secretRow, button)
      return
    }

    if (!this.ensureUnlocked()) return

    let parsedPasswordPayload = null
    let parsedNotesPayload = null

    try {
      const payloads = await this.loadEntrySecretPayloads(entryId)
      parsedPasswordPayload = payloads.passwordPayload
      parsedNotesPayload = payloads.notesPayload
    } catch (_error) {
      notify("Entry payload is unavailable.", "error")
      return
    }

    const passwordPayload = isClientPayload(parsedPasswordPayload) ? parsedPasswordPayload : null
    const notesPayload = isClientPayload(parsedNotesPayload) ? parsedNotesPayload : null

    if (!passwordPayload) {
      notify("Entry payload is not valid client-side ciphertext.", "error")
      return
    }

    const passwordOutput = secretRow.querySelector("[data-nerve-password-output]")
    const notesOutput = secretRow.querySelector("[data-nerve-notes-output]")
    const notesWrapper = secretRow.querySelector("[data-nerve-notes-wrapper]")

    try {
      const metadata = await this.entryRowMetadata(entryRow)
      const password = await decryptValue(
        passwordPayload,
        this.passphrase,
        nerveEntryAssociatedData(metadata, "password")
      )
      const notes = notesPayload
        ? await decryptValue(
            notesPayload,
            this.passphrase,
            nerveEntryAssociatedData(metadata, "notes")
          )
        : null

      if (passwordOutput) passwordOutput.textContent = password
      if (notesOutput) notesOutput.textContent = notes || ""

      if (notesWrapper) {
        notesWrapper.classList.toggle("hidden", !notes)
      }

      secretRow.classList.remove("hidden")
      setButtonState(button, true)
    } catch (_error) {
      notify("Decryption failed. Check your Bridge passphrase.", "error")
    }
  },

  async loadEntrySecretPayloads(entryId) {
    return new Promise((resolve, reject) => {
      this.pushEvent("load_secret", { id: entryId }, (reply) => {
        if (!reply || reply.status !== "ok") {
          reject(new Error("Entry payload is unavailable."))
          return
        }

        resolve({
          passwordPayload: parsePayload(reply.encrypted_password),
          notesPayload: parsePayload(reply.encrypted_notes)
        })
      })
    })
  },

  async decryptEntryMetadataRows() {
    if (!this.passphrase) return

    const rows = Array.from(this.el.querySelectorAll("[data-nerve-entry-id]"))
    await Promise.all(rows.map((row) => this.entryRowMetadata(row).catch(() => null)))
  },

  hideSecret(secretRow, button) {
    const passwordOutput = secretRow.querySelector("[data-nerve-password-output]")
    const notesOutput = secretRow.querySelector("[data-nerve-notes-output]")
    const notesWrapper = secretRow.querySelector("[data-nerve-notes-wrapper]")

    if (passwordOutput) passwordOutput.textContent = ""
    if (notesOutput) notesOutput.textContent = ""
    if (notesWrapper) notesWrapper.classList.add("hidden")

    secretRow.classList.add("hidden")
    setButtonState(button, false)
  },

  hideAllSecrets() {
    this.el.querySelectorAll("[data-nerve-secret-row]").forEach((row) => {
      this.hideSecret(row, null)
    })

    this.el.querySelectorAll("[data-nerve-reveal]").forEach((button) => {
      setButtonState(button, false)
    })
  }
}
