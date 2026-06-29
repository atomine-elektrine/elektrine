/**
 * Nerve - zero-knowledge password entries, now keyed by the account master
 * password. Unlock is shared via vault_session; entries are encrypted/decrypted
 * with the Nerve subkey of the master key. The server only ever stores ciphertext.
 */

import { encryptValue, decryptValue, unwrapWithSecret } from "./vault_crypto"
import * as vaultSession from "./vault_session"

const FEATURE = "nerve"
const PASSWORD_LENGTH = 24
const PASSWORD_ALPHABET =
  "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%^&*-_"

const metadataAad = () => ({ purpose: "elektrine-nerve-metadata" })

function entryAad(metadata, field) {
  return {
    purpose: "elektrine-nerve-entry",
    field,
    title: (metadata.title || "").trim(),
    login_username: (metadata.login_username || "").trim(),
    website: (metadata.website || "").trim()
  }
}

export const Nerve = {
  mounted() {
    this.unsubscribe = vaultSession.subscribe(() => this.onLockChange())
    this.bind()
    this.onLockChange()
  },

  destroyed() {
    this.unsubscribe && this.unsubscribe()
  },

  bind() {
    this.el.addEventListener("click", (event) => {
      if (event.target.closest("[data-vault-unlock]")) return this.unlock()
      if (event.target.closest("[data-vault-lock]")) return vaultSession.lock()
      if (event.target.closest("[data-nerve-toggle-password]")) return this.togglePasswordVisibility()
      if (event.target.closest("[data-nerve-generate]")) return this.generatePassword()
      if (event.target.closest("[data-nerve-entry-submit]")) {
        event.preventDefault()
        return this.saveEntry()
      }
      const reveal = event.target.closest("[data-nerve-reveal]")
      if (reveal) {
        event.preventDefault()
        return this.toggleReveal(reveal)
      }
    })
  },

  // --- lock state ---

  onLockChange() {
    const unlocked = vaultSession.isUnlocked()
    const status = this.el.querySelector("[data-vault-status]")
    if (status) {
      status.textContent = unlocked
        ? status.dataset.unlockedLabel || "Unlocked."
        : status.dataset.lockedLabel || "Locked."
    }

    if (unlocked) this.decryptVisibleMetadata()
  },

  setError(message) {
    const el = this.el.querySelector("[data-vault-error]")
    if (el) el.textContent = message || ""
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

  async unlock() {
    this.setError("")
    const input = this.el.querySelector("[data-vault-unlock-input]")
    const wrapped = this.wrappedDek()
    if (!wrapped) return this.setError("No master key found.")

    try {
      const mdk = await unwrapWithSecret(wrapped, input ? input.value : "")
      vaultSession.unlock(mdk)
      if (input) input.value = ""
    } catch (_error) {
      this.setError("Incorrect master passphrase.")
    }
  },

  // --- entries ---

  async key() {
    return vaultSession.featureKey(FEATURE)
  },

  async decryptMetadata(row, key) {
    const raw = row.dataset.encryptedMetadata
    if (!raw) return {}
    const payload = JSON.parse(raw)
    return JSON.parse(await decryptValue(payload, key, metadataAad()))
  },

  async decryptVisibleMetadata() {
    let key
    try {
      key = await this.key()
    } catch (_error) {
      return
    }

    const rows = this.el.querySelectorAll("[data-encrypted-metadata]")
    for (const row of rows) {
      try {
        const metadata = await this.decryptMetadata(row, key)
        this.setText(row, "[data-nerve-title-output]", metadata.title)
        this.setText(row, "[data-nerve-username-output]", metadata.login_username)
        this.setText(row, "[data-nerve-website-output]", metadata.website)
      } catch (_error) {
        // leave the placeholder if a row fails to decrypt
      }
    }
  },

  async saveEntry() {
    this.setError("")
    if (!vaultSession.isUnlocked()) return this.setError("Unlock your master password first.")

    const form = this.el.querySelector("#nerve-entry-form")
    const metadata = {
      title: this.fieldValue('[name="entry[title]"]'),
      login_username: this.fieldValue('[name="entry[login_username]"]'),
      website: this.fieldValue('[name="entry[website]"]')
    }
    const password = this.value("[data-nerve-password-input]")
    const notes = this.value("[data-nerve-notes-input]")

    if (!password) return this.setError("A password is required.")

    try {
      const key = await this.key()

      this.setHidden(
        "[data-nerve-encrypted-metadata]",
        await encryptValue(JSON.stringify(metadata), key, metadataAad())
      )
      this.setHidden(
        "[data-nerve-encrypted-password]",
        await encryptValue(password, key, entryAad(metadata, "password"))
      )
      this.setHidden(
        "[data-nerve-encrypted-notes]",
        notes ? await encryptValue(notes, key, entryAad(metadata, "notes")) : null
      )

      // Never let the plaintext reach the server.
      this.setValue("[data-nerve-password-input]", "")
      this.setValue("[data-nerve-notes-input]", "")
      form.requestSubmit()
    } catch (_error) {
      this.setError("Could not encrypt this entry.")
    }
  },

  toggleReveal(button) {
    const id = button.dataset.nerveReveal
    const secretRow = this.el.querySelector(`[data-nerve-secret-row="${id}"]`)
    if (!secretRow) return

    if (!secretRow.classList.contains("hidden")) {
      secretRow.classList.add("hidden")
      return
    }

    if (!vaultSession.isUnlocked()) return this.setError("Unlock your master password first.")

    this.pushEvent("load_secret", { id }, (reply) => this.showSecret(button, secretRow, reply))
  },

  async showSecret(button, secretRow, reply) {
    if (!reply || reply.status !== "ok") return

    try {
      const key = await this.key()
      const row = button.closest("[data-encrypted-metadata]") || button
      const metadata = await this.decryptMetadata(row, key)

      const passwordOut = secretRow.querySelector("[data-nerve-password-output]")
      if (passwordOut && reply.encrypted_password) {
        passwordOut.textContent = await decryptValue(
          JSON.parse(reply.encrypted_password),
          key,
          entryAad(metadata, "password")
        )
      }

      const notesWrapper = secretRow.querySelector("[data-nerve-notes-wrapper]")
      const notesOut = secretRow.querySelector("[data-nerve-notes-output]")
      if (notesOut && reply.encrypted_notes) {
        notesOut.textContent = await decryptValue(
          JSON.parse(reply.encrypted_notes),
          key,
          entryAad(metadata, "notes")
        )
        notesWrapper && notesWrapper.classList.remove("hidden")
      }

      secretRow.classList.remove("hidden")
    } catch (_error) {
      this.setError("Could not decrypt this entry.")
    }
  },

  generatePassword() {
    const bytes = new Uint8Array(PASSWORD_LENGTH)
    crypto.getRandomValues(bytes)
    const password = Array.from(bytes, (b) => PASSWORD_ALPHABET[b % PASSWORD_ALPHABET.length]).join("")
    this.setValue("[data-nerve-password-input]", password)
    // Reveal it so the user can see/copy what was generated.
    this.setPasswordVisible(true)
  },

  togglePasswordVisibility() {
    const input = this.el.querySelector("[data-nerve-password-input]")
    this.setPasswordVisible(input && input.type === "password")
  },

  setPasswordVisible(visible) {
    const input = this.el.querySelector("[data-nerve-password-input]")
    if (!input) return
    input.type = visible ? "text" : "password"

    const show = this.el.querySelector("[data-nerve-eye-show]")
    const hide = this.el.querySelector("[data-nerve-eye-hide]")
    if (show) show.classList.toggle("hidden", visible)
    if (hide) hide.classList.toggle("hidden", !visible)
  },

  // --- small DOM helpers ---

  value(selector) {
    const el = this.el.querySelector(selector)
    return el ? el.value : ""
  },

  fieldValue(selector) {
    const el = this.el.querySelector(`#nerve-entry-form ${selector}`)
    return el ? el.value : ""
  },

  setValue(selector, value) {
    const el = this.el.querySelector(selector)
    if (el) el.value = value
  },

  setHidden(selector, payload) {
    this.setValue(selector, payload ? JSON.stringify(payload) : "")
  },

  setText(scope, selector, text) {
    const target = scope.querySelector(selector)
    if (target && typeof text === "string") target.textContent = text
  }
}
