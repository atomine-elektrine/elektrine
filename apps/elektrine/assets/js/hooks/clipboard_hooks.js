import { copyToClipboard } from '../utils/clipboard'

function resolveCopyText(el) {
  if (el.dataset.content) {
    return el.dataset.content
  }

  if (el.dataset.copyTarget) {
    const target = document.getElementById(el.dataset.copyTarget)
    if (target) {
      if ('value' in target && typeof target.value === 'string') {
        return target.value
      }

      return target.textContent
    }
  }

  const emailElement = document.getElementById('email-address')
  if (emailElement) {
    return emailElement.textContent
  }

  return ''
}

function showTemporaryCopySuccess(el, onDone = null) {
  el.classList.add('btn-success')
  el.dataset.copied = 'true'

  return setTimeout(() => {
    el.classList.remove('btn-success')
    delete el.dataset.copied
    if (typeof onDone === 'function') onDone()
  }, 2000)
}

export const CopyEmail = {
  mounted() {
    this.onClick = (e) => {
      e.preventDefault()
      const email = this.el.dataset.email

      if (email) {
        copyToClipboard(email, 'email').then(copied => {
          if (!copied) return

          const icon = this.el.querySelector('span')
          if (icon) {
            const originalClass = icon.className
            icon.className = 'hero-check w-3 h-3'

            this.copySuccessTimer = setTimeout(() => {
              icon.className = originalClass
              this.copySuccessTimer = null
            }, 2000)
          }
        }).catch(() => {})
      }
    }

    this.el.addEventListener('click', this.onClick)
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener('click', this.onClick)
    if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
  }
}

export const CopyToClipboard = {
  mounted() {
    this.onClick = e => {
      e.preventDefault()

      const textToCopy = resolveCopyText(this.el)

      if (textToCopy) {
        copyToClipboard(textToCopy).then(copied => {
          if (copied) {
            if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
            this.copySuccessTimer = showTemporaryCopySuccess(this.el, () => {
              this.copySuccessTimer = null
            })
          }
        }).catch(() => {})
      }
    }

    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
  }
}

export const CopyButton = {
  mounted() {
    this.handleEvent("copy_to_clipboard", ({ text }) => {
      copyToClipboard(text).then(copied => {
        if (copied) {
          this.showSuccess()
        }
      }).catch(() => {})
    })
  },

  showSuccess() {
    if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
    this.el.classList.remove('btn-primary')
    this.el.classList.add('btn-success')
    this.el.dataset.copied = 'true'

    this.copySuccessTimer = setTimeout(() => {
      this.el.classList.remove('btn-success')
      this.el.classList.add('btn-primary')
      delete this.el.dataset.copied
      this.copySuccessTimer = null
    }, 2000)
  },

  destroyed() {
    if (this.copySuccessTimer) clearTimeout(this.copySuccessTimer)
  }
}
