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

  if (options.formData !== undefined) {
    fetchOptions.body = options.formData
  } else if (options.body !== undefined) {
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
  return request(settings, "/api/ext/v1/nerve/entries?limit=100")
}

export function getEntry(settings, entryId) {
  return request(settings, `/api/ext/v1/nerve/entries/${entryId}`)
}

export function createEntry(settings, attrs) {
  return request(settings, "/api/ext/v1/nerve/entries", {
    method: "POST",
    body: {
      entry: attrs
    }
  })
}

export function updateEntry(settings, entryId, attrs) {
  return request(settings, `/api/ext/v1/nerve/entries/${entryId}`, {
    method: "PUT",
    body: {
      entry: attrs
    }
  })
}

export function createKairoSource(settings, attrs) {
  return request(settings, "/api/ext/v1/kairo/sources", {
    method: "POST",
    body: {
      source: attrs
    }
  })
}

export function createKairoFileSource(settings, file, attrs = {}) {
  const formData = new FormData()
  const filename = file?.name || attrs.title || "kairo-file"

  formData.append("source[file]", file, filename)

  for (const [key, value] of Object.entries(attrs)) {
    appendFormValue(formData, `source[${key}]`, value)
  }

  return request(settings, "/api/ext/v1/kairo/sources", {
    method: "POST",
    formData
  })
}

function appendFormValue(formData, field, value) {
  if (value === undefined || value === null || value === "") {
    return
  }

  if (Array.isArray(value)) {
    value.forEach((item) => appendFormValue(formData, `${field}[]`, item))
    return
  }

  if (typeof value === "object") {
    for (const [nestedKey, nestedValue] of Object.entries(value)) {
      appendFormValue(formData, `${field}[${nestedKey}]`, nestedValue)
    }
    return
  }

  formData.append(field, value)
}

export function isPersonalAccessToken(token) {
  return ((token || "").trim()).startsWith("ekt_")
}

export function loginWithAccount(serverUrl, username, password, options = {}) {
  return request(
    { serverUrl, apiToken: "" },
    "/api/auth/login",
    {
      method: "POST",
      auth: false,
      body: {
        username,
        password,
        ...options
      }
    }
  )
}

export function logoutWithAccount(settings) {
  if (isPersonalAccessToken(settings.apiToken)) {
    return Promise.resolve({ message: "Signed out locally." })
  }

  return request(settings, "/api/auth/logout", {
    method: "POST"
  })
}
