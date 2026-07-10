/**
 * KairoVault - zero-knowledge encryption/decryption for Kairo sources.
 * Encrypted rows decrypt on demand under the Kairo subkey of the unlocked
 * encrypted data key, which can be unlocked inline for the tab. The composer can also
 * encrypt new notes client-side before they are pushed to the server, so the
 * plaintext body is never persisted.
 */

import { decryptValue, encryptValue, unwrapWithSecret } from "./vault_crypto"
import * as vaultSession from "./vault_session"

const FEATURE = "kairo"
const AAD = { purpose: "elektrine-kairo-source" }

export const KairoVault = {
  mounted() {
    this.encryptSavePending = false
    this.unlockPending = false
    this.unsubscribe = vaultSession.subscribe(() => this.renderLockState())
    this.onRootClick = (event) => this.onClick(event)
    this.onRootKeydown = (event) => this.onKeydown(event)
    this.el.addEventListener("click", this.onRootClick)
    this.el.addEventListener("keydown", this.onRootKeydown)
    this.renderLockState()
  },

  updated() {
    // LiveView re-rendered the contents (e.g. selecting a source), which resets
    // the locked-hint to its server default; re-apply the lock state.
    this.renderLockState()
  },

  destroyed() {
    this.unsubscribe && this.unsubscribe()
    this.el.removeEventListener("click", this.onRootClick)
    this.el.removeEventListener("keydown", this.onRootKeydown)
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
      return
    }

    const encryptSave = event.target.closest("[data-kairo-encrypt-save]")
    if (encryptSave) {
      event.preventDefault()
      this.saveEncryptedNote(encryptSave)
    }
  },

  onKeydown(event) {
    if (event.key !== "Enter" || !event.target.closest("[data-kairo-master-unlock-input]")) return
    event.preventDefault()
    this.unlockMaster()
  },

  async unlockMaster() {
    if (this.unlockPending) return

    const input = this.el.querySelector("[data-kairo-master-unlock-input]")
    const error = this.el.querySelector("[data-kairo-master-error]")
    const wrapped = this.wrappedDek()
    const setError = (message) => {
      if (!error) return
      error.textContent = message || ""
      error.classList.toggle("hidden", !message)
    }

    if (!wrapped) {
      return setError("Set up account-password encryption first.")
    }

    if (!input || input.value.trim() === "") {
      return setError("Enter your account password.")
    }

    const button = this.el.querySelector("[data-kairo-master-unlock]")
    this.unlockPending = true
    if (button) {
      button.disabled = true
      button.setAttribute("aria-busy", "true")
    }

    try {
      const mdk = await unwrapWithSecret(wrapped, input.value)
      vaultSession.unlock(mdk)
      input.value = ""
      setError("")
      // The vault-change subscription re-renders the lock state.
    } catch (_error) {
      setError(
        "Incorrect account password. If you just reset it, recover encrypted data at /account/encrypted-data."
      )
    } finally {
      this.unlockPending = false
      if (button) {
        button.disabled = false
        button.removeAttribute("aria-busy")
      }
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

  async saveEncryptedNote(button) {
    if (this.encryptSavePending) return

    const form = this.el.querySelector("#kairo-note-form")
    if (!form) return

    const error = this.el.querySelector("[data-kairo-encrypt-error]")
    const setError = (message) => {
      if (!error) return
      error.textContent = message || ""
      error.classList.toggle("hidden", !message)
    }

    if (!vaultSession.isUnlocked()) {
      return setError("Enter your account password to save encrypted notes.")
    }

    const field = (name) => {
      const input = form.querySelector(`[name="note[${name}]"]`)
      return input ? input.value : ""
    }

    const content = field("content")
    const title = field("title")
    if (content.trim() === "" && title.trim() === "") {
      return setError("Add a title or some content first.")
    }

    this.encryptSavePending = true
    button.disabled = true
    button.setAttribute("aria-busy", "true")

    try {
      const key = await vaultSession.featureKey(FEATURE)
      const payload = await encryptValue(content, key, AAD)

      this.pushEvent(
        "save_encrypted_note",
        {
          note: { title, tags: field("tags"), project_id: field("project_id") },
          payload
        },
        (reply) => {
          this.finishEncryptedSave()
          if (reply && reply.ok) {
            setError("")
          } else {
            setError((reply && reply.error) || "Could not save the encrypted note.")
          }
        }
      )
    } catch (_error) {
      this.finishEncryptedSave()
      setError("Encryption failed in this browser.")
    }
  },

  finishEncryptedSave() {
    this.encryptSavePending = false
    const button = this.el.querySelector("[data-kairo-encrypt-save]")
    if (!button) return
    button.disabled = false
    button.removeAttribute("aria-busy")
  },

  async decryptRow(button) {
    const output = button.parentElement.querySelector("[data-kairo-output]")
    if (!output) return

    if (!vaultSession.isUnlocked()) {
      output.textContent = "Enter your account password to read this."
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
