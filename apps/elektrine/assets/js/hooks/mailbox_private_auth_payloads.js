import { parsePayload } from "./mailbox_private_crypto"

function value(form, selector) {
  return form.querySelector(selector)?.value || ""
}

export function readPasswordUpdateContext(form) {
  const vaultConfigured = form.dataset.vaultConfigured === "true"
  const configured = form.dataset.privateMailboxConfigured === "true"
  const unlockMode = form.dataset.privateMailboxUnlockMode || "separate_passphrase"

  return {
    vaultConfigured,
    configured,
    unlockMode,
    shouldRewrapMailbox: configured && unlockMode === "account_password",
    currentPassword: value(form, "input[name='user[current_password]']"),
    newPassword: value(form, "input[name='user[password]']"),
    vaultWrappedDek: parsePayload(form.dataset.vaultWrappedDek),
    vaultWrappedDekRecovery: parsePayload(form.dataset.vaultWrappedDekRecovery),
    wrappedKeyPayload: parsePayload(form.dataset.privateMailboxWrappedKey),
    verifierPayload: parsePayload(form.dataset.privateMailboxVerifier)
  }
}

export function readVaultFields(form) {
  return {
    wrappedDekField: form.querySelector("input[name='user[vault_wrapped_dek]']"),
    wrappedDekRecoveryField: form.querySelector(
      "input[name='user[vault_wrapped_dek_recovery]']"
    )
  }
}

export function readMailboxFields(form) {
  return {
    wrappedKeyField: form.querySelector("input[name='user[private_mailbox_wrapped_private_key]']"),
    verifierField: form.querySelector("input[name='user[private_mailbox_verifier]']"),
    unlockModeField: form.querySelector("input[name='user[private_mailbox_unlock_mode]']")
  }
}

export function shouldHandlePasswordUpdate(context) {
  return context.vaultConfigured || (context.configured && context.unlockMode === "account_password")
}

export function passwordUpdateValidationError(context, vaultFields, mailboxFields) {
  if (context.vaultConfigured && (!context.vaultWrappedDek || !context.vaultWrappedDekRecovery)) {
    return "Encrypted data update is unavailable. Reload and try again."
  }

  if (context.vaultConfigured && (!vaultFields.wrappedDekField || !vaultFields.wrappedDekRecoveryField)) {
    return "Encrypted data update fields are missing. Reload and try again."
  }

  if (context.shouldRewrapMailbox && (!context.wrappedKeyPayload || !context.verifierPayload)) {
    return "Private mailbox rewrap data is unavailable. Reload and try again."
  }

  if (
    context.shouldRewrapMailbox &&
    (!mailboxFields.wrappedKeyField || !mailboxFields.verifierField || !mailboxFields.unlockModeField)
  ) {
    return "Private mailbox password update fields are missing. Reload and try again."
  }

  return null
}
