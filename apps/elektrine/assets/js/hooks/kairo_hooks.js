/**
 * KairoVault — optional zero-knowledge encryption for Kairo sources.
 * When the "Encrypt" toggle is on, the content is encrypted in the browser
 * under the Kairo subkey of the unlocked master key before the form submits;
 * the server only ever stores the ciphertext. Encrypted rows decrypt on demand.
 */

import { encryptValue, decryptValue, unwrapWithSecret } from "./vault_crypto"
import * as vaultSession from "./vault_session"

const FEATURE = "kairo"
const AAD = { purpose: "elektrine-kairo-source" }

export const KairoVault = {
  mounted() {
    this.unsubscribe = vaultSession.subscribe(() => this.renderLockState())
    this.el.addEventListener("click", (event) => this.onClick(event))
    this.el.addEventListener("change", (event) => {
      if (event.target.matches("[data-kairo-encrypt-toggle]")) this.renderLockState()
    })
    this.renderLockState()
  },

  destroyed() {
    this.unsubscribe && this.unsubscribe()
  },

  renderLockState() {
    const toggle = this.el.querySelector("[data-kairo-encrypt-toggle]")
    const hint = this.el.querySelector("[data-kairo-locked-hint]")
    const needsUnlock = toggle && toggle.checked && !vaultSession.isUnlocked()
    if (hint) hint.classList.toggle("hidden", !needsUnlock)
  },

  onClick(event) {
    const submit = event.target.closest("[data-kairo-submit]")
    if (submit) {
      event.preventDefault()
      this.submit()
      return
    }

    const unlock = event.target.closest("[data-kairo-master-unlock]")
    if (unlock) {
      event.preventDefault()
      this.unlockMaster()
      return
    }

    const decrypt = event.target.closest("[data-kairo-decrypt]")
    if (decrypt) {
      event.preventDefault()
      this.decryptRow(decrypt)
    }
  },

  async unlockMaster() {
    const input = this.el.querySelector("[data-kairo-master-unlock-input]")
    const error = this.el.querySelector("[data-kairo-master-error]")
    const wrapped = this.wrappedDek()
    const setError = (message) => {
      if (!error) return
      error.textContent = message || ""
      error.classList.toggle("hidden", !message)
    }

    if (!wrapped) {
      return setError("Set up your master password first at /account/master-password.")
    }

    if (!input || input.value.trim() === "") {
      return setError("Enter your master passphrase.")
    }

    try {
      const mdk = await unwrapWithSecret(wrapped, input.value)
      vaultSession.unlock(mdk)
      input.value = ""
      setError("")
      // The vault-change subscription re-renders the lock state.
    } catch (_error) {
      setError("Incorrect master passphrase.")
    }
  },

  wrappedDek() {
    const raw = this.el.dataset.kairoMasterWrappedDek
    if (!raw) return null
    try {
      return JSON.parse(raw)
    } catch (_error) {
      return null
    }
  },

  async submit() {
    const form = this.el.querySelector("#kairo-source-form")
    const toggle = this.el.querySelector("[data-kairo-encrypt-toggle]")

    if (toggle && toggle.checked) {
      if (!vaultSession.isUnlocked()) {
        this.renderLockState()
        return
      }

      try {
        const contentEl = form.querySelector('[name="source[content]"]')
        const key = await vaultSession.featureKey(FEATURE)
        const payload = await encryptValue(contentEl ? contentEl.value : "", key, AAD)

        this.setValue("[data-kairo-encrypted-content]", JSON.stringify(payload))
        this.setValue("[data-kairo-encrypted-flag]", "true")
        if (contentEl) contentEl.value = "" // never send plaintext to the server
      } catch (_error) {
        return
      }
    }

    form.requestSubmit()
  },

  async decryptRow(button) {
    const output = button.parentElement.querySelector("[data-kairo-output]")
    if (!output) return

    if (!vaultSession.isUnlocked()) {
      output.textContent = "Unlock your master password to read this."
      output.classList.remove("hidden")
      return
    }

    try {
      const payload = JSON.parse(button.dataset.kairoPayload)
      const key = await vaultSession.featureKey(FEATURE)
      output.textContent = await decryptValue(payload, key, AAD)
      output.classList.remove("hidden")
    } catch (_error) {
      output.textContent = "Could not decrypt this source."
      output.classList.remove("hidden")
    }
  },

  setValue(selector, value) {
    const el = this.el.querySelector(selector)
    if (el) el.value = value
  }
}
