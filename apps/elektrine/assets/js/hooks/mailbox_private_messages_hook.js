import {
  bodyText,
  buildSandboxedEmailHtml,
  downloadBytes,
  formatAttachmentMeta,
  payloadString,
  previewText,
  restoreAttachmentPlaceholder,
  sanitizeProtectedHtml
} from "./mailbox_private_content"
import {
  decryptAttachmentPayload,
  decryptMessagePayload,
  getStoredPrivateKey,
  notify,
  parsePayload
} from "./mailbox_private_storage_hooks"

const decryptedAttachments = new WeakMap()

export const PrivateMailboxMessages = {
  mounted() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.onMailboxChange = () => this.renderPrivateContent()
    this.onClick = (event) => this.handleClick(event)

    window.addEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.addEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)
    this.el.addEventListener("click", this.onClick)

    this.renderPrivateContent()
  },

  updated() {
    this.mailboxId = this.el.dataset.privateMailboxId
    this.renderPrivateContent()
  },

  destroyed() {
    window.removeEventListener("elektrine:private-mailbox-unlocked", this.onMailboxChange)
    window.removeEventListener("elektrine:private-mailbox-locked", this.onMailboxChange)
    this.el.removeEventListener("click", this.onClick)
  },

  async handleClick(event) {
    const downloadButton = event.target.closest("[data-private-attachment-download]")
    if (!downloadButton) return

    event.preventDefault()

    const attachmentElement = downloadButton.closest("[data-private-attachment='true']")
    if (!attachmentElement || !this.mailboxId || !getStoredPrivateKey(this.mailboxId)) {
      notify("Unlock your mailbox before downloading protected attachments.")
      return
    }

    try {
      const payload = await this.decryptAttachmentElement(attachmentElement)
      if (!payload?.data) {
        notify("This protected attachment could not be decrypted.")
        return
      }

      downloadBytes(payload.filename, payload.content_type, payload.data)
    } catch (_error) {
      notify("Failed to decrypt this protected attachment.")
    }
  },

  async decryptAttachmentElement(element) {
    const cached = decryptedAttachments.get(element)
    if (cached) return cached

    const envelope = parsePayload(element.dataset.privateAttachmentPayload)
    if (!envelope) return null

    const payload = await decryptAttachmentPayload(envelope, this.mailboxId)
    if (payload) {
      decryptedAttachments.set(element, payload)
    }

    return payload
  },

  async renderPrivateContent() {
    const messageElements = Array.from(this.el.querySelectorAll("[data-private-message='true']"))
    const attachmentElements = Array.from(
      this.el.querySelectorAll("[data-private-attachment='true']")
    )
    const standaloneAddressElements = Array.from(
      this.el.querySelectorAll("[data-private-address-payload]")
    )

    if (!this.mailboxId || !getStoredPrivateKey(this.mailboxId)) {
      this.restorePlaceholders(messageElements)
      standaloneAddressElements.forEach((element) => this.restoreAddressPlaceholder(element))
      attachmentElements.forEach((element) => restoreAttachmentPlaceholder(element))
      return
    }

    await Promise.all(
      messageElements.map(async (element) => {
        const envelope = parsePayload(element.dataset.privateMessagePayload)
        if (!envelope) return

        try {
          const payload = await decryptMessagePayload(envelope, this.mailboxId)
          if (!payload) return

          const subjectEl = element.querySelector("[data-private-subject]")
          if (subjectEl) {
            const subject = typeof payload.subject === "string" ? payload.subject.trim() : ""
            subjectEl.textContent = subject || "(No Subject)"
          }

          const previewEl = element.querySelector("[data-private-preview]")
          if (previewEl) {
            previewEl.textContent = previewText(payload)
          }

          element.querySelectorAll("[data-private-address]").forEach((addressEl) => {
            const field = addressEl.dataset.privateAddress
            const value = payloadString(payload, field).trim()

            if (value) {
              addressEl.textContent = value
            }
          })

          const bodyEl = element.querySelector("[data-private-body]")
          const iframe = element.querySelector("[data-private-html-body-iframe]")
          const iframeContainer = element.querySelector("[data-private-html-body-container]")

          if (bodyEl) {
            bodyEl.textContent = bodyText(payload)
          }

          if (iframe && iframeContainer && typeof payload.html_body === "string" && payload.html_body.trim() !== "") {
            iframe.srcdoc = buildSandboxedEmailHtml(sanitizeProtectedHtml(payload.html_body))
            iframeContainer.classList.remove("hidden")

            if (bodyEl) {
              bodyEl.classList.add("hidden")
            }
          } else if (iframe && iframeContainer) {
            iframe.srcdoc = ""
            iframeContainer.classList.add("hidden")

            if (bodyEl) {
              bodyEl.classList.remove("hidden")
            }
          }
        } catch (_error) {
          this.restorePlaceholderForElement(element)
        }
      })
    )

    await Promise.all(
      standaloneAddressElements.map(async (element) => {
        const envelope = parsePayload(element.dataset.privateAddressPayload)
        if (!envelope) return

        try {
          const payload = await decryptMessagePayload(envelope, this.mailboxId)
          const value = payloadString(payload, element.dataset.privateAddress).trim()

          if (value) {
            element.textContent = value
          }
        } catch (_error) {
          this.restoreAddressPlaceholder(element)
        }
      })
    )

    await Promise.all(
      attachmentElements.map(async (element) => {
        try {
          const payload = await this.decryptAttachmentElement(element)
          if (!payload) return

          const filenameEl = element.querySelector("[data-private-attachment-filename]")
          if (filenameEl) {
            filenameEl.textContent = payload.filename || "attachment"
          }

          const metaEl = element.querySelector("[data-private-attachment-meta]")
          if (metaEl) {
            metaEl.textContent = formatAttachmentMeta(payload)
          }

          const labelEl = element.querySelector("[data-private-attachment-download-label]")
          if (labelEl) {
            labelEl.textContent = "Download"
          }
        } catch (_error) {
          restoreAttachmentPlaceholder(element)
        }
      })
    )
  },

  restorePlaceholders(elements) {
    elements.forEach((element) => this.restorePlaceholderForElement(element))
  },

  restorePlaceholderForElement(element) {
    const subjectEl = element.querySelector("[data-private-subject]")
    if (subjectEl && subjectEl.dataset.privateSubjectPlaceholder) {
      subjectEl.textContent = subjectEl.dataset.privateSubjectPlaceholder
    }

    const previewEl = element.querySelector("[data-private-preview]")
    if (previewEl && previewEl.dataset.privatePreviewPlaceholder) {
      previewEl.textContent = previewEl.dataset.privatePreviewPlaceholder
    }

    element.querySelectorAll("[data-private-address]").forEach((addressEl) => {
      this.restoreAddressPlaceholder(addressEl)
    })

    const bodyEl = element.querySelector("[data-private-body]")
    if (bodyEl && bodyEl.dataset.privateBodyPlaceholder) {
      bodyEl.textContent = bodyEl.dataset.privateBodyPlaceholder
      bodyEl.classList.remove("hidden")
    }

    const iframe = element.querySelector("[data-private-html-body-iframe]")
    const iframeContainer = element.querySelector("[data-private-html-body-container]")
    if (iframe && iframeContainer) {
      iframe.srcdoc = ""
      iframeContainer.classList.add("hidden")
    }
  },

  restoreAddressPlaceholder(addressEl) {
    if (addressEl.dataset.privateAddressPlaceholder) {
      addressEl.textContent = addressEl.dataset.privateAddressPlaceholder
    }
  }
}
