/**
 * Passkey Hooks
 * WebAuthn/Passkey integration for passwordless authentication.
 */

/**
 * Helper to convert ArrayBuffer to Base64URL string
 */
function bufferToBase64URL(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ''
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '')
}

/**
 * Helper to convert Base64URL string to ArrayBuffer
 */
function base64URLToBuffer(base64url) {
  // Add padding if needed
  const padding = '='.repeat((4 - (base64url.length % 4)) % 4)
  const base64 = base64url
    .replace(/-/g, '+')
    .replace(/_/g, '/')
    + padding
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes.buffer
}

/**
 * Check if WebAuthn is supported
 */
function isWebAuthnSupported() {
  return !!(window.PublicKeyCredential)
}

/**
 * Check if conditional UI (passkey autofill) is available
 */
async function isConditionalUIAvailable() {
  if (!isWebAuthnSupported()) return false
  if (typeof PublicKeyCredential.isConditionalMediationAvailable !== 'function') return false
  try {
    return await PublicKeyCredential.isConditionalMediationAvailable()
  } catch {
    return false
  }
}

/**
 * PasskeyRegister Hook
 * Handles WebAuthn registration for adding new passkeys.
 *
 * Usage: <button phx-hook="PasskeyRegister" phx-click="start_passkey_registration">
 */
export const PasskeyRegister = {
  mounted() {
    // Check WebAuthn support on mount
    if (!isWebAuthnSupported()) {
      this.el.disabled = true
      this.el.title = 'Passkeys are not supported in this browser'
    }

    // Listen for registration challenge from server
    this.handleEvent('passkey_registration_challenge', async (data) => {
      try {
        await this.handleRegistration(data)
      } catch (error) {
        console.error('Passkey registration error:', error)
        this.pushEvent('passkey_registration_error', {
          error: error.name === 'NotAllowedError'
            ? 'Registration was cancelled or timed out'
            : error.message || 'Registration failed'
        })
      }
    })
  },

  async handleRegistration(challengeData) {
    // Build the credential creation options
    const publicKey = {
      challenge: base64URLToBuffer(challengeData.challenge_b64),
      rp: {
        id: challengeData.rp_id,
        name: challengeData.rp_name
      },
      user: {
        id: base64URLToBuffer(challengeData.user_id),
        name: challengeData.user_name,
        displayName: challengeData.user_display_name
      },
      pubKeyCredParams: challengeData.pub_key_cred_params.map(p => ({
        type: p.type,
        alg: p.alg
      })),
      timeout: challengeData.timeout,
      attestation: challengeData.attestation || 'none',
      authenticatorSelection: {
        residentKey: challengeData.authenticator_selection?.resident_key || 'preferred',
        userVerification: challengeData.authenticator_selection?.user_verification || 'preferred'
      },
      excludeCredentials: (challengeData.exclude_credentials || []).map(cred => ({
        type: cred.type,
        id: base64URLToBuffer(cred.id),
        transports: cred.transports
      }))
    }

    // Request credential creation from browser/authenticator
    const credential = await navigator.credentials.create({ publicKey })

    // Extract and encode the response
    const response = credential.response
    const attestationResponse = {
      id: credential.id,
      rawId: bufferToBase64URL(credential.rawId),
      type: credential.type,
      response: {
        clientDataJSON: bufferToBase64URL(response.clientDataJSON),
        attestationObject: bufferToBase64URL(response.attestationObject)
      }
    }

    // Include transports if available (for future authentication hints)
    if (response.getTransports) {
      attestationResponse.response.transports = response.getTransports()
    }

    // Send to server for verification
    this.pushEvent('passkey_registration_response', {
      attestation: attestationResponse,
      name: challengeData.suggested_name || null
    })
  }
}

/**
 * PasskeyAuth Hook
 * Handles WebAuthn authentication for passkey login.
 *
 * Usage: <button phx-hook="PasskeyAuth" id="passkey-login">Sign in with passkey</button>
 */
export const PasskeyAuth = {
  mounted() {
    // Check WebAuthn support
    if (!isWebAuthnSupported()) {
      this.el.disabled = true
      this.el.title = 'Passkeys are not supported in this browser'
      return
    }

    // Handle click to start authentication
    this.handleClick = async () => {
      this.el.disabled = true
      try {
        // Request challenge from server
        const challengeData = await this.getChallenge()
        if (challengeData.error) {
          throw new Error(challengeData.error)
        }
        await this.handleAuthentication(challengeData)
      } catch (error) {
        console.error('Passkey authentication error:', error)
        if (window.showNotification) {
          window.showNotification(
            error.name === 'NotAllowedError'
              ? 'Authentication was cancelled or timed out'
              : error.message || 'Authentication failed',
            'error'
          )
        }
      } finally {
        this.el.disabled = false
      }
    }

    this.el.addEventListener('click', this.handleClick)
  },

  async getChallenge() {
    return new Promise((resolve) => {
      // Set up one-time event handler for challenge response
      const challengeRef = this.handleEvent('passkey_auth_challenge', (data) => {
        this.removeHandleEvent(challengeRef)
        if (this.challengeEventRef === challengeRef) {
          this.challengeEventRef = null
        }
        resolve(data)
      })

      this.challengeEventRef = challengeRef

      // Request challenge
      this.pushEvent('get_passkey_challenge', {})
    })
  },

  async handleAuthentication(challengeData) {
    // Build the credential request options
    const publicKey = {
      challenge: base64URLToBuffer(challengeData.challenge_b64),
      rpId: challengeData.rp_id,
      timeout: challengeData.timeout,
      userVerification: challengeData.user_verification || 'preferred',
      allowCredentials: (challengeData.allow_credentials || []).map(cred => ({
        type: cred.type,
        id: base64URLToBuffer(cred.id),
        transports: cred.transports
      }))
    }

    // Request authentication from browser/authenticator
    const credential = await navigator.credentials.get({ publicKey })

    // Extract and encode the response
    const response = credential.response
    const assertionResponse = {
      id: credential.id,
      rawId: bufferToBase64URL(credential.rawId),
      type: credential.type,
      response: {
        clientDataJSON: bufferToBase64URL(response.clientDataJSON),
        authenticatorData: bufferToBase64URL(response.authenticatorData),
        signature: bufferToBase64URL(response.signature)
      }
    }

    // Include userHandle if present (for discoverable credentials)
    if (response.userHandle) {
      assertionResponse.response.userHandle = bufferToBase64URL(response.userHandle)
    }

    // Submit to server via form POST for proper session handling
    this.submitAuthentication(assertionResponse, challengeData.challenge_b64)
  },

  submitAuthentication(assertion, challenge) {
    // Create a form to POST the assertion (this ensures proper cookie handling)
    const form = document.createElement('form')
    form.method = 'POST'
    form.action = '/passkey/authenticate'
    form.style.display = 'none'

    // Add CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (csrfToken) {
      const csrfInput = document.createElement('input')
      csrfInput.type = 'hidden'
      csrfInput.name = '_csrf_token'
      csrfInput.value = csrfToken
      form.appendChild(csrfInput)
    }

    // Add assertion data
    const assertionInput = document.createElement('input')
    assertionInput.type = 'hidden'
    assertionInput.name = 'assertion'
    assertionInput.value = JSON.stringify(assertion)
    form.appendChild(assertionInput)

    // Add challenge
    const challengeInput = document.createElement('input')
    challengeInput.type = 'hidden'
    challengeInput.name = 'challenge'
    challengeInput.value = challenge
    form.appendChild(challengeInput)

    document.body.appendChild(form)
    form.submit()
  },

  destroyed() {
    if (this.handleClick) {
      this.el.removeEventListener('click', this.handleClick)
    }

    if (this.challengeEventRef) {
      this.removeHandleEvent(this.challengeEventRef)
      this.challengeEventRef = null
    }
  }
}

/**
 * PasskeyConditionalUI Hook
 * Enables browser autofill integration for passkeys.
 * This allows the browser to show passkey suggestions in the username field.
 *
 * Usage: <input phx-hook="PasskeyConditionalUI" autocomplete="username webauthn">
 */
export const PasskeyConditionalUI = {
  async mounted() {
    // Check if conditional UI is available
    const available = await isConditionalUIAvailable()
    if (!available) {
      return
    }

    // Mark the input for conditional mediation
    this.el.setAttribute('autocomplete', 'username webauthn')

    // Start conditional UI authentication
    try {
      await this.startConditionalUI()
    } catch (error) {
      // Conditional UI errors are expected (user may dismiss, etc.)
      console.debug('Conditional UI not started:', error.message)
    }
  },

  async startConditionalUI() {
    // Request challenge from server for conditional UI
    const challengeData = await this.getConditionalChallenge()
    if (challengeData.error) {
      return
    }

    const publicKey = {
      challenge: base64URLToBuffer(challengeData.challenge_b64),
      rpId: challengeData.rp_id,
      timeout: challengeData.timeout,
      userVerification: challengeData.user_verification || 'preferred',
      allowCredentials: [] // Empty for discoverable credentials
    }

    try {
      this.abortController = new AbortController()

      // Use conditional mediation
      const credential = await navigator.credentials.get({
        publicKey,
        mediation: 'conditional',
        signal: this.abortController.signal
      })

      if (credential) {
        // User selected a passkey from autofill
        const response = credential.response
        const assertionResponse = {
          id: credential.id,
          rawId: bufferToBase64URL(credential.rawId),
          type: credential.type,
          response: {
            clientDataJSON: bufferToBase64URL(response.clientDataJSON),
            authenticatorData: bufferToBase64URL(response.authenticatorData),
            signature: bufferToBase64URL(response.signature)
          }
        }

        if (response.userHandle) {
          assertionResponse.response.userHandle = bufferToBase64URL(response.userHandle)
        }

        // Submit authentication
        this.submitConditionalAuth(assertionResponse, challengeData.challenge_b64)
      }
    } catch (error) {
      // AbortError is expected when user navigates away or cancels
      if (error.name !== 'AbortError') {
        console.error('Conditional UI error:', error)
      }
    }
  },

  async getConditionalChallenge() {
    return new Promise((resolve) => {
      const challengeRef = this.handleEvent('passkey_conditional_challenge', (data) => {
        this.removeHandleEvent(challengeRef)
        if (this.conditionalChallengeRef === challengeRef) {
          this.conditionalChallengeRef = null
        }
        resolve(data)
      })

      this.conditionalChallengeRef = challengeRef
      this.pushEvent('get_passkey_conditional_challenge', {})
    })
  },

  submitConditionalAuth(assertion, challenge) {
    const form = document.createElement('form')
    form.method = 'POST'
    form.action = '/passkey/authenticate'
    form.style.display = 'none'

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (csrfToken) {
      const csrfInput = document.createElement('input')
      csrfInput.type = 'hidden'
      csrfInput.name = '_csrf_token'
      csrfInput.value = csrfToken
      form.appendChild(csrfInput)
    }

    const assertionInput = document.createElement('input')
    assertionInput.type = 'hidden'
    assertionInput.name = 'assertion'
    assertionInput.value = JSON.stringify(assertion)
    form.appendChild(assertionInput)

    const challengeInput = document.createElement('input')
    challengeInput.type = 'hidden'
    challengeInput.name = 'challenge'
    challengeInput.value = challenge
    form.appendChild(challengeInput)

    document.body.appendChild(form)
    form.submit()
  },

  destroyed() {
    if (this.conditionalChallengeRef) {
      this.removeHandleEvent(this.conditionalChallengeRef)
      this.conditionalChallengeRef = null
    }

    // Abort any pending conditional UI request
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }
}
