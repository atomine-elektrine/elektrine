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
    this.submitResetTimer = null
    this.onSubmit = (e) => {
      if (e.defaultPrevented) return

      const submitBtn = this.el.querySelector('button[type="submit"], button:not([type])')
      if (submitBtn) {
        // Store original content
        const originalContent = submitBtn.innerHTML

        // Get loading text from data attribute or use original
        const loadingText = submitBtn.dataset.loadingText || submitBtn.textContent.trim()

        // Replace with spinner and loading text without injecting text as HTML.
        submitBtn.innerHTML = spinnerSvg()
        const loadingTextElement = document.createElement('span')
        loadingTextElement.textContent = loadingText
        submitBtn.appendChild(loadingTextElement)
        submitBtn.disabled = true
        submitBtn.classList.add('pointer-events-none')

        // Restore after timeout (in case of network issues)
        this.submitResetTimer = setTimeout(() => {
          submitBtn.innerHTML = originalContent
          submitBtn.disabled = false
          submitBtn.classList.remove('pointer-events-none')
          this.submitResetTimer = null
        }, 30000)
      }
    }

    this.el.addEventListener('submit', this.onSubmit)
  },

  destroyed() {
    if (this.onSubmit) this.el.removeEventListener('submit', this.onSubmit)
    if (this.submitResetTimer) clearTimeout(this.submitResetTimer)
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

    this.onInput = (e) => {
      this.pushEvent("update_tag_input", {
        field: this.el.dataset.field,
        value: e.target.value
      })
    }

    this.el.addEventListener('input', this.onInput)
  },

  destroyed() {
    if (this.onInput) this.el.removeEventListener('input', this.onInput)
  }
}

/**
 * Suggestion Dropdown Hook
 * Handles mousedown events on suggestions (fires before blur)
 */
export const SuggestionDropdown = {
  mounted() {
    this.onMouseDown = (e) => {
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
    }

    this.el.addEventListener('mousedown', this.onMouseDown)
  },

  destroyed() {
    if (this.onMouseDown) this.el.removeEventListener('mousedown', this.onMouseDown)
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
 * Security check hook
 * Solves configured anti-abuse layers before submitting.
 */
const POW_STATUS_CLASSES = {
  progress: 'text-base-content/60',
  success: 'text-success',
  error: 'text-error'
}

export const AtominePow = {
  mounted() {
    this.form = this.el.closest('form') || document.getElementById('register-form')
    this.statusEl = this.el.querySelector('[data-atomine-pow-status]')
    this.difficulty = normalizeDifficulty(this.el.dataset.difficulty)
    this.inFlight = null
    this.submittingWithToken = false
    this.handleSubmit = (event) => this.onSubmit(event)

    if (this.form) {
      this.resetSubmissionState()
      this.form.addEventListener('submit', this.handleSubmit, true)
    }
  },

  async onSubmit(event) {
    if (!this.form) return

    if (this.form?.dataset.atominePowSkip === 'true') {
      delete this.form.dataset.atominePowSkip
      this.submittingWithToken = false
      return
    }

    event.preventDefault()
    event.stopImmediatePropagation()

    if (this.submittingWithToken) return

    try {
      await this.ensureToken()
      this.submittingWithToken = true
      this.form.dataset.atominePowSkip = 'true'
      this.requestSubmit(event.submitter)
    } catch (_error) {
      this.setResponseToken('')
      this.setStatus('Security check failed. Please try again.', 'error')
    }
  },

  updated() {
    this.statusEl = this.el.querySelector('[data-atomine-pow-status]')
    if (!this.inFlight) this.resetSubmissionState()
  },

  resetSubmissionState() {
    this.submittingWithToken = false
    if (this.form) delete this.form.dataset.atominePowSkip
    this.setResponseToken('')
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
    this.setStatus('Preparing the security check...')

    const challengeResponse = await postJson('/api/atomine/pow/challenge', {
      difficulty: this.difficulty
    })

    const challenge = challengeResponse.challenge
    const difficulty = normalizeDifficulty(challengeResponse.difficulty ?? this.difficulty)
    this.setStatus('Checking this browser...')
    const gateProof = await collectGateProof(challenge)

    this.setStatus('Running a short work check...')

    const solution = await solvePow(challenge, difficulty, (attempts) => {
      this.setStatus(`Still working... ${attempts.toLocaleString()} attempts tried`)
    })

    this.setStatus('Finishing the check...')

    const tokenResponse = await postJson('/api/atomine/anonymous-tokens', {
      challenge,
      solution,
      gate_proof: gateProof
    })

    if (!tokenResponse.token) {
      throw new Error('Missing Atomine token')
    }

    this.setResponseToken(tokenResponse.token)
    this.setStatus('Check complete. Submitting...', 'success')
  },

  requestSubmit(submitter) {
    if (typeof this.form.requestSubmit === 'function') {
      this.form.requestSubmit(submitter || undefined)
    } else {
      this.form.submit()
    }
  },

  setStatus(message, state = 'progress') {
    if (!this.statusEl) return
    this.statusEl.textContent = message
    this.statusEl.classList.remove(...Object.values(POW_STATUS_CLASSES))
    this.statusEl.classList.add(POW_STATUS_CLASSES[state] || POW_STATUS_CLASSES.progress)
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

async function collectGateProof(challenge) {
  const checks = []

  checks.push(measureBrowserCheck('layout.getComputedStyle', () => {
    const probe = document.createElement('div')
    probe.style.cssText = 'position:absolute;left:-9999px;width:37px;height:11px;padding:3px;display:block;'
    document.body.appendChild(probe)
    const style = window.getComputedStyle(probe)
    const ok = style.display === 'block' && style.width === '37px' && style.paddingLeft === '3px'
    probe.remove()
    return { ok }
  }))

  checks.push(measureBrowserCheck('canvas.toDataURL', () => {
    const canvas = document.createElement('canvas')
    canvas.width = 16
    canvas.height = 16
    const ctx = canvas.getContext('2d')
    if (!ctx) return { ok: false }
    ctx.fillStyle = '#1f6feb'
    ctx.fillRect(0, 0, 16, 16)
    ctx.fillStyle = '#ffffff'
    ctx.fillText('A', 3, 12)
    const data = canvas.toDataURL('image/png')
    return { ok: data.startsWith('data:image/png;base64,'), bytes: data.length }
  }))

  checks.push(measureBrowserCheck('event.isTrusted', () => {
    let syntheticTrusted = null
    const button = document.createElement('button')
    button.type = 'button'
    button.addEventListener('click', (event) => {
      syntheticTrusted = event.isTrusted
    }, { once: true })
    button.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    return { ok: syntheticTrusted === false, synthetic_trusted: syntheticTrusted }
  }))

  checks.push(measureBrowserCheck('navigator.webdriver', () => {
    const webdriver = navigator.webdriver === true
    return { ok: !webdriver, webdriver }
  }))

  checks.push(measureBrowserCheck('dom.querySelector', () => {
    const id = `atomine-gate-${Math.random().toString(36).slice(2)}`
    const probe = document.createElement('span')
    probe.id = id
    probe.dataset.atomineBrowserProof = 'true'
    document.body.appendChild(probe)
    const ok = document.querySelector(`#${id}`)?.dataset.atomineBrowserProof === 'true'
    probe.remove()
    return { ok }
  }))

  if (checks.some((check) => !check.ok)) {
    throw new Error('browser instrumentation failed')
  }

  return {
    version: 'atomine-gate-v1',
    layers: ['pow', 'browser_instrumentation'],
    browser_instrumentation: {
      challenge_hash: await sha256Base64Url(challenge),
      checks,
      signals: {
        user_agent_hash: await sha256Base64Url(navigator.userAgent || ''),
        languages: Array.isArray(navigator.languages) ? navigator.languages.slice(0, 5) : [],
        hardware_concurrency: navigator.hardwareConcurrency || null,
        device_memory: navigator.deviceMemory || null,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || null
      }
    }
  }
}

function measureBrowserCheck(name, fn) {
  const startedAt = performance.now()

  try {
    const result = fn() || {}
    return {
      name,
      ok: result.ok === true,
      duration_ms: Math.max(0, Math.round(performance.now() - startedAt)),
      ...result
    }
  } catch (error) {
    return {
      name,
      ok: false,
      duration_ms: Math.max(0, Math.round(performance.now() - startedAt)),
      error: error?.name || 'Error'
    }
  }
}

async function sha256Base64Url(value) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  const bytes = new Uint8Array(digest)
  let binary = ''

  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }

  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
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
