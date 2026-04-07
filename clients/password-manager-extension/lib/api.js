function isLoopbackHostname(hostname) {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]"
}

function hasProtocol(value) {
  return /^[a-z][a-z\d+.-]*:\/\//i.test(value)
}

function coerceLocalDevelopmentUrl(value) {
  if (hasProtocol(value)) {
    return value
  }

  if (/^(localhost|127\.0\.0\.1)(:\d+)?(\/.*)?$/i.test(value)) {
    return `http://${value}`
  }

  if (/^\[::1\](:\d+)?(\/.*)?$/i.test(value)) {
    return `http://${value}`
  }

  return value
}

export function normalizeServerUrl(value) {
  const trimmed = coerceLocalDevelopmentUrl((value || "").trim())

  if (!trimmed) {
    throw new Error("Server URL is required.")
  }

  let url

  try {
    url = new URL(trimmed)
  } catch (_error) {
    throw new Error("Enter a valid server URL, including https:// or http://localhost.")
  }

  const isLocalDevelopmentServer = url.protocol === "http:" && isLoopbackHostname(url.hostname)

  if (url.protocol !== "https:" && !isLocalDevelopmentServer) {
    throw new Error("Server URL must start with https://, or use http:// for localhost testing.")
  }

  url.pathname = url.pathname.replace(/\/+$/, "")
  url.hash = ""
  url.search = ""

  return url.toString().replace(/\/+$/, "")
}

async function parseJson(response) {
  try {
    return await response.json()
  } catch (_error) {
    return null
  }
}

function errorMessage(payload, response) {
  const message = payload?.error?.message || payload?.error || payload?.message

  if (typeof message === "string" && message.trim()) {
    return message
  }

  return `Request failed (${response.status}).`
}

async function request(settings, path, options = {}) {
  const serverUrl = normalizeServerUrl(settings.serverUrl)
  const token = ((options.token ?? settings.apiToken) || "").trim()

  const headers = {
    Accept: "application/json"
  }

  const fetchOptions = {
    method: options.method || "GET",
    headers
  }

  if (options.auth !== false) {
    if (!token) {
      throw new Error("An access token is required.")
    }

    headers.Authorization = `Bearer ${token}`
  }

  if (options.body !== undefined) {
    headers["Content-Type"] = "application/json"
    fetchOptions.body = JSON.stringify(options.body)
  }

  let response

  try {
    response = await fetch(`${serverUrl}${path}`, fetchOptions)
  } catch (_error) {
    throw new Error("Could not reach the Elektrine server.")
  }

  const payload = await parseJson(response)

  if (!response.ok) {
    throw new Error(errorMessage(payload, response))
  }

  return payload?.data ?? payload
}

export function listEntries(settings) {
  return request(settings, "/api/ext/v1/password-manager/entries?limit=100")
}

export function getEntry(settings, entryId) {
  return request(settings, `/api/ext/v1/password-manager/entries/${entryId}`)
}

export function setupVault(settings, encryptedVerifier) {
  return request(settings, "/api/ext/v1/password-manager/vault/setup", {
    method: "POST",
    body: {
      vault: {
        encrypted_verifier: encryptedVerifier
      }
    }
  })
}

export function deleteVault(settings) {
  return request(settings, "/api/ext/v1/password-manager/vault", {
    method: "DELETE"
  })
}

export function createEntry(settings, attrs) {
  return request(settings, "/api/ext/v1/password-manager/entries", {
    method: "POST",
    body: {
      entry: attrs
    }
  })
}

export function updateEntry(settings, entryId, attrs) {
  return request(settings, `/api/ext/v1/password-manager/entries/${entryId}`, {
    method: "PUT",
    body: {
      entry: attrs
    }
  })
}

export function loginWithAccount(serverUrl, username, password) {
  return request(
    { serverUrl, apiToken: "" },
    "/api/auth/login",
    {
      method: "POST",
      auth: false,
      body: { username, password }
    }
  )
}

export function logoutWithAccount(settings) {
  return request(settings, "/api/auth/logout", {
    method: "POST"
  })
}
