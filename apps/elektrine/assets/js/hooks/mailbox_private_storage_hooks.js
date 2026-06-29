import { scryptAsync } from "@noble/hashes/scrypt.js"
import { unwrapWithSecret } from "./vault_crypto"
import * as vaultSession from "./vault_session"

const MASTER_MODE = "master"
const MASTER_FEATURE = "email"
const WRAP_ALGORITHM = "AES-GCM"
export const VERIFY_TEXT = "elektrine-private-mailbox-v1"
const MESSAGE_AAD = new TextEncoder().encode("ElektrineMailboxStorageV1")
const ATTACHMENT_AAD = new TextEncoder().encode("ElektrineMailboxAttachmentV1")
const DEFAULT_SCRYPT = { n: 16384, r: 8, p: 1 }
export const encoder = new TextEncoder()
const decoder = new TextDecoder()
const importedPrivateKeys = new Map()

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

function encodedStableJson(value) {
  return encoder.encode(stableJson(value))
}

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

export function parsePayload(raw) {
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

function isKnownUnlockMode(value) {
  return isValidUnlockMode(value) || value === MASTER_MODE
}

function unlockModeFromPayload(...payloads) {
  for (const payload of payloads) {
    if (!payload || typeof payload !== "object") continue

    const unlockMode = payload.unlock_mode || payload.unlockMode
    if (isKnownUnlockMode(unlockMode)) {
      return unlockMode
    }
  }

  return null
}

export function notify(message, type = "error", title = "Mailbox") {
  if (typeof window.showNotification === "function") {
    window.showNotification(message, type, title)
  } else {
    console.error(`[Mailbox] ${message}`)
  }
}

export function cacheLoginPassword(password) {
  void password
}

function clearCachedLoginPassword() {
  return null
}

function getCachedLoginPassword() {
  return null
}

export function getStoredPrivateKey(mailboxId) {
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

function keyWrapAADContext(unlockMode, kind) {
  return {
    purpose: "elektrine-private-mailbox-key-wrap",
    version: 2,
    kind,
    algorithm: WRAP_ALGORITHM,
    kdf: "scrypt",
    unlock_mode: unlockMode
  }
}

function wrapParams(payload, iv) {
  if (Number(payload.version) >= 2) {
    return { name: WRAP_ALGORITHM, iv, additionalData: encodedStableJson(payload.aad_context) }
  }

  return { name: WRAP_ALGORITHM, iv }
}

export async function wrapBytes(bytes, passphrase, unlockMode = null, kind = "private_key") {
  const salt = randomBytes(16)
  const iv = randomBytes(12)
  const key = await deriveWrappingKey(passphrase, salt, DEFAULT_SCRYPT)
  const aadContext = keyWrapAADContext(unlockMode, kind)
  const ciphertext = await crypto.subtle.encrypt(
    { name: WRAP_ALGORITHM, iv, additionalData: encodedStableJson(aadContext) },
    key,
    bytes
  )

  const payload = {
    version: 2,
    algorithm: WRAP_ALGORITHM,
    kdf: "scrypt",
    aad_context: aadContext,
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
  const plaintext = await crypto.subtle.decrypt(wrapParams(payload, iv), key, ciphertext)
  return new Uint8Array(plaintext)
}

// --- master-password mode -------------------------------------------------
// Instead of deriving a wrapping key from a passphrase, master mode wraps the
// mailbox key with the email subkey of the account master key (held in the
// shared vault session). One master unlock therefore unlocks this mailbox too.

async function masterEmailKey() {
  return vaultSession.featureKey(MASTER_FEATURE)
}

function masterAADContext(kind) {
  return {
    purpose: "elektrine-private-mailbox-key-wrap",
    version: 2,
    kind,
    algorithm: WRAP_ALGORITHM,
    kdf: MASTER_MODE,
    unlock_mode: MASTER_MODE
  }
}

async function wrapBytesWithMasterKey(bytes, kind = "private_key") {
  const key = await masterEmailKey()
  const iv = randomBytes(12)
  const aadContext = masterAADContext(kind)
  const ciphertext = await crypto.subtle.encrypt(
    { name: WRAP_ALGORITHM, iv, additionalData: encodedStableJson(aadContext) },
    key,
    bytes
  )

  return {
    version: 2,
    algorithm: WRAP_ALGORITHM,
    kdf: MASTER_MODE,
    unlock_mode: MASTER_MODE,
    aad_context: aadContext,
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext))
  }
}

async function unwrapBytesWithMasterKey(payload) {
  const key = await masterEmailKey()
  const iv = base64ToBytes(payload.iv)
  const ciphertext = base64ToBytes(payload.ciphertext)
  const plaintext = await crypto.subtle.decrypt(wrapParams(payload, iv), key, ciphertext)
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
    { name: "AES-GCM", iv, additionalData: envelopeAAD(envelope, aad) },
    contentKey,
    concatBytes(ciphertext, tag)
  )

  return JSON.parse(new TextDecoder().decode(plaintext))
}

function envelopeAAD(envelope, legacyAAD) {
  if (Number(envelope.version) >= 2 && envelope.aad_context) {
    return encodedStableJson(envelope.aad_context)
  }

  return legacyAAD
}

export async function decryptMessagePayload(envelope, mailboxId) {
  return decryptEnvelope(envelope, mailboxId, MESSAGE_AAD)
}

export async function decryptAttachmentPayload(envelope, mailboxId) {
  return decryptEnvelope(envelope, mailboxId, ATTACHMENT_AAD)
}

export async function unwrapMailboxPrivateKey(wrappedKeyPayload, verifierPayload, passphrase) {
  const verifierBytes = await unwrapBytes(verifierPayload, passphrase)
  const verifierText = decoder.decode(verifierBytes)

  if (verifierText !== VERIFY_TEXT) {
    throw new Error("invalid-passphrase")
  }

  return unwrapBytes(wrappedKeyPayload, passphrase)
}

async function importAndStorePrivateKey(mailboxId, privateKeyBytes) {
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

async function unlockMailbox(mailboxId, wrappedKeyPayload, verifierPayload, passphrase) {
  const privateKeyBytes = await unwrapMailboxPrivateKey(
    wrappedKeyPayload,
    verifierPayload,
    passphrase
  )
  await importAndStorePrivateKey(mailboxId, privateKeyBytes)
}

async function unlockMailboxWithMaster(mailboxId, wrappedKeyPayload, verifierPayload) {
  const verifierBytes = await unwrapBytesWithMasterKey(verifierPayload)

  if (decoder.decode(verifierBytes) !== VERIFY_TEXT) {
    throw new Error("invalid-master-key")
  }

  const privateKeyBytes = await unwrapBytesWithMasterKey(wrappedKeyPayload)
  await importAndStorePrivateKey(mailboxId, privateKeyBytes)
}

function lockedStatusText(unlockMode) {
  if (unlockMode === MASTER_MODE) {
    return "Mailbox locked. Unlock your master password to unlock it in this tab."
  }

  if (unlockMode === "account_password") {
    return "Mailbox locked. Enter your account password again to unlock it in this tab."
  }

  return "Mailbox locked."
}

function unlockSecretLabel(unlockMode) {
  return unlockMode === "account_password" ? "account password" : "mailbox passphrase"
}

function unlockSecretPlaceholder(unlockMode) {
  return unlockMode === "account_password" ? "Account password" : "Mailbox passphrase"
}

export function maybeSetValue(field, nextValue, matcher) {
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

export const MailboxPrivateStorage = {
  mounted() {
    this.captureElements()
    this.bindEvents()
    this.unsubscribeVault = vaultSession.subscribe(() => this.onVaultChange())
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
    if (this.unsubscribeVault) this.unsubscribeVault()
  },

  onVaultChange() {
    // The shared master vault locked or unlocked: master-mode setup gating and
    // auto-unlock both depend on it.
    this.renderSetupModeState()
    if (vaultSession.isUnlocked()) {
      void this.maybeAutoUnlock()
    } else if (this.unlockMode === MASTER_MODE && this.mailboxId) {
      clearPrivateKey(this.mailboxId)
      this.renderLockState()
    }
  },

  captureElements() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.configured = this.el.dataset.privateMailboxConfigured === "true"
    this.wrappedKeyPayload = parsePayload(this.el.dataset.privateMailboxWrappedKey)
    this.verifierPayload = parsePayload(this.el.dataset.privateMailboxVerifier)
    const datasetUnlockMode = this.el.dataset.privateMailboxUnlockMode

    this.unlockMode =
      (isKnownUnlockMode(datasetUnlockMode) ? datasetUnlockMode : null) ||
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
    this.masterFields = this.el.querySelector("[data-private-mailbox-master-fields]")
    this.masterUnlockFields = this.el.querySelector("[data-private-mailbox-master-unlock-fields]")
    this.masterConfigured = this.el.dataset.privateMailboxMasterConfigured === "true"
    this.masterWrappedDek = parsePayload(this.el.dataset.privateMailboxMasterWrappedDek)
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
        return
      }

      const masterUnlockButton = event.target.closest("[data-private-mailbox-master-unlock]")
      if (masterUnlockButton) {
        event.preventDefault()
        await this.handleMasterVaultUnlock()
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

    if (isKnownUnlockMode(selectedMode)) {
      return selectedMode
    }

    return "account_password"
  },

  renderSetupModeState() {
    const mode = this.currentSetupMode()

    if (this.accountPasswordFields) {
      const hidden = mode !== "account_password"
      this.accountPasswordFields.classList.toggle("hidden", hidden)

      if (this.setupAccountPasswordInput) {
        this.setupAccountPasswordInput.toggleAttribute("required", !hidden)
      }
    }

    if (this.customPassphraseFields) {
      const hidden = mode !== "separate_passphrase"
      this.customPassphraseFields.classList.toggle("hidden", hidden)

      if (this.setupPassphraseInput) {
        this.setupPassphraseInput.toggleAttribute("required", !hidden)
      }

      if (this.setupConfirmInput) {
        this.setupConfirmInput.toggleAttribute("required", !hidden)
      }
    }

    if (this.masterFields) {
      this.masterFields.classList.toggle("hidden", mode !== MASTER_MODE)
    }

    if (this.masterUnlockFields) {
      // Show the inline unlock only when the master password exists but the
      // vault is locked for this tab; once unlocked, setup can proceed.
      const showUnlock = mode === MASTER_MODE && this.masterConfigured && !vaultSession.isUnlocked()
      this.masterUnlockFields.classList.toggle("hidden", !showUnlock)
    }
  },

  // The dedicated master-unlock field (settings page) or, on pages that only
  // render one unlock field (the inbox), the shared passphrase input.
  masterPassphraseInput() {
    return (
      this.el.querySelector("[data-private-mailbox-master-unlock-input]") ||
      this.el.querySelector("[data-private-mailbox-passphrase]")
    )
  },

  async handleMasterVaultUnlock() {
    const input = this.masterPassphraseInput()
    const passphrase = input?.value || ""

    if (!this.masterWrappedDek) {
      this.setMasterError("Set up your master password first at /account/master-password.")
      return
    }

    if (passphrase.trim() === "") {
      this.setMasterError("Enter your master passphrase.")
      return
    }

    try {
      const mdk = await unwrapWithSecret(this.masterWrappedDek, passphrase)
      vaultSession.unlock(mdk)
      if (input) input.value = ""
      this.setMasterError("")
      // The vault-change subscription re-renders setup state and auto-unlocks a
      // configured master mailbox.
    } catch (_error) {
      this.setMasterError("Incorrect master passphrase.")
    }
  },

  setMasterError(message) {
    this.el.querySelectorAll("[data-private-mailbox-master-error]").forEach((el) => {
      el.textContent = message || ""
      el.classList.toggle("hidden", !message)
    })
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

    this.setStatusText(lockedStatusText(this.unlockMode))
    this.renderUnlockPanels(false)
  },

  async maybeAutoUnlock() {
    if (
      this.autoUnlockSuppressed ||
      !this.configured ||
      !this.mailboxId ||
      !this.wrappedKeyPayload ||
      !this.verifierPayload ||
      getStoredPrivateKey(this.mailboxId)
    ) {
      return
    }

    if (this.unlockMode === MASTER_MODE) {
      if (!vaultSession.isUnlocked()) return

      try {
        await unlockMailboxWithMaster(
          this.mailboxId,
          this.wrappedKeyPayload,
          this.verifierPayload
        )
        this.renderLockState()
      } catch (_error) {
        // master key mismatch or transient error; stay locked
      }

      return
    }

    if (this.unlockMode !== "account_password") {
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
    if (!this.mailboxId || !this.wrappedKeyPayload || !this.verifierPayload) {
      notify("Private mailbox storage is not configured yet.")
      return
    }

    if (this.unlockMode === MASTER_MODE) {
      // If the shared vault is locked for this tab, unlock it inline with the
      // master passphrase before unwrapping the mailbox key.
      if (!vaultSession.isUnlocked()) {
        const masterInput = this.masterPassphraseInput()
        const masterPassphrase = masterInput?.value || ""

        if (!this.masterWrappedDek) {
          notify("Set up your master password first at /account/master-password.")
          return
        }

        if (masterPassphrase.trim() === "") {
          notify("Enter your master passphrase to unlock this mailbox.")
          return
        }

        try {
          const mdk = await unwrapWithSecret(this.masterWrappedDek, masterPassphrase)
          vaultSession.unlock(mdk)
          if (masterInput) masterInput.value = ""
        } catch (_error) {
          notify("Incorrect master passphrase.")
          return
        }
      }

      try {
        await unlockMailboxWithMaster(this.mailboxId, this.wrappedKeyPayload, this.verifierPayload)
        this.autoUnlockSuppressed = false
        this.renderLockState()
        notify("Mailbox unlocked for this tab.", "success")
      } catch (_error) {
        notify("Could not unlock the mailbox with your master password.")
      }

      return
    }

    const passphrase = this.passphraseInput?.value || ""

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

    if (unlockMode === MASTER_MODE) {
      if (!vaultSession.isUnlocked()) {
        notify(
          this.masterConfigured
            ? "Unlock your master password above first, then enable private storage."
            : "Set up your master password first at /account/master-password."
        )
        return
      }

      try {
        const { publicKeyPem, privateKey } = await generateMailboxKeypair()
        const wrappedPrivateKey = await wrapBytesWithMasterKey(privateKey, "private_key")
        const verifier = await wrapBytesWithMasterKey(encoder.encode(VERIFY_TEXT), "verifier")

        this.wrappedKeyInput.value = JSON.stringify(wrappedPrivateKey)
        this.publicKeyInput.value = publicKeyPem
        this.verifierInput.value = JSON.stringify(verifier)
        this.setupForm.requestSubmit()
      } catch (_error) {
        notify("Could not generate mailbox keys with your master password.")
      }

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
      const verifier = await wrapBytes(
        encoder.encode(VERIFY_TEXT),
        wrappingSecret,
        unlockMode,
        "verifier"
      )

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
