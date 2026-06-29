/**
 * KairoVault - zero-knowledge decryption for Kairo sources.
 * Sources are ingested via the API (encrypted client-side there); this page only
 * reads them. Encrypted rows decrypt on demand under the Kairo subkey of the
 * unlocked master key, which can be unlocked inline for the tab.
 */

import { decryptValue, unwrapWithSecret } from "./vault_crypto"
import * as vaultSession from "./vault_session"

const FEATURE = "kairo"
const AAD = { purpose: "elektrine-kairo-source" }

export const KairoVault = {
  mounted() {
    this.unsubscribe = vaultSession.subscribe(() => this.renderLockState())
    this.el.addEventListener("click", (event) => this.onClick(event))
    this.renderLockState()
  },

  updated() {
    // LiveView re-rendered the contents (e.g. selecting a source), which resets
    // the locked-hint to its server default; re-apply the lock state.
    this.renderLockState()
  },

  destroyed() {
    this.unsubscribe && this.unsubscribe()
  },

  renderLockState() {
    const hint = this.el.querySelector("[data-kairo-locked-hint]")
    if (hint) hint.classList.toggle("hidden", vaultSession.isUnlocked())
  },

  onClick(event) {
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
  }
}
