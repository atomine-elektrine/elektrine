/**
 * Form Hooks
 * Hooks for form inputs, tag inputs, and autocomplete functionality.
 */

const SPINNER_SVG =
  '<svg class="w-5 h-5 animate-spin" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="currentColor" aria-hidden="true"><path d="M12 2a1 1 0 0 1 1 1v2a1 1 0 1 1-2 0V3a1 1 0 0 1 1-1Zm0 16a1 1 0 0 1 1 1v2a1 1 0 1 1-2 0v-2a1 1 0 0 1 1-1Zm10-7a1 1 0 1 1 0 2h-2a1 1 0 1 1 0-2h2ZM4 11a1 1 0 1 1 0 2H2a1 1 0 1 1 0-2h2Zm15.07-5.66a1 1 0 0 1 1.41 1.41l-1.41 1.42a1 1 0 1 1-1.41-1.42l1.41-1.41ZM6.34 17.66a1 1 0 1 1 1.41 1.41l-1.41 1.42a1 1 0 0 1-1.41-1.42l1.41-1.41Zm13.15 1.42a1 1 0 0 1-1.41 0l-1.42-1.42a1 1 0 1 1 1.42-1.41l1.41 1.41a1 1 0 0 1 0 1.42ZM7.76 7.08A1 1 0 1 1 6.34 8.5L4.93 7.08a1 1 0 1 1 1.41-1.41l1.42 1.41Z"/></svg>'

/**
 * FormSubmit Hook
 * Shows loading spinner on form submit buttons when the form is submitted.
 * Attach to forms with regular (non-LiveView) submissions.
 */
export const FormSubmit = {
  mounted() {
    this.el.addEventListener('submit', (e) => {
      const submitBtn = this.el.querySelector('button[type="submit"], button:not([type])')
      if (submitBtn) {
        // Store original content
        const originalContent = submitBtn.innerHTML

        // Get loading text from data attribute or use original
        const loadingText = submitBtn.dataset.loadingText || submitBtn.textContent.trim()

        // Replace with spinner and loading text
        submitBtn.innerHTML = `${SPINNER_SVG}<span>${loadingText}</span>`
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

/**
 * Timezone Detector Hook
 * Detects user's timezone and saves to cookie
 */
export const TimezoneDetector = {
  mounted() {
    this.detectAndSave()
  },

  updated() {
    this.detectAndSave()
  },

  detectAndSave() {
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
    document.cookie = `detected_timezone=${timezone}; path=/; max-age=31536000; SameSite=Lax`
    this.el.dataset.lastSent = timezone
  }
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
    let form = this.el.closest('form')
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
        this.widgetId = window.turnstile.render(this.el, {
          sitekey: sitekey,
          theme: theme,
          size: size,
          callback: (token) => {
            // Find the hidden input (should exist in the template)
            let input = document.getElementById('cf-turnstile-response')
            if (!input) {
              input = form.querySelector('input[name="cf-turnstile-response"]')
            }
            if (!input) {
              // Fallback: create it
              input = document.createElement('input')
              input.type = 'hidden'
              input.name = 'cf-turnstile-response'
              input.id = 'cf-turnstile-response'
              form.appendChild(input)
            }
            input.value = token

            const existingError = this.el.parentElement?.querySelector('[data-turnstile-error="true"]')
            if (existingError) {
              existingError.remove()
            }
          },
          'error-callback': (errorCode) => {
            console.error('Turnstile error:', errorCode)

            const input = form.querySelector('input[name="cf-turnstile-response"]')
            if (input) input.value = ''

            const existingError = this.el.parentElement?.querySelector('[data-turnstile-error="true"]')
            if (!existingError) {
              // Show user-friendly error once to avoid repeated messages on retry loops
              const errorDiv = document.createElement('div')
              errorDiv.className = 'text-warning text-xs mt-1'
              errorDiv.dataset.turnstileError = 'true'
              errorDiv.textContent = 'Verification unavailable. You may still submit the form.'
              this.el.parentElement.appendChild(errorDiv)
            }
          },
          'expired-callback': () => {
            // Token expired, clear the hidden input
            const input = form.querySelector('input[name="cf-turnstile-response"]')
            if (input) input.value = ''
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

  destroyed() {
    if (typeof window.turnstile !== 'undefined' && this.widgetId) {
      window.turnstile.remove(this.widgetId)
    }
  }
}
