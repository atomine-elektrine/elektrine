const ADMIN_PREFIX = '/pripyat'
const ADMIN_SECURITY_PREFIX = '/pripyat/security'
const ADMIN_SECURITY_EXEMPT_PATHS = new Set(['/pripyat/stop-impersonation'])
const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

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

function base64URLToBuffer(base64url) {
  const padding = '='.repeat((4 - (base64url.length % 4)) % 4)
  const base64 = base64url.replace(/-/g, '+').replace(/_/g, '/') + padding
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)

  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }

  return bytes.buffer
}

function getCsrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute('content') || ''
}

function parseActionPath(action) {
  try {
    const url = new URL(action || window.location.pathname, window.location.origin)
    return url.pathname
  } catch (_error) {
    return null
  }
}

function resolveFormMethod(form) {
  const override = form.querySelector("input[name='_method']")
  const method = override?.value || form.getAttribute('method') || form.method || 'GET'
  return method.toUpperCase()
}

function isSensitiveAdminPath(path) {
  return Boolean(path) &&
    path.startsWith(ADMIN_PREFIX) &&
    !path.startsWith(ADMIN_SECURITY_PREFIX) &&
    !ADMIN_SECURITY_EXEMPT_PATHS.has(path)
}

function shouldInterceptForm(form) {
  if (!form || form.dataset.adminResignSkip === 'true') return false
  if (form.hasAttribute('phx-submit') || form.hasAttribute('data-phx-submit')) return false

  const method = resolveFormMethod(form)
  if (!MUTATING_METHODS.has(method)) return false

  const path = parseActionPath(form.getAttribute('action') || window.location.pathname)
  return isSensitiveAdminPath(path)
}

async function parseJsonResponse(response) {
  let body = {}
  try {
    body = await response.json()
  } catch (_error) {
    body = {}
  }

  if (!response.ok) {
    throw new Error(body.error || 'Admin security request failed.')
  }

  return body
}

async function postJson(path, payload) {
  const response = await fetch(path, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-csrf-token': getCsrfToken()
    },
    credentials: 'same-origin',
    body: JSON.stringify(payload)
  })

  return parseJsonResponse(response)
}

async function createPasskeyAssertion(challengeData) {
  if (!window.PublicKeyCredential) {
    throw new Error('Passkeys are not supported by this browser.')
  }

  const publicKey = {
    challenge: base64URLToBuffer(challengeData.challenge_b64),
    rpId: challengeData.rp_id,
    timeout: challengeData.timeout,
    userVerification: challengeData.user_verification || 'preferred',
    allowCredentials: (challengeData.allow_credentials || []).map((credential) => ({
      type: credential.type,
      id: base64URLToBuffer(credential.id),
      transports: credential.transports
    }))
  }

  const credential = await navigator.credentials.get({ publicKey })
  const response = credential.response

  const assertion = {
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
    assertion.response.userHandle = bufferToBase64URL(response.userHandle)
  }

  return assertion
}

function upsertGrantInput(form, grantToken) {
  let input = form.querySelector("input[name='_admin_action_grant']")
  if (!input) {
    input = document.createElement('input')
    input.type = 'hidden'
    input.name = '_admin_action_grant'
    form.appendChild(input)
  }

  input.value = grantToken
}

function notifyAdminSecurityError(message) {
  if (window.showNotification) {
    window.showNotification(message, 'error')
  } else {
    window.alert(message)
  }
}

function requestFormSubmit(form, submitter) {
  if (typeof form.requestSubmit === 'function') {
    if (submitter) {
      form.requestSubmit(submitter)
    } else {
      form.requestSubmit()
    }

    return
  }

  const submitEvent = new Event('submit', { bubbles: true, cancelable: true })

  if (form.dispatchEvent(submitEvent)) {
    HTMLFormElement.prototype.submit.call(form)
  }
}

function bindSensitiveConfirm(submitter, form) {
  if (!submitter) return
  if (submitter.dataset.adminResignConfirmBound === 'true') return
  if (!submitter.hasAttribute('data-confirm')) return

  submitter.dataset.adminResignConfirmBound = 'true'

  submitter.addEventListener(
    'click',
    (event) => {
      if (submitter.form !== form) return
      if (!window.confirm(submitter.getAttribute('data-confirm') || 'Are you sure?')) {
        event.preventDefault()
        event.stopImmediatePropagation()
        return
      }

      event.preventDefault()
      event.stopImmediatePropagation()
      requestFormSubmit(form, submitter)
    },
    true
  )
}

async function signFormAction(form) {
  const method = resolveFormMethod(form)
  const path = parseActionPath(form.getAttribute('action') || window.location.pathname)

  if (!path) {
    throw new Error('Unable to resolve admin action path.')
  }

  const startData = await postJson('/pripyat/security/action/start', { method, path })
  const assertion = await createPasskeyAssertion(startData)

  const finishData = await postJson('/pripyat/security/action/finish', {
    intent_token: startData.intent_token,
    challenge: startData.challenge_b64,
    assertion
  })

  if (!finishData.grant_token) {
    throw new Error('Missing action grant token.')
  }

  return finishData.grant_token
}

function bindSensitiveForm(form) {
  if (!shouldInterceptForm(form) || form.dataset.adminResignBound === 'true') return

  form.dataset.adminResignBound = 'true'

  form
    .querySelectorAll("button[type='submit'][data-confirm], input[type='submit'][data-confirm]")
    .forEach((submitter) => bindSensitiveConfirm(submitter, form))

  form.addEventListener('submit', async (event) => {
    if (form.dataset.adminResignSkip === 'true') {
      delete form.dataset.adminResignSkip
      return
    }

    if (form.dataset.adminResignInFlight === 'true') return

    event.preventDefault()
    form.dataset.adminResignInFlight = 'true'

    try {
      const grantToken = await signFormAction(form)
      upsertGrantInput(form, grantToken)
      form.dataset.adminResignSkip = 'true'
      delete form.dataset.adminResignInFlight
      requestFormSubmit(form)
    } catch (error) {
      delete form.dataset.adminResignInFlight
      notifyAdminSecurityError(error.message || 'Passkey confirmation failed.')
    }
  })
}

function bindAdminElevation(root = document) {
  const container = root.querySelector('[data-admin-elevation="true"]')
  const button = root.querySelector('#admin-elevate-passkey')
  if (!container || !button || button.dataset.adminElevationBound === 'true') return

  button.dataset.adminElevationBound = 'true'

  button.addEventListener('click', async () => {
    button.disabled = true

    try {
      const returnTo = container.dataset.returnTo || '/pripyat'
      const startData = await postJson('/pripyat/security/elevate/start', { return_to: returnTo })
      const assertion = await createPasskeyAssertion(startData)

      const finishData = await postJson('/pripyat/security/elevate/finish', {
        intent_token: startData.intent_token,
        challenge: startData.challenge_b64,
        assertion
      })

      window.location.href = finishData.redirect_to || returnTo
    } catch (error) {
      button.disabled = false
      notifyAdminSecurityError(error.message || 'Admin elevation failed.')
    }
  })
}

export function initAdminSecurity(root = document) {
  const forms = root.querySelectorAll ? root.querySelectorAll('form') : []
  forms.forEach(bindSensitiveForm)
  bindAdminElevation(root)
}
