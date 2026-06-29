/**
 * VaultManager — browser side of the master-password page.
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

  destroyed() {
    this.unsubscribe && this.unsubscribe()
  },

  bind() {
    this.on("[data-vault-setup]", "click", () => this.setup())
    this.on("[data-vault-setup-finish]", "click", () => this.finishSetup())
    this.on("[data-vault-unlock]", "click", () => this.unlock())
    this.on("[data-vault-lock]", "click", () => vaultSession.lock())
  },

  on(selector, event, handler) {
    const el = this.el.querySelector(selector)
    if (el) el.addEventListener(event, handler)
  },

  setError(message) {
    const el = this.el.querySelector("[data-vault-error]")
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

  async setup() {
    this.setError("")
    const passphrase = this.value("[data-vault-setup-input]")
    const confirm = this.value("[data-vault-setup-confirm]")

    if (passphrase.length < MIN_PASSPHRASE_LENGTH) {
      return this.setError(`Use at least ${MIN_PASSPHRASE_LENGTH} characters.`)
    }
    if (passphrase !== confirm) {
      return this.setError("Passphrases do not match.")
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

  finishSetup() {
    const form = this.el.querySelector("[data-vault-setup-form]")
    if (form) form.requestSubmit()
  },

  async unlock() {
    this.setError("")
    const passphrase = this.value("[data-vault-unlock-input]")
    const wrapped = this.wrappedDek()
    if (!wrapped) return this.setError("No master key found.")

    try {
      const mdk = await unwrapWithSecret(wrapped, passphrase)
      vaultSession.unlock(mdk)
      this.setValue("[data-vault-unlock-input]", "")
    } catch (_error) {
      this.setError("Incorrect master passphrase.")
    }
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

  value(selector) {
    const el = this.el.querySelector(selector)
    return el ? el.value : ""
  },

  setValue(selector, value) {
    const el = this.el.querySelector(selector)
    if (el) el.value = value
  }
}
