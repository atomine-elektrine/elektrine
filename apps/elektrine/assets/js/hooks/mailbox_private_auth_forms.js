import { submitFormPreservingEvents } from "../utils/form_submission"
import {
  VERIFY_TEXT,
  cacheLoginPassword,
  encoder,
  notify,
  parsePayload,
  unwrapMailboxPrivateKey,
  wrapBytes
} from "./mailbox_private_storage_hooks"

function bindPrivateMailboxLoginForm(form) {
  if (!form || form.dataset.privateMailboxLoginBound === "true") return

  form.addEventListener("submit", () => {
    const passwordInput = form.querySelector("input[name='user[password]']")
    const password = passwordInput?.value || ""

    if (password.trim() !== "") {
      cacheLoginPassword(password)
    }
  })

  form.dataset.privateMailboxLoginBound = "true"
}

function bindPrivateMailboxPasswordForm(form) {
  if (!form || form.dataset.privateMailboxPasswordBound === "true") return

  form.addEventListener("submit", async (event) => {
    if (form.dataset.privateMailboxRewrapSubmitting === "true") {
      return
    }

    const configured = form.dataset.privateMailboxConfigured === "true"
    const unlockMode = form.dataset.privateMailboxUnlockMode || "separate_passphrase"

    if (!configured || unlockMode !== "account_password") {
      return
    }

    const currentPassword = form.querySelector("input[name='user[current_password]']")?.value || ""
    const newPassword = form.querySelector("input[name='user[password]']")?.value || ""

    if (currentPassword.trim() === "" || newPassword.trim() === "") {
      return
    }

    const wrappedKeyPayload = parsePayload(form.dataset.privateMailboxWrappedKey)
    const verifierPayload = parsePayload(form.dataset.privateMailboxVerifier)

    if (!wrappedKeyPayload || !verifierPayload) {
      event.preventDefault()
      notify("Private mailbox rewrap data is unavailable. Reload and try again.")
      return
    }

    const wrappedKeyField = form.querySelector(
      "input[name='user[private_mailbox_wrapped_private_key]']"
    )
    const verifierField = form.querySelector("input[name='user[private_mailbox_verifier]']")
    const unlockModeField = form.querySelector("input[name='user[private_mailbox_unlock_mode]']")

    if (!wrappedKeyField || !verifierField || !unlockModeField) {
      event.preventDefault()
      notify("Private mailbox password update fields are missing. Reload and try again.")
      return
    }

    try {
      event.preventDefault()

      const privateKeyBytes = await unwrapMailboxPrivateKey(
        wrappedKeyPayload,
        verifierPayload,
        currentPassword
      )
      const nextWrappedKey = await wrapBytes(privateKeyBytes, newPassword, "account_password")
      const nextVerifier = await wrapBytes(
        encoder.encode(VERIFY_TEXT),
        newPassword,
        "account_password",
        "verifier"
      )

      wrappedKeyField.value = JSON.stringify(nextWrappedKey)
      verifierField.value = JSON.stringify(nextVerifier)
      unlockModeField.value = "account_password"
      cacheLoginPassword(newPassword)

      form.dataset.privateMailboxRewrapSubmitting = "true"
      submitFormPreservingEvents(form)
    } catch (_error) {
      notify(
        "Could not rewrap your private mailbox with the new password. Check your current password and try again."
      )
    }
  })

  form.dataset.privateMailboxPasswordBound = "true"
}

export function initPrivateMailboxAuthForms(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === "function" ? rootCandidate : document

  root
    .querySelectorAll("[data-private-mailbox-login-form='true']")
    .forEach((form) => bindPrivateMailboxLoginForm(form))

  root
    .querySelectorAll("[data-private-mailbox-password-form='true']")
    .forEach((form) => bindPrivateMailboxPasswordForm(form))
}
