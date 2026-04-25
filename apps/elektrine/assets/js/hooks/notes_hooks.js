const textEncoder = new TextEncoder()

function bytesToBase64Url(bytes) {
  let binary = ""

  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }

  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")
}

async function encryptNotePayload(payload) {
  const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, [
    "encrypt",
    "decrypt",
  ])
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const plaintext = textEncoder.encode(JSON.stringify(payload))
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext))
  const rawKey = new Uint8Array(await crypto.subtle.exportKey("raw", key))

  return {
    key: bytesToBase64Url(rawKey),
    envelope: {
      version: 1,
      algorithm: "AES-GCM-256",
      iv: bytesToBase64Url(iv),
      ciphertext: bytesToBase64Url(ciphertext),
    },
  }
}

export const EncryptedNoteShare = {
  mounted() {
    this.handleClick = async (event) => {
      event.preventDefault()

      if (!window.crypto?.subtle) {
        window.showNotification?.("This browser does not support Web Crypto.", "error")
        return
      }

      const noteId = this.el.dataset.noteId
      const titleInput = document.querySelector('[name="note[title]"]')
      const bodyInput = document.querySelector('[name="note[body]"]')
      const expiresInInput = document.getElementById("encrypted-note-expires-in")
      const burnAfterReadInput = document.getElementById("encrypted-note-burn-after-read")

      try {
        this.el.disabled = true
        const { key, envelope } = await encryptNotePayload({
          title: titleInput?.value || "",
          body: bodyInput?.value || "",
          created_at: new Date().toISOString(),
        })

        this.pushEvent("create_encrypted_share", {
          id: noteId,
          payload: envelope,
          key,
          expires_in: expiresInInput?.value || "1d",
          burn_after_read: Boolean(burnAfterReadInput?.checked),
        }, (reply) => {
          if (reply?.url) {
            const output = document.getElementById(this.el.dataset.outputId)

            if (output) {
              output.value = reply.url
              output.closest("[data-encrypted-share-output]")?.classList.remove("hidden")
            }

            navigator.clipboard?.writeText(reply.url).catch(() => {})
            window.showNotification?.("Encrypted share link copied.", "success")
          } else {
            window.showNotification?.(reply?.error || "Could not create encrypted share link.", "error")
          }
        })
      } catch (_error) {
        window.showNotification?.("Could not encrypt this note.", "error")
      } finally {
        this.el.disabled = false
      }
    }

    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },
}
