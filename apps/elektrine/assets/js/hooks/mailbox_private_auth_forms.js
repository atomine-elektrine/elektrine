import { submitFormPreservingEvents } from "../utils/form_submission"
import {
  readMailboxFields,
  readPasswordUpdateContext,
  readVaultFields,
  passwordUpdateValidationError,
  shouldHandlePasswordUpdate
} from "./mailbox_private_auth_payloads"
import { unwrapWithSecret, wrapWithSecret } from "./vault_crypto"
import {
  VERIFY_TEXT,
  cacheLoginPassword,
  encoder,
  notify,
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

    const context = readPasswordUpdateContext(form)

    if (!shouldHandlePasswordUpdate(context)) return
    if (context.currentPassword.trim() === "" || context.newPassword.trim() === "") return

    const vaultFields = readVaultFields(form)
    const mailboxFields = readMailboxFields(form)
    const validationError = passwordUpdateValidationError(context, vaultFields, mailboxFields)

    if (validationError) {
      event.preventDefault()
      notify(validationError)
      return
    }

    try {
      event.preventDefault()

      if (context.vaultConfigured) {
        const mdk = await unwrapWithSecret(context.vaultWrappedDek, context.currentPassword)
        vaultFields.wrappedDekField.value = JSON.stringify(
          await wrapWithSecret(mdk, context.newPassword)
        )
        vaultFields.wrappedDekRecoveryField.value = JSON.stringify(context.vaultWrappedDekRecovery)
      }

      if (context.shouldRewrapMailbox) {
        const privateKeyBytes = await unwrapMailboxPrivateKey(
          context.wrappedKeyPayload,
          context.verifierPayload,
          context.currentPassword
        )
        const nextWrappedKey = await wrapBytes(privateKeyBytes, context.newPassword, "account_password")
        const nextVerifier = await wrapBytes(
          encoder.encode(VERIFY_TEXT),
          context.newPassword,
          "account_password",
          "verifier"
        )

        mailboxFields.wrappedKeyField.value = JSON.stringify(nextWrappedKey)
        mailboxFields.verifierField.value = JSON.stringify(nextVerifier)
        mailboxFields.unlockModeField.value = "account_password"
      }

      cacheLoginPassword(context.newPassword)

      form.dataset.privateMailboxRewrapSubmitting = "true"
      submitFormPreservingEvents(form)
    } catch (_error) {
      notify(
        "Could not update encrypted data for the new password. Check your current password and try again."
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
