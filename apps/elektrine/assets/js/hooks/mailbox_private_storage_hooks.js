/**
 * MailboxPrivateStorage hook: drives the lock/unlock/setup UI for a mailbox's
 * zero-knowledge private storage. The crypto and key-management primitives live
 * in ./mailbox_private_crypto; the public names that other modules import from
 * here are re-exported below so their imports keep working unchanged.
 */

import { unwrapWithSecret } from "./vault_crypto"
import * as vaultSession from "./vault_session"
import {
  MASTER_MODE,
  VERIFY_TEXT,
  cacheLoginPassword,
  clearCachedLoginPassword,
  clearPrivateKey,
  dispatchMailboxEvent,
  encoder,
  generateMailboxKeypair,
  getCachedLoginPassword,
  getStoredPrivateKey,
  isKnownUnlockMode,
  lockedStatusText,
  notify,
  parsePayload,
  unlockMailbox,
  unlockMailboxWithMaster,
  unlockModeFromPayload,
  unlockSecretLabel,
  unlockSecretPlaceholder,
  wrapBytes,
  wrapBytesWithMasterKey
} from "./mailbox_private_crypto"

export {
  VERIFY_TEXT,
  cacheLoginPassword,
  decryptAttachmentPayload,
  decryptMessagePayload,
  encoder,
  getStoredPrivateKey,
  maybeSetValue,
  notify,
  parsePayload,
  unwrapMailboxPrivateKey,
  wrapBytes
} from "./mailbox_private_crypto"


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
    // The shared account-password vault locked or unlocked: setup gating and
    // auto-unlock both depend on it.
    this.renderSetupModeState()
    if (vaultSession.isUnlocked()) {
      this.autoUnlockFailed = false
      this.renderLockState()
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
      // Show the inline unlock only when encrypted data is enabled but the
      // account-password vault is locked for this tab; once unlocked, setup can proceed.
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
      this.setMasterError("Set up account-password encrypted data first.")
      return
    }

    if (passphrase.trim() === "") {
      this.setMasterError("Enter your account password.")
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
      this.setMasterError(
        "Incorrect account password. If you just reset it, recover encrypted data at /account/encrypted-data."
      )
    }
  },

  setMasterError(message) {
    this.el.querySelectorAll("[data-private-mailbox-master-error]").forEach((el) => {
      el.textContent = message || ""
      el.classList.toggle("hidden", !message)
    })
  },

  // True when an auto-unlock is about to run for this panel (the encrypted-data vault
  // is already unlocked in this tab). Used to render a quiet "unlocking" state
  // instead of flashing the passphrase prompt on load, then swapping it out.
  autoUnlockPending() {
    return (
      !this.autoUnlockSuppressed &&
      !this.autoUnlockFailed &&
      this.configured &&
      this.unlockMode === MASTER_MODE &&
      !!this.wrappedKeyPayload &&
      !!this.verifierPayload &&
      vaultSession.isUnlocked()
    )
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

    if (this.autoUnlockPending()) {
      this.setStatusText("Unlocking private mailbox…")
      this.renderUnlockPanels(true)
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
        this.autoUnlockFailed = false
        this.renderLockState()
      } catch (_error) {
        // encrypted data key mismatch or transient error; fall back to the manual prompt
        this.autoUnlockFailed = true
        this.renderLockState()
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
      // If encrypted data is locked for this tab, unlock it inline with the
      // account password before unwrapping the mailbox key.
      if (!vaultSession.isUnlocked()) {
        const masterInput = this.masterPassphraseInput()
        const masterPassphrase = masterInput?.value || ""

        if (!this.masterWrappedDek) {
          notify("Set up account-password encrypted data first.")
          return
        }

        if (masterPassphrase.trim() === "") {
          notify("Enter your account password to unlock this mailbox.")
          return
        }

        try {
          const mdk = await unwrapWithSecret(this.masterWrappedDek, masterPassphrase)
          vaultSession.unlock(mdk)
          if (masterInput) masterInput.value = ""
        } catch (_error) {
          notify(
            "Incorrect account password. If you just reset it, recover encrypted data at /account/encrypted-data."
          )
          return
        }
      }

      try {
        await unlockMailboxWithMaster(this.mailboxId, this.wrappedKeyPayload, this.verifierPayload)
        this.autoUnlockSuppressed = false
        this.renderLockState()
        notify("Mailbox unlocked for this tab.", "success")
      } catch (_error) {
        notify(
          "This mailbox was wrapped with an older encrypted-data key. Reset private mailbox storage in Account Settings, then set it up again."
        )
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
            ? "Enter your account password above first, then enable private storage."
            : "Set up account-password encrypted data first."
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
        notify("Could not generate mailbox keys.")
      }

      return
    }

    if (unlockMode === "account_password") {
      if (accountPassword.trim() === "") {
        notify("Enter your current password to enable private mailbox storage.")
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
