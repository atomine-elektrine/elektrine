import {
  buildForwardBody,
  buildReplyBody,
  escapeHtml,
  formatAttachmentMeta,
  payloadString,
  prefixedSubject
} from "./mailbox_private_content"
import {
  decryptAttachmentPayload,
  decryptMessagePayload,
  getStoredPrivateKey,
  maybeSetValue,
  parsePayload
} from "./mailbox_private_storage_hooks"

export const PrivateMailboxCompose = {
  mounted() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.mode = this.el.dataset.privateComposeMode
    this.messageEnvelope = parsePayload(this.el.dataset.privateOriginalPayload)
    this.attachments = parsePayload(this.el.dataset.privateOriginalAttachments) || {}
    this.metadata = {
      from: this.el.dataset.privateOriginalFrom || "",
      to: this.el.dataset.privateOriginalTo || "",
      cc: this.el.dataset.privateOriginalCc || "",
      bcc: this.el.dataset.privateOriginalBcc || "",
      status: this.el.dataset.privateOriginalStatus || "",
      insertedAt: this.el.dataset.privateOriginalInsertedAt || ""
    }

    this.onMailboxChange = () => this.applyPrefill()
    window.addEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.addEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)

    this.applyPrefill()
  },

  updated() {
    this.applyPrefill()
  },

  destroyed() {
    window.removeEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.removeEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)
  },

  get subjectInput() {
    return document.querySelector("input[name='email[subject]']")
  },

  get hiddenBodyInput() {
    return document.querySelector("[data-private-compose-hidden-body]")
  },

  get previewElement() {
    return document.querySelector("[data-private-compose-preview]")
  },

  get privateForwardAttachmentsInput() {
    return document.querySelector("#private-forward-attachments")
  },

  get attachmentsPreview() {
    return document.querySelector("[data-private-compose-attachments-preview]")
  },

  renderLockedAttachments() {
    if (!this.attachmentsPreview || this.mode !== "forward") return

    const hasPrivateAttachments = Object.values(this.attachments).some((attachment) =>
      Boolean(attachment?.private_encrypted_payload)
    )

    if (!hasPrivateAttachments) return

    this.attachmentsPreview.innerHTML = `
      <div class="rounded border border-base-300 bg-base-200 p-3 text-sm text-base-content/70">
        Unlock the mailbox in this tab to include protected attachments in the forwarded message.
      </div>
    `
  },

  async applyPrefill() {
    if (!this.mailboxId || !this.messageEnvelope) return

    if (!getStoredPrivateKey(this.mailboxId)) {
      this.renderLockedAttachments()
      if (this.privateForwardAttachmentsInput) {
        this.privateForwardAttachmentsInput.value = ""
      }
      return
    }

    try {
      const payload = await decryptMessagePayload(this.messageEnvelope, this.mailboxId)
      if (!payload) return

      const originalSubject = typeof payload.subject === "string" ? payload.subject : ""
      const subject = prefixedSubject(this.mode, originalSubject)
      const metadata = {
        ...this.metadata,
        from: payloadString(payload, "from") || this.metadata.from,
        to: payloadString(payload, "to") || this.metadata.to,
        cc: payloadString(payload, "cc") || this.metadata.cc,
        bcc: payloadString(payload, "bcc") || this.metadata.bcc
      }

      maybeSetValue(this.subjectInput, subject, (currentValue) =>
        currentValue.includes("Encrypted message")
      )

      const decryptedAttachments = await this.decryptForwardAttachments()

      const body =
        this.mode === "forward"
          ? buildForwardBody(payload, metadata, decryptedAttachments)
          : buildReplyBody(payload, metadata)

      const protectedForwardAttachments = decryptedAttachments.filter((attachment) => attachment.data)

      if (this.hiddenBodyInput) {
        this.hiddenBodyInput.value = body
      }

      if (this.previewElement) {
        this.previewElement.textContent = body
      }

      if (this.privateForwardAttachmentsInput) {
        this.privateForwardAttachmentsInput.value = JSON.stringify(protectedForwardAttachments)
      }

      this.renderForwardAttachments(decryptedAttachments)
    } catch (_error) {
      this.renderLockedAttachments()
    }
  },

  async decryptForwardAttachments() {
    const attachments = Object.entries(this.attachments || {})
    if (attachments.length === 0) return []

    const decrypted = await Promise.all(
      attachments.map(async ([attachmentId, attachment]) => {
        if (!attachment?.private_encrypted_payload) {
          return {
            attachment_id: attachmentId,
            filename: attachment.filename || "attachment",
            content_type: attachment.content_type || "application/octet-stream",
            size: attachment.size || 0
          }
        }

        const payload = await decryptAttachmentPayload(attachment.private_encrypted_payload, this.mailboxId)

        return {
          attachment_id: attachmentId,
          filename: payload.filename || "attachment",
          content_type: payload.content_type || "application/octet-stream",
          size: payload.size || 0,
          encoding: payload.encoding || "base64",
          data: payload.data || ""
        }
      })
    )

    return decrypted
  },

  renderForwardAttachments(attachments) {
    if (!this.attachmentsPreview || this.mode !== "forward") return

    if (attachments.length === 0) {
      this.attachmentsPreview.innerHTML = ""
      return
    }

    this.attachmentsPreview.innerHTML = attachments
      .map(
        (attachment) => `
          <div class="flex items-center justify-between p-2 bg-base-200 rounded border border-base-300">
            <div class="flex items-center gap-2">
              <div class="text-base-content/60">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 24 24" fill="currentColor"><path d="M19.5 8.25V18A2.25 2.25 0 0 1 17.25 20.25H6.75A2.25 2.25 0 0 1 4.5 18V6A2.25 2.25 0 0 1 6.75 3.75h7.5L19.5 8.25Z"/><path d="M14.25 3.75V8.25H18.75"/></svg>
              </div>
              <div>
                <p class="text-sm font-medium">${escapeHtml(attachment.filename || "attachment")}</p>
                <p class="text-xs text-base-content/60">${escapeHtml(formatAttachmentMeta(attachment))}</p>
              </div>
            </div>
            <div class="badge badge-success badge-sm">Will be forwarded</div>
          </div>
        `
      )
      .join("")
  }
}
