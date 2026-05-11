/**
 * Form Hooks
 * Hooks for form inputs, tag inputs, and autocomplete functionality.
 */
import { spinnerSvg } from '../utils/spinner'

const ATOMINE_MIN_DIFFICULTY = 0
const ATOMINE_MAX_DIFFICULTY = 30
const ATOMINE_PROGRESS_INTERVAL = 1000

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
 * Atomine proof-of-work Hook
 * Solves a small local browser challenge and submits an anonymous effort token.
 */
export const AtominePow = {
  mounted() {
    this.form = this.el.closest('form') || document.getElementById('register-form')
    this.statusEl = this.el.querySelector('[data-atomine-pow-status]')
    this.difficulty = normalizeDifficulty(this.el.dataset.difficulty)
    this.inFlight = null
    this.handleSubmit = (event) => this.onSubmit(event)

    if (this.form) {
      this.form.addEventListener('submit', this.handleSubmit, true)
    }
  },

  async onSubmit(event) {
    if (!this.form) return

    if (this.form?.dataset.atominePowSkip === 'true') {
      delete this.form.dataset.atominePowSkip
      return
    }

    if (this.responseToken()) return

    event.preventDefault()
    event.stopImmediatePropagation()

    try {
      await this.ensureToken()
      this.form.dataset.atominePowSkip = 'true'
      this.requestSubmit(event.submitter)
    } catch (_error) {
      this.setResponseToken('')
      this.showError('atomine proof failed; retry')
    }
  },

  updated() {
    this.statusEl = this.el.querySelector('[data-atomine-pow-status]')
  },

  ensureToken() {
    if (!this.inFlight) {
      this.inFlight = this.solveAndIssueToken().finally(() => {
        this.inFlight = null
      })
    }

    return this.inFlight
  },

  responseInput() {
    return this.form?.querySelector('input[name="atomine_pow_token"]')
  },

  responseInputs() {
    return Array.from(this.form?.querySelectorAll('input[name="atomine_pow_token"]') || [])
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
    let input = form.querySelector('input[name="atomine_pow_token"]')

    if (!input) {
      input = document.createElement('input')
      input.type = 'hidden'
      input.name = 'atomine_pow_token'
      form.appendChild(input)
    }

    input.id = 'atomine-pow-token'
    return input
  },

  async solveAndIssueToken() {
    if (!window.crypto?.subtle) {
      throw new Error('Web Crypto is unavailable')
    }

    this.ensureResponseInput(this.form)
    this.clearError()
    this.setStatus('atomine: requesting challenge')

    const challengeResponse = await postJson('/api/atomine/pow/challenge', {
      difficulty: this.difficulty
    })

    const challenge = challengeResponse.challenge
    const difficulty = normalizeDifficulty(challengeResponse.difficulty ?? this.difficulty)
    this.setStatus(`atomine: solving sha256 nonce, difficulty=${difficulty}`)

    const solution = await solvePow(challenge, difficulty, (attempts) => {
      this.setStatus(`atomine: attempts=${attempts.toLocaleString()}`)
    })

    this.setStatus('atomine: redeeming anonymous effort token')

    const tokenResponse = await postJson('/api/atomine/anonymous-tokens', {
      challenge,
      solution
    })

    if (!tokenResponse.token) {
      throw new Error('Missing Atomine token')
    }

    this.setResponseToken(tokenResponse.token)
    this.setStatus('atomine: proof accepted, submitting')
  },

  requestSubmit(submitter) {
    if (typeof this.form.requestSubmit === 'function') {
      this.form.requestSubmit(submitter || undefined)
    } else {
      this.form.submit()
    }
  },

  setStatus(message) {
    if (this.statusEl) this.statusEl.textContent = message
  },

  showError(message) {
    let error = this.el.parentElement?.querySelector('[data-atomine-pow-error="true"]')
    if (!error && this.el.parentElement) {
      error = document.createElement('div')
      error.className = 'text-warning text-xs mt-1'
      error.dataset.atominePowError = 'true'
      this.el.parentElement.appendChild(error)
    }
    if (error) error.textContent = message
  },

  clearError() {
    const error = this.el.parentElement?.querySelector('[data-atomine-pow-error="true"]')
    if (error) error.remove()
  },

  destroyed() {
    if (this.form && this.handleSubmit) {
      this.form.removeEventListener('submit', this.handleSubmit, true)
    }
  }
}

async function postJson(url, body) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  })

  const json = await response.json().catch(() => ({}))
  if (!response.ok) {
    throw new Error(json.error || 'request failed')
  }

  return json
}

async function solvePow(challenge, difficulty, onProgress) {
  const encoder = new TextEncoder()
  let nonce = 0

  while (true) {
    const solution = String(nonce)
    const digest = await crypto.subtle.digest('SHA-256', encoder.encode(`${challenge}:${solution}`))

    if (leadingZeroBits(new Uint8Array(digest)) >= difficulty) {
      return solution
    }

    nonce += 1

    if (nonce % ATOMINE_PROGRESS_INTERVAL === 0) {
      if (onProgress) onProgress(nonce)
      await new Promise((resolve) => setTimeout(resolve, 0))
    }
  }
}

function normalizeDifficulty(value) {
  const parsed = Number.parseInt(value ?? '18', 10)
  if (Number.isNaN(parsed)) return 18
  return Math.min(ATOMINE_MAX_DIFFICULTY, Math.max(ATOMINE_MIN_DIFFICULTY, parsed))
}

function leadingZeroBits(bytes) {
  let total = 0

  for (const byte of bytes) {
    if (byte === 0) {
      total += 8
      continue
    }

    for (let bit = 7; bit >= 0; bit -= 1) {
      if ((byte & (1 << bit)) === 0) {
        total += 1
      } else {
        return total
      }
    }
  }

  return total
}
