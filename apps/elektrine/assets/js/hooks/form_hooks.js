/**
 * Form Hooks
 * Hooks for form inputs, tag inputs, and autocomplete functionality.
 */
import { spinnerSvg } from '../utils/spinner'

/**
 * FormSubmit Hook
 * Shows loading spinner on form submit buttons when the form is submitted.
 * Attach to forms with regular (non-LiveView) submissions.
 */
export const FormSubmit = {
  mounted() {
    this.el.addEventListener('submit', (e) => {
      if (e.defaultPrevented) return

      const submitBtn = this.el.querySelector('button[type="submit"], button:not([type])')
      if (submitBtn) {
        // Store original content
        const originalContent = submitBtn.innerHTML

        // Get loading text from data attribute or use original
        const loadingText = submitBtn.dataset.loadingText || submitBtn.textContent.trim()

        // Replace with spinner and loading text
        submitBtn.innerHTML = `${spinnerSvg()}<span>${loadingText}</span>`
        submitBtn.disabled = true
        submitBtn.classList.add('pointer-events-none')

        // Restore after timeout (in case of network issues)
        setTimeout(() => {
          submitBtn.innerHTML = originalContent
          submitBtn.disabled = false
          submitBtn.classList.remove('pointer-events-none')
        }, 30000)
      }
    })
  }
}

/**
 * Tag Input Hook
 * Sends input value to LiveView on change
 */
export const TagInputHook = {
  mounted() {
    this.handleEvent("clear-tag-input", ({ field }) => {
      if (field === this.el.dataset.field) {
        this.el.value = ''
      }
    })

    this.el.addEventListener('input', (e) => {
      this.pushEvent("update_tag_input", {
        field: this.el.dataset.field,
        value: e.target.value
      })
    })
  }
}

/**
 * Suggestion Dropdown Hook
 * Handles mousedown events on suggestions (fires before blur)
 */
export const SuggestionDropdown = {
  mounted() {
    this.el.addEventListener('mousedown', (e) => {
      const suggestionEl = e.target.closest('[data-suggestion-email]')
      if (suggestionEl) {
        const email = suggestionEl.dataset.suggestionEmail
        const field = suggestionEl.dataset.suggestionField

        const inputId = field + '-tag-input'
        const inputEl = document.getElementById(inputId)
        if (inputEl) inputEl.value = ''

        this.pushEvent("select_suggestion", { field, email })
        e.preventDefault()
      }
    })
  }
}

export function detectAndSaveTimezone(element = null) {
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
  document.cookie = `detected_timezone=${timezone}; path=/; max-age=31536000; SameSite=Lax`

  if (element) {
    element.dataset.lastSent = timezone
  }
}

export function initTimezoneDetectors(rootCandidate = document) {
  const root =
    rootCandidate && typeof rootCandidate.querySelectorAll === 'function' ? rootCandidate : document

  root.querySelectorAll('[data-timezone-detector]').forEach((element) => {
    detectAndSaveTimezone(element)
  })
}

/**
 * VPN Download Hook
 * Handles downloading WireGuard configuration files
 */
export const VPNDownload = {
  mounted() {
    this.handleEvent("download_config", ({ filename, content }) => {
      const blob = new Blob([content], { type: 'text/plain' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)

      if (window.showNotification) {
        window.showNotification('VPN configuration downloaded', 'info', 'Success!')
      }
    })
  }
}

/**
 * Turnstile Hook
 * Cloudflare Turnstile CAPTCHA integration
 */
export const Turnstile = {
  mounted() {
    this.form = this.el.closest('form') || document.getElementById('register-form')
    this.handleSubmit = (event) => {
      if (!this.responseToken()) {
        event.preventDefault()
        this.showError('Please complete the security verification before submitting.')
      }
    }

    if (this.form) {
      this.form.addEventListener('submit', this.handleSubmit, true)
    }

    this.renderWidget()
  },

  updated() {
    // Re-render if the widget was removed (e.g., after form submission error)
    if (!this.el.querySelector('iframe')) {
      this.renderWidget()
    }
  },

  renderWidget() {
    const sitekey = this.el.dataset.sitekey
    const theme = this.el.dataset.theme || 'auto'
    const size = this.el.dataset.size || 'normal'

    // Find the form element to append hidden input
    let form = this.form || this.el.closest('form')
    if (!form) {
      form = document.getElementById('register-form')
    }
    if (!form) {
      console.error('Turnstile: Could not find parent form element')
      return
    }

    // Check if sitekey is missing
    if (!sitekey) {
      console.error('Turnstile: No sitekey provided')
      this.el.innerHTML = '<div class="text-error text-sm p-2 bg-error/10 rounded">Security verification not configured.</div>'
      return
    }

    // Check if Turnstile script is loaded
    if (typeof window.turnstile !== 'undefined') {
      // Only remove if we have an existing widget ID
      if (this.widgetId) {
        try {
          window.turnstile.remove(this.widgetId)
        } catch (e) {
          // Ignore removal errors
        }
        this.widgetId = null
      }

      // Render new widget
      try {
        this.ensureResponseInput(form)
        this.setResponseToken('')

        this.widgetId = window.turnstile.render(this.el, {
          sitekey: sitekey,
          theme: theme,
          size: size,
          callback: (token) => {
            this.ensureResponseInput(form)
            this.setResponseToken(token)

            this.clearError()
          },
          'error-callback': (errorCode) => {
            console.error('Turnstile error:', errorCode)

            this.setResponseToken('')

            this.showError('Verification unavailable. Please try again or refresh the page.')
          },
          'expired-callback': () => {
            // Token expired, clear the hidden input
            this.setResponseToken('')
          }
        })
      } catch (e) {
        console.error('Turnstile render error:', e)
      }
    } else {
      // Script not loaded yet, wait and retry
      this.retryCount = (this.retryCount || 0) + 1
      if (this.retryCount < 10) {
        setTimeout(() => this.renderWidget(), 500)
      } else {
        console.error('Turnstile: Script failed to load after 10 retries')
        // Show error message to user
        this.el.innerHTML = '<div class="text-error text-sm p-2 bg-error/10 rounded">Security verification failed to load. Please refresh the page.</div>'
      }
    }
  },

  responseInput() {
    return this.form?.querySelector('input[name="cf-turnstile-response"]')
  },

  responseInputs() {
    return Array.from(this.form?.querySelectorAll('input[name="cf-turnstile-response"]') || [])
  },

  responseToken() {
    return this.responseInputs().find((input) => input.value)?.value || ''
  },

  setResponseToken(token) {
    this.responseInputs().forEach((input) => {
      input.value = token
    })
  },

  ensureResponseInput(form) {
    let input = form.querySelector('input[name="cf-turnstile-response"]')

    if (!input) {
      input = document.createElement('input')
      input.type = 'hidden'
      input.name = 'cf-turnstile-response'
      form.appendChild(input)
    }

    input.id = 'cf-turnstile-response'
    return input
  },

  showError(message) {
    let error = this.el.parentElement?.querySelector('[data-turnstile-error="true"]')
    if (!error && this.el.parentElement) {
      error = document.createElement('div')
      error.className = 'text-warning text-xs mt-1'
      error.dataset.turnstileError = 'true'
      this.el.parentElement.appendChild(error)
    }
    if (error) error.textContent = message
  },

  clearError() {
    const error = this.el.parentElement?.querySelector('[data-turnstile-error="true"]')
    if (error) error.remove()
  },

  destroyed() {
    if (this.form && this.handleSubmit) {
      this.form.removeEventListener('submit', this.handleSubmit, true)
    }

    if (typeof window.turnstile !== 'undefined' && this.widgetId) {
      window.turnstile.remove(this.widgetId)
    }
  }
}
