/**
 * Password Manager Hooks
 * Client-side encryption/decryption for zero-knowledge vault entries.
 */

const ITERATIONS = 210000
const VERSION = 1
const ALGORITHM = "AES-GCM"
const KDF = "PBKDF2-SHA256"
const PASSWORD_LENGTH = 24
const VERIFIER_TEXT = "elektrine-vault-verifier-v1"

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

async function encryptValue(plaintext, passphrase) {
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await deriveAesKey(passphrase, salt, ITERATIONS)
  const ciphertextBuffer = await crypto.subtle.encrypt(
    { name: ALGORITHM, iv },
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

async function decryptValue(payload, passphrase) {
  const iv = base64ToBytes(payload.iv)
  const salt = base64ToBytes(payload.salt)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const key = await deriveAesKey(passphrase, salt, payload.iterations)
  const plaintextBuffer = await crypto.subtle.decrypt(
    { name: ALGORITHM, iv },
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

  const required = [
    lowercase[Math.floor(Math.random() * lowercase.length)],
    uppercase[Math.floor(Math.random() * uppercase.length)],
    digits[Math.floor(Math.random() * digits.length)],
    symbols[Math.floor(Math.random() * symbols.length)]
  ]

  while (required.length < PASSWORD_LENGTH) {
    required.push(all[Math.floor(Math.random() * all.length)])
  }

  return required
    .sort(() => Math.random() - 0.5)
    .join("")
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

function isLegacyServerPayload(parsed) {
  return (
    parsed &&
    typeof parsed.encrypted_data === "string" &&
    typeof parsed.iv === "string" &&
    typeof parsed.tag === "string"
  )
}

function notify(message, type = "error", title = "Vault") {
  if (typeof window.showNotification === "function") {
    window.showNotification(message, type, title)
  } else {
    console.error(`[Vault] ${message}`)
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

export const PasswordVault = {
  mounted() {
    this.passphrase = null
    this.captureElements()
    this.bindEvents()
    this.renderLockState()
  },

  updated() {
    const wasConfigured = this.vaultConfigured
    this.captureElements()

    if (wasConfigured && !this.vaultConfigured) {
      this.clearUnlockedState()
    }

    this.renderLockState()
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.onKeydown) this.el.removeEventListener("keydown", this.onKeydown)
  },

  captureElements() {
    this.vaultConfigured = this.el.dataset.vaultConfigured === "true"
    this.vaultVerifierPayload = parsePayload(this.el.dataset.vaultVerifier)
    this.form = this.el.querySelector("[data-vault-form]")
    this.setupForm = this.el.querySelector("[data-vault-setup-form]")
    this.setupPassphraseInput = this.el.querySelector("[data-vault-setup-passphrase]")
    this.setupPassphraseConfirmInput = this.el.querySelector("[data-vault-setup-passphrase-confirm]")
    this.setupEncryptedVerifierInput = this.el.querySelector("[data-vault-setup-encrypted-verifier]")
    this.passphraseInput = this.el.querySelector("[data-vault-passphrase-input]")
    this.status = this.el.querySelector("[data-vault-status]")
    this.passwordInput = this.el.querySelector("[data-vault-password-input]")
    this.notesInput = this.el.querySelector("[data-vault-notes-input]")
    this.encryptedPasswordInput = this.el.querySelector("[data-vault-encrypted-password]")
    this.encryptedNotesInput = this.el.querySelector("[data-vault-encrypted-notes]")
  },

  bindEvents() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.onKeydown) this.el.removeEventListener("keydown", this.onKeydown)

    this.onClick = async (event) => {
      const unlockButton = event.target.closest("[data-vault-unlock]")
      if (unlockButton) {
        event.preventDefault()
        await this.unlockVault()
        return
      }

      const lockButton = event.target.closest("[data-vault-lock]")
      if (lockButton) {
        event.preventDefault()
        this.lockVault()
        return
      }

      const generateButton = event.target.closest("[data-vault-generate]")
      if (generateButton) {
        event.preventDefault()
        this.generatePassword()
        return
      }

      const revealButton = event.target.closest("[data-vault-reveal]")
      if (revealButton) {
        event.preventDefault()
        await this.toggleReveal(revealButton)
        return
      }

      const setupSubmitButton = event.target.closest("[data-vault-setup-submit]")
      if (setupSubmitButton) {
        event.preventDefault()
        await this.submitSetupEncrypted()
        return
      }

      const entrySubmitButton = event.target.closest("[data-vault-entry-submit]")
      if (entrySubmitButton) {
        event.preventDefault()
        await this.submitEncrypted()
      }
    }

    this.onKeydown = async (event) => {
      if (event.key !== "Enter") return
      if (event.target?.tagName === "TEXTAREA") return

      if (event.target.closest("[data-vault-setup-form]")) {
        event.preventDefault()
        await this.submitSetupEncrypted()
        return
      }

      if (event.target.closest("[data-vault-form]")) {
        event.preventDefault()
        await this.submitEncrypted()
      }
    }

    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKeydown)
  },

  async unlockVault() {
    if (!this.vaultConfigured) {
      notify("Set up your vault before unlocking.", "warning")
      return
    }

    const passphrase = this.passphraseInput?.value?.trim()

    if (!passphrase) {
      notify("Enter a vault passphrase first.", "warning")
      return
    }

    if (isClientPayload(this.vaultVerifierPayload)) {
      try {
        const verifier = await decryptValue(this.vaultVerifierPayload, passphrase)

        if (verifier !== VERIFIER_TEXT) {
          notify("Incorrect vault passphrase.", "error")
          return
        }
      } catch (_error) {
        notify("Incorrect vault passphrase.", "error")
        return
      }
    }

    this.passphrase = passphrase
    if (this.passphraseInput) this.passphraseInput.value = ""
    this.renderLockState()
    notify("Vault unlocked in this browser session.", "success", "Vault")
  },

  lockVault() {
    this.clearUnlockedState()
    this.renderLockState()
    notify("Vault locked.", "info", "Vault")
  },

  clearUnlockedState() {
    this.passphrase = null
    if (this.passphraseInput) this.passphraseInput.value = ""
    this.hideAllSecrets()
  },

  renderLockState() {
    if (!this.status) return

    if (!this.vaultConfigured) {
      this.status.textContent = "Set up your vault passphrase to continue."
      this.status.classList.remove("text-error")
      return
    }

    if (this.passphrase) {
      this.status.textContent = "Vault unlocked in this browser session."
      this.status.classList.remove("text-error")
    } else {
      this.status.textContent = "Vault locked."
      this.status.classList.remove("text-error")
    }
  },

  ensureUnlocked() {
    if (!this.vaultConfigured) {
      notify("Set up your vault first.", "warning")
      return false
    }

    if (this.passphrase) return true

    notify("Unlock your vault before encrypting or revealing entries.", "warning")

    if (this.status) {
      this.status.textContent = "Vault is locked."
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

    if (!passphrase || passphrase.length < 8) {
      notify("Use a vault passphrase with at least 8 characters.", "warning")
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
      notify("Unable to create vault verifier in the browser.", "error")
    }
  },

  async submitEncrypted() {
    if (!this.ensureUnlocked()) return
    if (!this.passwordInput || !this.encryptedPasswordInput || !this.encryptedNotesInput) return

    const password = this.passwordInput.value
    const notes = this.notesInput?.value || ""

    if (!password) {
      notify("Password is required before saving an entry.", "warning")
      return
    }

    try {
      const encryptedPassword = await encryptValue(password, this.passphrase)
      const encryptedNotes = notes ? await encryptValue(notes, this.passphrase) : null

      this.encryptedPasswordInput.value = JSON.stringify(encryptedPassword)
      this.encryptedNotesInput.value = encryptedNotes ? JSON.stringify(encryptedNotes) : ""

      // Minimize plaintext lifetime in the DOM before the LiveView submit.
      this.passwordInput.value = ""
      if (this.notesInput) this.notesInput.value = ""
      this.form.requestSubmit()
    } catch (_error) {
      notify("Unable to encrypt entry in the browser.", "error")
    }
  },

  async toggleReveal(button) {
    const entryId = button.dataset.vaultReveal
    if (!entryId) return

    const entryRow = this.el.querySelector(`[data-vault-entry-id="${entryId}"]`)
    const secretRow = this.el.querySelector(`[data-vault-secret-row="${entryId}"]`)
    if (!entryRow || !secretRow) return

    const alreadyRevealed = button.dataset.revealed === "true"

    if (alreadyRevealed) {
      this.hideSecret(secretRow, button)
      return
    }

    if (!this.ensureUnlocked()) return

    const parsedPasswordPayload = parsePayload(entryRow.dataset.encryptedPassword)
    const parsedNotesPayload = parsePayload(entryRow.dataset.encryptedNotes)

    if (isLegacyServerPayload(parsedPasswordPayload)) {
      notify("This is a legacy vault entry. Re-save it to migrate to zero-knowledge mode.", "warning")
      return
    }

    const passwordPayload = isClientPayload(parsedPasswordPayload) ? parsedPasswordPayload : null
    const notesPayload = isClientPayload(parsedNotesPayload) ? parsedNotesPayload : null

    if (!passwordPayload) {
      notify("Entry payload is not valid client-side ciphertext.", "error")
      return
    }

    const passwordOutput = secretRow.querySelector("[data-vault-password-output]")
    const notesOutput = secretRow.querySelector("[data-vault-notes-output]")
    const notesWrapper = secretRow.querySelector("[data-vault-notes-wrapper]")

    try {
      const password = await decryptValue(passwordPayload, this.passphrase)
      const notes = notesPayload ? await decryptValue(notesPayload, this.passphrase) : null

      if (passwordOutput) passwordOutput.textContent = password
      if (notesOutput) notesOutput.textContent = notes || ""

      if (notesWrapper) {
        notesWrapper.classList.toggle("hidden", !notes)
      }

      secretRow.classList.remove("hidden")
      setButtonState(button, true)
    } catch (_error) {
      notify("Decryption failed. Check your vault passphrase.", "error")
    }
  },

  hideSecret(secretRow, button) {
    const passwordOutput = secretRow.querySelector("[data-vault-password-output]")
    const notesOutput = secretRow.querySelector("[data-vault-notes-output]")
    const notesWrapper = secretRow.querySelector("[data-vault-notes-wrapper]")

    if (passwordOutput) passwordOutput.textContent = ""
    if (notesOutput) notesOutput.textContent = ""
    if (notesWrapper) notesWrapper.classList.add("hidden")

    secretRow.classList.add("hidden")
    setButtonState(button, false)
  },

  hideAllSecrets() {
    this.el.querySelectorAll("[data-vault-secret-row]").forEach((row) => {
      this.hideSecret(row, null)
    })

    this.el.querySelectorAll("[data-vault-reveal]").forEach((button) => {
      setButtonState(button, false)
    })
  }
}
