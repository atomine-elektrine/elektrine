/**
 * VaultManager - browser side of the account-password vault page.
 * Generates/wraps the Master Data Key on setup, unwraps it on unlock, and
 * shares the unlocked key via vault_session so every feature unlocks at once.
 */

import {
  generateMdk,
  wrapWithSecret,
  unwrapWithSecret,
  generateRecoveryCode,
  normalizeRecoveryCode,
  MIN_PASSPHRASE_LENGTH
} from "./vault_crypto"
import * as vaultSession from "./vault_session"

export const VaultManager = {
  mounted() {
    this.unsubscribe = vaultSession.subscribe(() => this.renderState())
    this.bind()
    this.renderState()
  },

  updated() {
    this.renderState()
    this.renderResetState()
  },

  destroyed() {
    this.unsubscribe && this.unsubscribe()
  },

  bind() {
    if (this.bound) return
    this.bound = true

    this.el.addEventListener("click", (event) => this.handleClick(event))
    this.el.addEventListener("submit", (event) => this.handleSubmit(event))
    this.el.addEventListener("input", (event) => this.handleInput(event))
    this.renderResetState()
  },

  handleClick(event) {
    if (event.target.closest("[data-vault-setup]")) {
      event.preventDefault()
      this.setup()
      return
    }

    if (event.target.closest("[data-vault-setup-finish]")) {
      event.preventDefault()
      this.finishSetup()
      return
    }

    if (event.target.closest("[data-vault-unlock]")) {
      event.preventDefault()
      this.unlock()
      return
    }

    if (event.target.closest("[data-vault-lock]")) {
      event.preventDefault()
      vaultSession.lock()
      return
    }

    if (event.target.closest("[data-vault-reset-button]")) {
      vaultSession.lock()
      return
    }

    if (event.target.closest("[data-vault-recovery]")) {
      event.preventDefault()
      this.recover()
      return
    }

    if (event.target.closest("[data-vault-recovery-finish]")) {
      event.preventDefault()
      this.finishRecovery()
    }
  },

  handleSubmit(event) {
    const setupForm = event.target.closest("[data-vault-setup-form]")
    if (setupForm) {
      this.handleSetupSubmit(event, setupForm)
      return
    }

    const recoveryForm = event.target.closest("[data-vault-recovery-form]")
    if (recoveryForm) {
      this.handleRecoverySubmit(event, recoveryForm)
    }
  },

  handleInput(event) {
    if (event.target.closest("[data-vault-reset-confirm]")) {
      this.renderResetState()
    }
  },

  setError(message) {
    const el = this.el.querySelector("[data-vault-error]")
    if (el) el.textContent = message || ""
  },

  setRecoveryError(message) {
    const el = this.el.querySelector("[data-vault-recovery-error]")
    if (el) el.textContent = message || ""
  },

  renderState() {
    const unlocked = vaultSession.isUnlocked()

    const status = this.el.querySelector("[data-vault-status]")
    if (status) {
      status.textContent = unlocked
        ? status.dataset.unlockedLabel || "Unlocked"
        : status.dataset.lockedLabel || "Locked"
      status.classList.toggle("badge-success", unlocked)
    }

    const locked = this.el.querySelector("[data-vault-locked-section]")
    const unlockedSection = this.el.querySelector("[data-vault-unlocked-section]")
    if (locked) locked.classList.toggle("hidden", unlocked)
    if (unlockedSection) unlockedSection.classList.toggle("hidden", !unlocked)
  },

  renderResetState() {
    const input = this.el.querySelector("[data-vault-reset-confirm]")
    const button = this.el.querySelector("[data-vault-reset-button]")
    if (!input || !button) return

    const expected = "RESET ENCRYPTED DATA"
    button.disabled = input.value.trim() !== expected
  },

  async setup() {
    this.setError("")
    const passphrase = this.value("[data-vault-setup-input]")
    const confirmInput = this.el.querySelector("[data-vault-setup-confirm]")
    const confirm = confirmInput ? confirmInput.value : passphrase

    if (!passphrase) {
      return this.setError("Enter your current password.")
    }
    if (!this.accountPasswordMode() && passphrase.length < MIN_PASSPHRASE_LENGTH) {
      return this.setError(`Use at least ${MIN_PASSPHRASE_LENGTH} characters.`)
    }
    if (passphrase !== confirm) {
      return this.setError("Passwords do not match.")
    }

    try {
      const mdk = generateMdk()
      const recoveryCode = generateRecoveryCode()

      const wrappedDek = await wrapWithSecret(mdk, passphrase)
      const wrappedRecovery = await wrapWithSecret(mdk, normalizeRecoveryCode(recoveryCode))

      this.setValue("[data-vault-wrapped-dek-input]", JSON.stringify(wrappedDek))
      this.setValue("[data-vault-wrapped-dek-recovery-input]", JSON.stringify(wrappedRecovery))

      // Unlock the session now so the user is unlocked the moment setup saves.
      vaultSession.unlock(mdk)

      const output = this.el.querySelector("[data-vault-recovery-output]")
      if (output) output.textContent = recoveryCode
      this.el.querySelector("[data-vault-recovery-panel]")?.classList.remove("hidden")
      this.el.querySelector("[data-vault-setup]")?.classList.add("hidden")
    } catch (_error) {
      this.setError("Could not set up encryption in this browser.")
    }
  },

  handleSetupSubmit(event, form = event.currentTarget) {
    if (form?.dataset.vaultSetupSubmitting === "true") return

    event.preventDefault()
    this.setup()
  },

  async recover() {
    this.setRecoveryError("")

    const recoveryCode = normalizeRecoveryCode(this.value("[data-vault-recovery-code]"))
    const passphrase = this.value("[data-vault-recovery-new-input]")
    const confirmInput = this.el.querySelector("[data-vault-recovery-new-confirm]")
    const confirm = confirmInput ? confirmInput.value : passphrase
    const wrapped = this.wrappedRecoveryDek()

    if (!wrapped) {
      return this.setRecoveryError("No recovery key found.")
    }
    if (!recoveryCode) {
      return this.setRecoveryError("Enter your recovery code.")
    }
    if (!passphrase) {
      return this.setRecoveryError("Enter your current password.")
    }
    if (!this.accountPasswordMode() && passphrase.length < MIN_PASSPHRASE_LENGTH) {
      return this.setRecoveryError(`Use at least ${MIN_PASSPHRASE_LENGTH} characters.`)
    }
    if (passphrase !== confirm) {
      return this.setRecoveryError("Passwords do not match.")
    }

    try {
      const mdk = await unwrapWithSecret(wrapped, recoveryCode)
      const newRecoveryCode = generateRecoveryCode()
      const wrappedDek = await wrapWithSecret(mdk, passphrase)
      const wrappedRecovery = await wrapWithSecret(mdk, normalizeRecoveryCode(newRecoveryCode))

      this.setValue("[data-vault-recovery-wrapped-dek-input]", JSON.stringify(wrappedDek))
      this.setValue(
        "[data-vault-recovery-wrapped-dek-recovery-input]",
        JSON.stringify(wrappedRecovery)
      )

      vaultSession.unlock(mdk)

      const output = this.el.querySelector("[data-vault-recovery-new-output]")
      if (output) output.textContent = newRecoveryCode
      this.el.querySelector("[data-vault-recovery-new-panel]")?.classList.remove("hidden")
      this.el.querySelector("[data-vault-recovery]")?.classList.add("hidden")
    } catch (_error) {
      this.setRecoveryError("Recovery code is incorrect or cannot unlock this account.")
    }
  },

  handleRecoverySubmit(event, form = event.currentTarget) {
    if (form?.dataset.vaultRecoverySubmitting === "true") return

    event.preventDefault()
    this.recover()
  },

  finishRecovery() {
    const form = this.el.querySelector("[data-vault-recovery-form]")
    if (form) {
      form.dataset.vaultRecoverySubmitting = "true"
      form.requestSubmit()
    }
  },

  finishSetup() {
    const form = this.el.querySelector("[data-vault-setup-form]")
    if (form) {
      form.dataset.vaultSetupSubmitting = "true"
      form.requestSubmit()
    }
  },

  async unlock() {
    this.setError("")
    const passphrase = this.value("[data-vault-unlock-input]")
    const wrapped = this.wrappedDek()
    if (!wrapped) return this.setError("No encrypted data key found.")

    try {
      const mdk = await unwrapWithSecret(wrapped, passphrase)
      vaultSession.unlock(mdk)
      this.setValue("[data-vault-unlock-input]", "")
    } catch (_error) {
      this.setError("Incorrect password.")
    }
  },

  accountPasswordMode() {
    return this.el.dataset.vaultSecretMode === "account_password"
  },

  wrappedDek() {
    const raw = this.el.dataset.vaultWrappedDek
    if (!raw) return null
    try {
      return JSON.parse(raw)
    } catch (_error) {
      return null
    }
  },

  wrappedRecoveryDek() {
    const raw = this.el.dataset.vaultWrappedDekRecovery
    if (!raw) return null
    try {
      return JSON.parse(raw)
    } catch (_error) {
      return null
    }
  },

  value(selector) {
    const el = this.el.querySelector(selector)
    return el ? el.value : ""
  },

  setValue(selector, value) {
    const el = this.el.querySelector(selector)
    if (el) el.value = value
  }
}
