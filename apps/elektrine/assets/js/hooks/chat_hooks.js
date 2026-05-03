// Chat-specific LiveView hooks
import { copyToClipboard } from '../utils/clipboard'

function selectedTextWithin(element) {
  const selection = window.getSelection()

  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return ''

  const text = selection.toString().trim()
  if (!text) return ''

  for (let index = 0; index < selection.rangeCount; index++) {
    const range = selection.getRangeAt(index)
    const container = range.commonAncestorContainer
    const node = container.nodeType === Node.TEXT_NODE ? container.parentElement : container

    if (node && element.contains(node)) {
      return text
    }
  }

  return ''
}

const CHAT_E2EE_STORAGE_PREFIX = 'elektrine:chat-e2ee:v1'
const CHAT_E2EE_MAX_DEVICES = 64
const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder()

function cryptoAvailable() {
  return Boolean(window.crypto?.subtle && window.crypto?.getRandomValues)
}

function parseJson(value, fallback) {
  if (!value) return fallback

  try {
    return JSON.parse(value)
  } catch (_err) {
    return fallback
  }
}

function bytesToBase64(bytes) {
  const array = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let binary = ''

  for (let offset = 0; offset < array.length; offset += 0x8000) {
    binary += String.fromCharCode(...array.subarray(offset, offset + 0x8000))
  }

  return btoa(binary)
}

function base64ToBytes(value) {
  const binary = atob(value)
  const bytes = new Uint8Array(binary.length)

  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index)
  }

  return bytes
}

function bytesToBase64Url(bytes) {
  return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

function randomBytes(length) {
  const bytes = new Uint8Array(length)
  window.crypto.getRandomValues(bytes)
  return bytes
}

function randomId(prefix) {
  if (window.crypto?.randomUUID) {
    return `${prefix}${window.crypto.randomUUID()}`
  }

  return `${prefix}${bytesToBase64Url(randomBytes(18))}`
}

function arrayBufferFromBytes(bytes) {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

async function sha256Base64Url(value) {
  const digest = await window.crypto.subtle.digest('SHA-256', textEncoder.encode(value))
  return bytesToBase64Url(digest)
}

function extractSearchKeywords(text) {
  const stopWords = new Set([
    'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'can', 'had', 'her', 'was',
    'one', 'our', 'out', 'day', 'get', 'has', 'him', 'his', 'how', 'man', 'new', 'now',
    'old', 'see', 'two', 'way', 'who', 'boy', 'did', 'its', 'let', 'put', 'say', 'she',
    'too', 'use'
  ])

  const lower = text.toLowerCase()
  const hashtags = lower.match(/#[a-z0-9_]+/g) || []
  const words = lower
    .replace(/[^a-z0-9_\s#]/g, ' ')
    .split(/\s+/)
    .filter(word => word.length >= 3 && !stopWords.has(word))

  return Array.from(new Set([...hashtags, ...words]))
}

function stableDevices(devices) {
  return [...devices]
    .map(device => ({
      user_id: Number.isInteger(Number(device.user_id)) ? Number(device.user_id) : null,
      recipient_handle: device.recipient_handle || null,
      origin_domain: device.origin_domain || null,
      device_id: String(device.device_id || ''),
      public_key: device.public_key || {}
    }))
    .sort((left, right) => {
      const leftOwner = left.recipient_handle || String(left.user_id)
      const rightOwner = right.recipient_handle || String(right.user_id)
      if (leftOwner !== rightOwner) return leftOwner.localeCompare(rightOwner)
      return left.device_id.localeCompare(right.device_id)
    })
}

async function devicesHash(devices) {
  return sha256Base64Url(JSON.stringify(stableDevices(devices)))
}

async function importRsaPublicKey(publicKeyPayload) {
  const key = publicKeyPayload?.key

  if (!key || publicKeyPayload.algorithm !== 'RSA-OAEP-SHA256') {
    throw new Error('Invalid chat public key')
  }

  return window.crypto.subtle.importKey(
    'spki',
    arrayBufferFromBytes(base64ToBytes(key)),
    { name: 'RSA-OAEP', hash: 'SHA-256' },
    false,
    ['encrypt']
  )
}

async function importRsaPrivateKey(privateKeyBase64) {
  return window.crypto.subtle.importKey(
    'pkcs8',
    arrayBufferFromBytes(base64ToBytes(privateKeyBase64)),
    { name: 'RSA-OAEP', hash: 'SHA-256' },
    false,
    ['decrypt']
  )
}

async function importAesKey(rawKeyBytes, usages) {
  return window.crypto.subtle.importKey(
    'raw',
    arrayBufferFromBytes(rawKeyBytes),
    { name: 'AES-GCM' },
    false,
    usages
  )
}

async function importHmacKey(rawKeyBytes) {
  return window.crypto.subtle.importKey(
    'raw',
    arrayBufferFromBytes(rawKeyBytes),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  )
}

export const ChatE2EE = {
  mounted() {
    this.devicePromise = null
    this.lastTypingAt = 0
    this.lastDeviceRegistrationAt = 0
    this.searchTimer = null

    this.submitHandler = event => this.handleSubmit(event)
    this.inputHandler = event => this.handleInput(event)
    this.toggleHandler = event => this.handleToggle(event)

    this.el.addEventListener('submit', this.submitHandler, true)
    this.el.addEventListener('input', this.inputHandler, true)
    this.el.addEventListener('click', this.toggleHandler, true)

    this.observer = new MutationObserver(() => this.decryptVisibleMessages())
    this.observer.observe(this.el, { childList: true, subtree: true })

    this.ensureDeviceRegistered()
    this.updateInputMode()
    this.updateToggleState()
    this.decryptVisibleMessages()
  },

  updated() {
    this.ensureDeviceRegistered()
    this.updateInputMode()
    this.updateToggleState()
    this.decryptVisibleMessages()
  },

  destroyed() {
    this.el.removeEventListener('submit', this.submitHandler, true)
    this.el.removeEventListener('input', this.inputHandler, true)
    this.el.removeEventListener('click', this.toggleHandler, true)

    if (this.observer) {
      this.observer.disconnect()
    }

    if (this.searchTimer) {
      clearTimeout(this.searchTimer)
    }
  },

  userId() {
    const userId = Number(this.el.dataset.userId)
    return Number.isInteger(userId) && userId > 0 ? userId : null
  },

  conversationId() {
    const conversationId = Number(this.el.dataset.conversationId)
    return Number.isInteger(conversationId) && conversationId > 0 ? conversationId : null
  },

  devices() {
    return parseJson(this.el.dataset.chatE2eeDevices, [])
  },

  memberIds() {
    return parseJson(this.el.dataset.chatE2eeMemberIds, [])
      .map(id => Number(id))
      .filter(id => Number.isInteger(id) && id > 0)
  },

  e2eeReady() {
    return this.e2eeCapable() && this.e2eeEnabled()
  },

  e2eeCapable() {
    if (!cryptoAvailable() || this.el.dataset.chatE2eeReady !== 'true' || !this.conversationId()) {
      return false
    }

    const devices = this.devices()
    return devices.length > 0 && devices.length <= CHAT_E2EE_MAX_DEVICES
  },

  e2eeEnabled() {
    const conversationId = this.conversationId()
    if (!conversationId || !this.userId()) return false

    return localStorage.getItem(this.enabledStorageKey(conversationId)) === 'true'
  },

  setE2EEEnabled(enabled) {
    const conversationId = this.conversationId()
    if (!conversationId || !this.userId()) return

    localStorage.setItem(this.enabledStorageKey(conversationId), enabled ? 'true' : 'false')
  },

  updateInputMode() {
    const form = this.messageForm()
    const textarea = this.messageInput()
    const enabled = this.e2eeReady()

    if (!form || !textarea) return

    if (enabled) {
      form.removeAttribute('phx-change')
      textarea.removeAttribute('phx-change')
    } else {
      form.setAttribute('phx-change', 'validate_upload')
      textarea.setAttribute('phx-change', 'update_message')
    }

    this.el.querySelectorAll('input[type="file"]').forEach(input => {
      input.disabled = enabled
    })

    const submitButton = form.querySelector('button[type="submit"]')
    if (enabled && submitButton) {
      submitButton.disabled = false
    }
  },

  updateToggleState() {
    const toggle = this.el.querySelector('[data-chat-e2ee-toggle="true"]')
    if (!toggle) return

    const capable = this.e2eeCapable()
    const enabled = capable && this.e2eeEnabled()
    const label = toggle.querySelector('[data-chat-e2ee-toggle-label]')

    toggle.disabled = !capable
    toggle.classList.toggle('btn-secondary', enabled)
    toggle.classList.toggle('btn-ghost', !enabled)
    toggle.title = capable
      ? 'Toggle optional client-side encrypted chat for this browser'
      : this.e2eeUnavailableTitle()

    if (label) {
      label.textContent = capable
        ? (enabled ? 'Encrypted chat on' : 'Encrypted chat off')
        : this.e2eeUnavailableLabel()
    }
  },

  e2eeUnavailableLabel() {
    switch (this.el.dataset.chatE2eeStatus) {
      case 'registering_device':
        return 'Registering this browser'
      case 'waiting_for_remote_keys':
        return 'Waiting for remote keys'
      case 'waiting_for_member_keys':
        return 'Waiting for member keys'
      case 'too_many_devices':
        return 'Too many devices'
      case 'not_applicable':
        return 'Encrypted chat not supported here'
      default:
        return 'Encrypted chat not ready'
    }
  },

  e2eeUnavailableTitle() {
    switch (this.el.dataset.chatE2eeStatus) {
      case 'registering_device':
        return 'This browser is registering an encryption device. Try again in a moment.'
      case 'waiting_for_remote_keys':
        return 'The remote participant has not advertised compatible chat encryption keys yet.'
      case 'waiting_for_member_keys':
        return 'Every active member needs at least one registered chat encryption device.'
      case 'too_many_devices':
        return 'This conversation has too many devices for the simple E2EE mode.'
      case 'not_applicable':
        return 'Optional client-side E2EE is currently supported for DMs and groups.'
      default:
        return 'Encrypted chat is not ready for this conversation yet.'
    }
  },

  handleToggle(event) {
    const toggle = event.target.closest('[data-chat-e2ee-toggle="true"]')
    if (!toggle || !this.el.contains(toggle)) return

    event.preventDefault()
    event.stopPropagation()

    if (!this.e2eeCapable()) return

    this.setE2EEEnabled(!this.e2eeEnabled())
    this.updateInputMode()
    this.updateToggleState()
  },

  messageForm() {
    const input = this.messageInput()
    return input?.closest('form') || null
  },

  messageInput() {
    return this.el.querySelector('#message-input')
  },

  async ensureDeviceRegistered() {
    if (!cryptoAvailable() || !this.userId() || this.devicePromise) return this.devicePromise
    if (Date.now() - this.lastDeviceRegistrationAt < 300000) return null

    this.devicePromise = this.loadOrCreateDevice()
      .then(device => new Promise(resolve => {
        this.pushEvent('register_chat_encryption_device', {
          device_id: device.device_id,
          public_key: {
            version: 1,
            algorithm: 'RSA-OAEP-SHA256',
            key: device.public_key
          },
          key_algorithm: 'RSA-OAEP-SHA256',
          label: device.label
        }, reply => {
          if (reply?.ok) {
            this.lastDeviceRegistrationAt = Date.now()
          }

          resolve({ device, reply })
        })
      }))
      .catch(error => {
        console.warn('Chat E2EE device registration failed', error)
        return null
      })
      .finally(() => {
        this.devicePromise = null
      })

    return this.devicePromise
  },

  async loadOrCreateDevice() {
    const key = this.deviceStorageKey()
    const stored = parseJson(localStorage.getItem(key), null)

    if (stored?.device_id && stored?.private_key && stored?.public_key) {
      return stored
    }

    const keyPair = await window.crypto.subtle.generateKey(
      {
        name: 'RSA-OAEP',
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: 'SHA-256'
      },
      true,
      ['encrypt', 'decrypt']
    )

    const [publicKey, privateKey] = await Promise.all([
      window.crypto.subtle.exportKey('spki', keyPair.publicKey),
      window.crypto.subtle.exportKey('pkcs8', keyPair.privateKey)
    ])

    const device = {
      device_id: randomId('web-'),
      public_key: bytesToBase64(publicKey),
      private_key: bytesToBase64(privateKey),
      key_algorithm: 'RSA-OAEP-SHA256',
      label: this.deviceLabel()
    }

    localStorage.setItem(key, JSON.stringify(device))
    return device
  },

  deviceStorageKey() {
    return `${CHAT_E2EE_STORAGE_PREFIX}:user:${this.userId()}:device`
  },

  deviceLabel() {
    const userAgent = navigator.userAgent || 'browser'
    return userAgent.length > 80 ? userAgent.slice(0, 80) : userAgent
  },

  handleInput(event) {
    if (event.target === this.messageInput() && this.e2eeReady()) {
      this.pushTypingEvent(event.target.value)
    }

    if (event.target?.name === 'query' && event.target.closest('#message-search-form')) {
      this.scheduleEncryptedSearch(event.target.value)
    }
  },

  pushTypingEvent(value) {
    if (!value.trim()) return

    const now = Date.now()
    if (now - this.lastTypingAt < 2000) return

    this.lastTypingAt = now
    this.pushEvent('chat_typing', {})
  },

  scheduleEncryptedSearch(query) {
    if (this.searchTimer) {
      clearTimeout(this.searchTimer)
    }

    this.searchTimer = setTimeout(async () => {
      if (!this.conversationId() || query.trim().length < 2) return

      const tokens = await this.searchTokensForKnownKeys(query)
      if (tokens.length === 0) return

      this.pushEvent('search_messages', { query, search_tokens: tokens })
    }, 150)
  },

  async handleSubmit(event) {
    const form = event.target
    const textarea = this.messageInput()

    if (!form || textarea?.closest('form') !== form || !this.e2eeReady()) {
      return
    }

    event.preventDefault()
    event.stopImmediatePropagation()

    const content = textarea.value.trim()
    const submitButton = form.querySelector('button[type="submit"]')
    const fileInput = form.querySelector('input[type="file"]')
    const hasUploads = form.dataset.hasUploads === 'true' || (fileInput && fileInput.files.length > 0)

    if (submitButton) {
      submitButton.disabled = true
    }

    if (!content || content.startsWith('/') || hasUploads) {
      console.warn('Encrypted chat mode only supports plain text messages. Toggle it off to use commands or attachments.')

      if (submitButton) {
        submitButton.disabled = false
      }

      return
    }

    try {
      await this.ensureDeviceRegistered()
      const encryptedMessage = await this.encryptMessage(content)

      this.pushEvent('send_client_encrypted_message', encryptedMessage.payload, reply => {
        if (reply?.ok) {
          if (encryptedMessage.devicesHash) {
            this.markPackagesSent(encryptedMessage.keyUid, encryptedMessage.devicesHash)
          }

          textarea.value = ''
          textarea.dispatchEvent(new Event('input', { bubbles: true }))
        } else {
          console.warn('Encrypted chat send failed', reply)
        }

        if (submitButton) {
          submitButton.disabled = false
        }
      })
    } catch (error) {
      console.warn('Could not encrypt chat message', error)
      if (submitButton) {
        submitButton.disabled = false
      }
    }
  },

  async encryptMessage(content) {
    const devices = this.devices()
    const { keyUid, rawKeyBytes, packagesNeeded, hash } = await this.conversationKeyForDevices(devices)
    const aesKey = await importAesKey(rawKeyBytes, ['encrypt'])
    const iv = randomBytes(12)
    const ciphertext = await window.crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      aesKey,
      textEncoder.encode(content)
    )

    const keyPackages = packagesNeeded ? await this.wrapConversationKey(rawKeyBytes, devices) : []
    const localKeyPackages = keyPackages.filter(keyPackage => Number.isInteger(keyPackage.user_id))
    const federatedKeyPackages = keyPackages.filter(keyPackage => keyPackage.recipient_handle)

    const payload = {
      version: 1,
      content_algorithm: 'AES-256-GCM',
      key_uid: keyUid,
      iv: bytesToBase64(iv),
      ciphertext: bytesToBase64(ciphertext)
    }

    if (federatedKeyPackages.length > 0) {
      payload.federated_key_packages = federatedKeyPackages
    }

    return {
      keyUid,
      devicesHash: packagesNeeded ? hash : null,
      payload: {
        encrypted_payload: payload,
        key_packages: localKeyPackages,
        search_index: await this.searchTokensForKey(rawKeyBytes, content)
      }
    }
  },

  async conversationKeyForDevices(devices) {
    const conversationId = this.conversationId()
    const hash = await devicesHash(devices)
    const activeKey = parseJson(localStorage.getItem(this.activeKeyStorageKey(conversationId)), null)

    if (activeKey?.key_uid && activeKey.devices_hash === hash) {
      const rawKeyBytes = this.loadRawConversationKey(conversationId, activeKey.key_uid)

      if (rawKeyBytes) {
        return {
          keyUid: activeKey.key_uid,
          rawKeyBytes,
          packagesNeeded: activeKey.packages_sent_hash !== hash,
          hash
        }
      }
    }

    const keyUid = randomId('key-')
    const rawKeyBytes = randomBytes(32)
    this.storeRawConversationKey(conversationId, keyUid, rawKeyBytes)
    this.storeActiveConversationKey(conversationId, keyUid, hash, null)

    return { keyUid, rawKeyBytes, packagesNeeded: true, hash }
  },

  async wrapConversationKey(rawKeyBytes, devices) {
    const packages = []

    for (const device of stableDevices(devices)) {
      const publicKey = await importRsaPublicKey(device.public_key)
      const encryptedKey = await window.crypto.subtle.encrypt(
        { name: 'RSA-OAEP' },
        publicKey,
        arrayBufferFromBytes(rawKeyBytes)
      )

      packages.push({
        ...(Number.isInteger(device.user_id) ? { user_id: device.user_id } : {}),
        ...(device.recipient_handle ? { recipient_handle: device.recipient_handle } : {}),
        ...(device.origin_domain ? { origin_domain: device.origin_domain } : {}),
        device_id: device.device_id,
        wrapped_key: {
          version: 1,
          key_algorithm: 'RSA-OAEP-SHA256',
          encrypted_key: bytesToBase64(encryptedKey)
        }
      })
    }

    return packages
  },

  async searchTokensForKnownKeys(query) {
    const conversationId = this.conversationId()
    if (!conversationId) return []

    const keyUids = parseJson(localStorage.getItem(this.keyListStorageKey(conversationId)), [])
    const tokenSets = await Promise.all(keyUids.map(keyUid => {
      const rawKeyBytes = this.loadRawConversationKey(conversationId, keyUid)
      return rawKeyBytes ? this.searchTokensForKey(rawKeyBytes, query) : []
    }))

    return Array.from(new Set(tokenSets.flat()))
  },

  async searchTokensForKey(rawKeyBytes, text) {
    const keywords = extractSearchKeywords(text)
    if (keywords.length === 0) return []

    const hmacKey = await importHmacKey(rawKeyBytes)
    const tokens = await Promise.all(keywords.map(async keyword => {
      const digest = await window.crypto.subtle.sign(
        'HMAC',
        hmacKey,
        textEncoder.encode(`chat-search:v1:${keyword}`)
      )

      return bytesToBase64(digest)
    }))

    return Array.from(new Set(tokens))
  },

  decryptVisibleMessages() {
    if (!cryptoAvailable() || !this.conversationId()) return

    this.el.querySelectorAll('[data-chat-encrypted-message="true"]').forEach(element => {
      if (element.dataset.decrypted === 'true') return
      if (element.dataset.decrypting === 'true') return

      element.dataset.decrypting = 'true'
      this.decryptMessageElement(element).finally(() => {
        delete element.dataset.decrypting
      })
    })
  },

  async decryptMessageElement(element) {
    const payload = parseJson(element.dataset.payload, null)
    const conversationId = Number(element.dataset.conversationId || this.conversationId())
    const keyUid = payload?.key_uid || element.dataset.keyUid

    if (!payload || !conversationId || !keyUid) return

    try {
      const rawKeyBytes = await this.rawConversationKey(conversationId, keyUid, payload)
      const aesKey = await importAesKey(rawKeyBytes, ['decrypt'])
      const plaintext = await window.crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: base64ToBytes(payload.iv) },
        aesKey,
        arrayBufferFromBytes(base64ToBytes(payload.ciphertext))
      )

      element.textContent = textDecoder.decode(plaintext)
      element.classList.remove('opacity-80')
      element.dataset.decrypted = 'true'
    } catch (error) {
      console.warn('Could not decrypt chat message', error)
      element.textContent = 'Encrypted message'
      element.dataset.decrypted = 'failed'
    }
  },

  async rawConversationKey(conversationId, keyUid, payload = null) {
    const stored = this.loadRawConversationKey(conversationId, keyUid)
    if (stored) return stored

    const device = await this.loadOrCreateDevice()
    const inlinePackage = this.inlineKeyPackageForDevice(payload, device.device_id)

    if (inlinePackage?.wrapped_key?.encrypted_key) {
      const rawKeyBytes = await this.decryptWrappedConversationKey(device, inlinePackage.wrapped_key)
      this.storeRawConversationKey(conversationId, keyUid, rawKeyBytes)
      return rawKeyBytes
    }

    const wrappedKey = await new Promise((resolve, reject) => {
      this.pushEvent('chat_e2ee_key', {
        conversation_id: conversationId,
        device_id: device.device_id,
        key_uid: keyUid
      }, reply => {
        if (reply?.ok && reply.wrapped_key) {
          resolve(reply.wrapped_key)
        } else {
          reject(new Error(reply?.error || 'Wrapped key not found'))
        }
      })
    })

    const rawKeyBytes = await this.decryptWrappedConversationKey(device, wrappedKey)

    this.storeRawConversationKey(conversationId, keyUid, rawKeyBytes)

    const hash = await devicesHash(this.devices())
    this.storeActiveConversationKey(conversationId, keyUid, hash, hash)

    return rawKeyBytes
  },

  inlineKeyPackageForDevice(payload, deviceId) {
    const packages = payload?.federated_key_packages || payload?.federatedKeyPackages || []
    return packages.find(keyPackage => keyPackage?.device_id === deviceId)
  },

  async decryptWrappedConversationKey(device, wrappedKey) {
    const privateKey = await importRsaPrivateKey(device.private_key)
    const rawKey = await window.crypto.subtle.decrypt(
      { name: 'RSA-OAEP' },
      privateKey,
      arrayBufferFromBytes(base64ToBytes(wrappedKey.encrypted_key))
    )

    return new Uint8Array(rawKey)
  },

  loadRawConversationKey(conversationId, keyUid) {
    const key = localStorage.getItem(this.rawKeyStorageKey(conversationId, keyUid))
    return key ? base64ToBytes(key) : null
  },

  storeRawConversationKey(conversationId, keyUid, rawKeyBytes) {
    localStorage.setItem(this.rawKeyStorageKey(conversationId, keyUid), bytesToBase64(rawKeyBytes))

    const listKey = this.keyListStorageKey(conversationId)
    const keyUids = parseJson(localStorage.getItem(listKey), [])
    if (!keyUids.includes(keyUid)) {
      localStorage.setItem(listKey, JSON.stringify([...keyUids, keyUid]))
    }
  },

  storeActiveConversationKey(conversationId, keyUid, devicesHashValue, packagesSentHash) {
    localStorage.setItem(this.activeKeyStorageKey(conversationId), JSON.stringify({
      key_uid: keyUid,
      devices_hash: devicesHashValue,
      packages_sent_hash: packagesSentHash
    }))
  },

  markPackagesSent(keyUid, devicesHashValue) {
    const conversationId = this.conversationId()
    if (!conversationId) return

    this.storeActiveConversationKey(conversationId, keyUid, devicesHashValue, devicesHashValue)
  },

  rawKeyStorageKey(conversationId, keyUid) {
    return `${CHAT_E2EE_STORAGE_PREFIX}:user:${this.userId()}:conversation:${conversationId}:key:${keyUid}`
  },

  activeKeyStorageKey(conversationId) {
    return `${CHAT_E2EE_STORAGE_PREFIX}:user:${this.userId()}:conversation:${conversationId}:active-key`
  },

  keyListStorageKey(conversationId) {
    return `${CHAT_E2EE_STORAGE_PREFIX}:user:${this.userId()}:conversation:${conversationId}:keys`
  },

  enabledStorageKey(conversationId) {
    return `${CHAT_E2EE_STORAGE_PREFIX}:user:${this.userId()}:conversation:${conversationId}:enabled`
  }
}

export const AutoExpandTextarea = {
  mounted() {
    this.sendingMessage = false
    this.lastSentContent = ""
    this.lastSentTime = 0
    this.lastLiveUpdateValue = null
    this.userResized = false // Track if user manually resized
    this.currentHeight = null // Track current height to preserve during LiveView updates
    this.liveUpdateEvent = this.el.dataset.liveUpdateEvent
    this.submitOnEnter = this.el.dataset.submitOnEnter !== 'false'

    // Get min/max heights from style attribute
    const style = this.el.getAttribute('style') || ''
    const minMatch = style.match(/min-height:\s*([0-9.]+)rem/)
    const maxMatch = style.match(/max-height:\s*([0-9.]+)rem/)
    this.minHeight = minMatch ? parseFloat(minMatch[1]) * 16 : 40 // Convert rem to px
    this.maxHeight = maxMatch ? parseFloat(maxMatch[1]) * 16 : 160

    // Store original style to preserve it
    this.originalStyle = this.el.getAttribute('style') || ''

    // Auto-expand textarea function
    const adjustHeight = () => {
      // Don't adjust if user has manually resized
      if (this.userResized) return

      // Store current scroll position
      const scrollPos = this.el.scrollTop

      // Temporarily set height to auto to measure content
      // But preserve other inline styles
      const currentStyleObj = this.el.style
      const oldHeight = currentStyleObj.height
      currentStyleObj.height = 'auto'

      // Calculate new height based on content
      const newHeight = Math.max(this.minHeight, Math.min(this.el.scrollHeight, this.maxHeight))

      // Set the new height while preserving other styles
      currentStyleObj.height = newHeight + 'px'
      this.currentHeight = newHeight // Store for LiveView updates

      // Restore scroll position if needed
      if (newHeight >= this.maxHeight) {
        this.el.scrollTop = scrollPos
      }
    }

    // Store the adjustHeight function
    this.adjustHeight = adjustHeight

    // Detect manual resize (mouseup on the resize handle)
    this.el.addEventListener('mousedown', (e) => {
      // Check if click is in the bottom right (resize handle area)
      const rect = this.el.getBoundingClientRect()
      const isResizeHandle = e.clientX > rect.right - 20 && e.clientY > rect.bottom - 20

      if (isResizeHandle) {
        this.userResized = true
      }
    })

    // Adjust height on any input or change
    const handleInput = () => {
      requestAnimationFrame(() => adjustHeight())

      if (this.liveUpdateEvent && this.el.value !== this.lastLiveUpdateValue) {
        this.lastLiveUpdateValue = this.el.value
        this.pushEvent(this.liveUpdateEvent, { value: this.el.value })
      }
    }

    this.el.addEventListener('input', handleInput)
    this.el.addEventListener('change', handleInput)
    this.el.addEventListener('paste', () => {
      setTimeout(handleInput, 10)
    })

    // Handle keyboard shortcuts
    this.el.addEventListener("keydown", (e) => {
      // Allow Shift+Enter for new line
      if (e.key === "Enter" && e.shiftKey) {
        // Let the default behavior happen (insert newline)
        setTimeout(() => adjustHeight(), 10)
        return
      }

      if (e.key === "Enter" && !e.shiftKey && !this.submitOnEnter) {
        setTimeout(() => adjustHeight(), 10)
        return
      }

      // Send message on Enter (without Shift)
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()

        const content = this.el.value.trim()
        const now = Date.now()

        // Enhanced duplicate prevention
        if (this.sendingMessage ||
            !content ||
            (content === this.lastSentContent && (now - this.lastSentTime) < 500)) {
          return
        }

        const form = this.el.closest("form")
        if (form) {
          this.sendingMessage = true
          this.lastSentContent = content
          this.lastSentTime = now

          // Disable the submit button temporarily
          const submitBtn = form.querySelector('button[type="submit"]')
          if (submitBtn) {
            submitBtn.disabled = true
          }

          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

          // Reset after submit
          setTimeout(() => {
            this.el.value = ""
            this.el.style.height = this.minHeight + 'px'
            this.currentHeight = this.minHeight
            this.userResized = false
            this.sendingMessage = false
            if (submitBtn) {
              submitBtn.disabled = false
            }
          }, 100)
        }
      }
    })

    // Handle clear message input event
    this.handleEvent("clear_message_input", () => {
      this.sendingMessage = false
      this.userResized = false
      this.el.value = ""
      // Use style object to preserve other CSS properties
      this.el.style.height = this.minHeight + 'px'
      this.currentHeight = this.minHeight
      this.el.focus()

      // Re-enable submit button
      const form = this.el.closest("form")
      if (form) {
        const submitBtn = form.querySelector('button[type="submit"]')
        if (submitBtn) {
          submitBtn.disabled = false
        }
      }
    })

    // Handle reset textarea event (for explicit resets)
    this.handleEvent("reset_textarea", ({id}) => {
      if (this.el.id === id) {
        this.sendingMessage = false
        this.userResized = false
        this.el.value = ""
        // Use style object to preserve other CSS properties
        this.el.style.height = this.minHeight + 'px'
        this.currentHeight = this.minHeight

        // Re-enable submit button
        const form = this.el.closest("form")
        if (form) {
          const submitBtn = form.querySelector('button[type="submit"]')
          if (submitBtn) {
            submitBtn.disabled = false
          }
        }
      }
    })

    // Listen for form submit to clear the textarea
    const form = this.el.closest("form")
    if (form) {
      form.addEventListener('submit', () => {
        setTimeout(() => {
          this.el.value = ""
          // Use style object to preserve other CSS properties
          this.el.style.height = this.minHeight + 'px'
          this.currentHeight = this.minHeight
          this.userResized = false
        }, 100)
      })
    }

    // Set initial height to match reset height for consistency
    this.el.style.height = this.minHeight + 'px'
    this.currentHeight = this.minHeight

    // Initial height adjustment (in case there's pre-filled content)
    setTimeout(() => {
      adjustHeight()
    }, 0)
  },

  updated() {
    // With phx-update="ignore", this shouldn't be called at all
    // But as a safety net, restore the height if needed
    if (this.currentHeight) {
      // Use style object to preserve other CSS properties
      this.el.style.height = this.currentHeight + 'px'
    }

    // Reset sending state
    this.sendingMessage = false
  }
}

export const SimpleChatInput = {
  mounted() {
    this.maxHeight = 150
    this.form = this.el.closest("form")
    this.awaitingSubmitClear = false
    this.valueBeforeUpdate = ""
    this.wasFocusedBeforeUpdate = false

    this.el.rows = 1
    this.el.style.boxSizing = 'border-box'
    this.baseHeight = Math.ceil(this.el.getBoundingClientRect().height || this.el.scrollHeight)
    this.el.style.height = this.baseHeight + 'px'
    this.el.style.overflowY = 'hidden'

    this.autoResize = () => {
      this.el.style.height = 'auto'
      const scrollHeight = this.el.scrollHeight
      const newHeight = scrollHeight <= this.baseHeight + 2
        ? this.baseHeight
        : Math.min(scrollHeight, this.maxHeight)
      this.el.style.height = newHeight + 'px'
      this.el.style.overflowY = scrollHeight > this.maxHeight ? 'auto' : 'hidden'
    }

    this.handleInput = () => {
      if (this.awaitingSubmitClear) {
        this.awaitingSubmitClear = false
      }

      this.autoResize()
    }

    this.el.addEventListener("input", this.handleInput)

    // Enter key handling
    this.handleKeydown = (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        if (this.form && this.el.value.trim()) {
          this.awaitingSubmitClear = true
          this.form.requestSubmit()
        }
      }
    }

    this.el.addEventListener("keydown", this.handleKeydown)

    if (this.form) {
      this.handleFormSubmit = () => {
        this.awaitingSubmitClear = true
      }

      this.form.addEventListener("submit", this.handleFormSubmit)
    }

    this.handleEvent("clear_message_input", () => {
      this.awaitingSubmitClear = false
      this.el.value = ""
      this.autoResize()
      this.el.focus()
    })

    this.focusComposer = () => {
      const activeElement = document.activeElement
      const activeTag = activeElement?.tagName
      const activeIsTypingTarget = activeTag === "INPUT" || activeTag === "TEXTAREA" || activeTag === "SELECT"
      const overlayActive =
        document.getElementById("chat-keyboard-shortcuts")?.dataset.activeOverlay === "true"

      if (
        window.matchMedia("(min-width: 640px)").matches &&
        !activeIsTypingTarget &&
        !overlayActive
      ) {
        this.el.focus({ preventScroll: true })
      }
    }

    setTimeout(this.focusComposer, 0)
  },

  beforeUpdate() {
    this.valueBeforeUpdate = this.el.value
    this.wasFocusedBeforeUpdate = document.activeElement === this.el
  },

  updated() {
    if (this.awaitingSubmitClear) {
      if (this.el.value === "") {
        this.awaitingSubmitClear = false
      }

      this.autoResize()
      return
    }

    // Keep local draft if an unrelated patch tries to shorten it while typing.
    if (
      this.wasFocusedBeforeUpdate &&
      this.valueBeforeUpdate &&
      this.el.value.length < this.valueBeforeUpdate.length
    ) {
      const cursorPosition = this.el.selectionStart
      this.el.value = this.valueBeforeUpdate

      if (cursorPosition !== null) {
        const safePosition = Math.min(cursorPosition, this.el.value.length)
        this.el.setSelectionRange(safePosition, safePosition)
      }
    }

    // Restore height after LiveView re-render
    this.autoResize()
  },

  destroyed() {
    if (this.handleInput) {
      this.el.removeEventListener("input", this.handleInput)
    }

    if (this.handleKeydown) {
      this.el.removeEventListener("keydown", this.handleKeydown)
    }

    if (this.form && this.handleFormSubmit) {
      this.form.removeEventListener("submit", this.handleFormSubmit)
    }
  }
}

export const ChatKeyboardShortcuts = {
  mounted() {
    this.handleKeydown = (event) => {
      if (event.key !== "Escape" || event.defaultPrevented) return
      if (this.el.dataset.activeOverlay !== "true") return

      event.preventDefault()
      this.pushEvent("close_chat_overlay", {})
    }

    document.addEventListener("keydown", this.handleKeydown)
  },

  destroyed() {
    if (this.handleKeydown) {
      document.removeEventListener("keydown", this.handleKeydown)
    }
  }
}

export const MessageList = {
  mounted() {
    const container = this.el
    this.isLoadingOlder = false
    this.initialScrollDone = false
    this.currentConversationId = container.dataset.conversationId

    // Check if user is near bottom (within 150px)
    const isNearBottom = () => {
      return container.scrollHeight - container.scrollTop - container.clientHeight < 150
    }

    // Smoothly scroll to bottom
    const scrollToBottom = (behavior = 'smooth') => {
      requestAnimationFrame(() => {
        container.scrollTo({
          top: container.scrollHeight,
          behavior: behavior
        })
      })
    }

    this.performInitialBottomScroll = () => {
      scrollToBottom('auto')

      ;[50, 120, 250, 500].forEach(delay => {
        setTimeout(() => scrollToBottom('auto'), delay)
      })

      setTimeout(() => {
        this.initialScrollDone = true
      }, 600)
    }

    // Show/hide "jump to bottom" button when scrolled up
    const updateJumpButton = () => {
      const hasScrolledUp = !isNearBottom()
      const jumpBtn = document.getElementById('jump-to-bottom')
      if (jumpBtn) {
        if (hasScrolledUp && this.initialScrollDone) {
          jumpBtn.classList.remove('hidden')
        } else {
          jumpBtn.classList.add('hidden')
        }
      }
    }

    // Function to check scroll position and load more messages
    const checkScrollPosition = () => {
      const scrollTop = container.scrollTop

      // Update jump button visibility
      updateJumpButton()

      // Load older messages when scrolled near top (within 100px)
      if (scrollTop < 100 && !this.isLoadingOlder) {
        this.isLoadingOlder = true
        this.pushEvent("load_older_messages", {})
      }

      // Reset loading flag when scroll position changes
      if (scrollTop > 200) {
        this.isLoadingOlder = false
      }
    }

    // Add scroll event listener with debouncing
    let scrollTimeout
    container.addEventListener('scroll', () => {
      clearTimeout(scrollTimeout)
      scrollTimeout = setTimeout(checkScrollPosition, 100)
    })

    // Handle maintaining scroll position after loading older messages
    this.handleEvent("maintain_scroll_position", () => {
      const prevHeight = container.scrollHeight
      requestAnimationFrame(() => {
        const newHeight = container.scrollHeight
        const heightDiff = newHeight - prevHeight
        container.scrollTop += heightDiff
        this.isLoadingOlder = false
      })
    })

    // Handle scroll to specific message
    this.handleEvent("scroll_to_message", ({message_id}) => {
      const messageEl = document.getElementById(`message-${message_id}`)
      if (messageEl) {
        messageEl.scrollIntoView({behavior: 'smooth', block: 'center'})
        messageEl.classList.add('highlight-message')
        setTimeout(() => messageEl.classList.remove('highlight-message'), 2000)
        this.initialScrollDone = true
      }
    })

    // Handle image loading - re-scroll if user is at bottom
    let pendingImageLoads = 0

    const handleImageLoad = () => {
      pendingImageLoads = Math.max(0, pendingImageLoads - 1)

      // Only re-scroll if user is still near bottom and initial scroll is done
      if (this.initialScrollDone && isNearBottom()) {
        scrollToBottom('auto')

        // Do one more scroll after a delay to catch any dimension changes
        setTimeout(() => {
          if (isNearBottom()) {
            scrollToBottom('auto')
          }
        }, 100)
      }
    }

    const imagesFromNode = (node) => {
      if (node.nodeType !== Node.ELEMENT_NODE) return []

      const images = node.tagName === 'IMG' ? [node] : []
      return images.concat(Array.from(node.querySelectorAll?.('img') || []))
    }

    // Add listeners only within the changed subtree instead of rescanning the full chat.
    const addImageListeners = (root = container) => {
      const images = root === container ? container.querySelectorAll('img') : imagesFromNode(root)
      images.forEach(img => {
        if (!img.dataset.listenerAdded) {
          img.dataset.listenerAdded = 'true'

          if (!img.complete) {
            pendingImageLoads++
            img.addEventListener('load', handleImageLoad, { once: true })
            img.addEventListener('error', handleImageLoad, { once: true })
          }
        }
      })
    }

    // Initial image listener setup
    addImageListeners()

    // Scroll to the latest messages on initial load.
    // Server-driven unread scrolling can still override this afterward.
    if (this.currentConversationId) {
      this.performInitialBottomScroll()
    }

    // Add image listeners when new content is added
    const imageObserver = new MutationObserver((mutations) => {
      mutations.forEach(mutation => {
        mutation.addedNodes.forEach(node => addImageListeners(node))
      })
    })

    imageObserver.observe(container, {
      childList: true,
      subtree: true
    })

    this.imageObserver = imageObserver

    // Handle scroll to bottom (server controls initial scroll)
    this.handleEvent("scroll_to_bottom", () => {
      // Aggressive initial scroll to handle images
      const doScroll = () => {
        const wasNearBottom = isNearBottom()
        scrollToBottom('auto')
        return wasNearBottom
      }

      // Immediate scroll
      doScroll()

      // Re-scroll multiple times to catch images loading
      // This is necessary because images load asynchronously
      const scrollAttempts = [50, 100, 200, 300, 500, 800, 1200, 1800]
      scrollAttempts.forEach(delay => {
        setTimeout(() => {
          // Only keep scrolling if we were at/near bottom
          // This prevents fighting with user if they scrolled up
          if (isNearBottom()) {
            scrollToBottom('auto')
          }
        }, delay)
      })

      // Mark done after all attempts
      setTimeout(() => {
        this.initialScrollDone = true
      }, 2000)
    })

    // Handle scroll to element (for unread indicator)
    this.handleEvent("scroll_to_element", ({element_id, position}) => {
      setTimeout(() => {
        const element = document.getElementById(element_id)
        if (element) {
          const block = position === 'top-third' ? 'center' : 'start'
          element.scrollIntoView({behavior: 'smooth', block: block})
          setTimeout(() => {
            this.initialScrollDone = true
          }, 500)
        }
      }, 100)
    })

    // Watch for new messages being added (after initial scroll)
    const observer = new MutationObserver((mutations) => {
      // Only process after initial scroll is complete
      if (!this.initialScrollDone) return

      // Check if new messages were added (not just timestamp updates)
      const hasNewMessages = mutations.some(mutation => {
        return Array.from(mutation.addedNodes).some(node => {
          if (node.nodeType !== 1) return false

          // Check if this is an actual message element
          if (node.id?.startsWith('message-') && !node.id?.includes('bubble') && !node.id?.includes('local-time')) {
            return true
          }

          // Check for containers with message children
          const hasMessageChild = node.querySelector?.('[id^="message-"]:not([id*="bubble"]):not([id*="local-time"])')
          return hasMessageChild ? true : false
        })
      })

      if (hasNewMessages) {
        // Add image listeners to any new images
        mutations.forEach(mutation => {
          mutation.addedNodes.forEach(node => addImageListeners(node))
        })

        // Only auto-scroll if user is near bottom (standard messenger UX)
        if (isNearBottom()) {
          requestAnimationFrame(() => {
            scrollToBottom('smooth')
          })
        } else {
          // User scrolled up - show jump button instead
          updateJumpButton()
        }
      }
    })

    observer.observe(container, {
      childList: true,
      subtree: true
    })

    this.observer = observer
  },

  updated() {
    // When conversation changes (detected by data-conversation-id change)
    const newConversationId = this.el.dataset.conversationId
    if (newConversationId && newConversationId !== this.currentConversationId) {
      // Conversation switched - reset state
      this.currentConversationId = newConversationId
      this.initialScrollDone = false
      this.isLoadingOlder = false

      // The imageObserver will automatically catch new images in the new conversation
      // No need to manually call addImageListeners - MutationObserver handles it
      this.performInitialBottomScroll()
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
    if (this.imageObserver) {
      this.imageObserver.disconnect()
    }
  }
}

export const ContextMenu = {
  mounted() {
    // Get conversation ID from data attribute
    const conversationId = this.el.dataset.conversationId

    // Handle right-click context menu
    this.contextMenuHandler = (e) => {
      e.preventDefault()
      // Hide any existing context menus first
      this.pushEvent("hide_message_context_menu", {})
      this.pushEvent("show_context_menu", {
        conversation_id: parseInt(conversationId),
        x: e.clientX,
        y: e.clientY
      })
    }
    this.el.addEventListener("contextmenu", this.contextMenuHandler)

    // Handle custom context menu event (for backwards compatibility)
    this.customEventHandler = (e) => {
      const { conversation_id, x, y } = e.detail
      // Hide any existing context menus first
      this.pushEvent("hide_message_context_menu", {})
      this.pushEvent("show_context_menu", {
        conversation_id: conversation_id,
        x: x,
        y: y
      })
    }
    this.el.addEventListener("phx:show_context_menu", this.customEventHandler)

    // Hide context menu immediately on any click
    this.clickHandler = (e) => {
      // Skip if clicking on the context menu itself
      const contextMenu = document.querySelector('[phx-click-away="hide_context_menu"]')
      if (contextMenu && !contextMenu.contains(e.target)) {
        this.pushEvent("hide_context_menu", {})
      }
    }

    document.addEventListener("click", this.clickHandler)

    // Also hide on scroll for better UX
    this.scrollHandler = () => {
      this.pushEvent("hide_context_menu", {})
    }
    this.el.addEventListener("scroll", this.scrollHandler)
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.contextMenuHandler)
    this.el.removeEventListener("phx:show_context_menu", this.customEventHandler)
    document.removeEventListener("click", this.clickHandler)
    this.el.removeEventListener("scroll", this.scrollHandler)
  }
}

export const VoiceRecorder = {
  mounted() {
    this.mediaRecorder = null
    this.audioChunks = []
    this.isRecording = false
    this.recordingTimer = null
    this.recordingSeconds = 0
    this.maxDuration = 120 // Max 2 minutes

    // UI elements
    const recordBtn = this.el
    const timerEl = document.getElementById('voice-timer')
    const cancelBtn = document.getElementById('voice-cancel')
    const sendBtn = document.getElementById('voice-send')
    const recordingIndicator = document.getElementById('voice-recording-indicator')
    this.cancelBtn = cancelBtn
    this.sendBtn = sendBtn

    const updateUI = (recording) => {
      if (recordingIndicator) {
        recordingIndicator.classList.toggle('hidden', !recording)
      }
      recordBtn.classList.toggle('text-error', recording)
      recordBtn.classList.toggle('animate-pulse', recording)
    }

    const formatTime = (seconds) => {
      const mins = Math.floor(seconds / 60)
      const secs = seconds % 60
      return `${mins}:${secs.toString().padStart(2, '0')}`
    }

    const startRecording = async () => {
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
        this.audioChunks = []

        // Use webm for better browser support, fall back to mp4
        const mimeType = MediaRecorder.isTypeSupported('audio/webm') ? 'audio/webm' : 'audio/mp4'
        this.mediaRecorder = new MediaRecorder(stream, { mimeType })

        this.mediaRecorder.ondataavailable = (e) => {
          if (e.data.size > 0) {
            this.audioChunks.push(e.data)
          }
        }

        this.mediaRecorder.onstop = () => {
          stream.getTracks().forEach(track => track.stop())
        }

        this.mediaRecorder.start(100) // Collect data every 100ms
        this.isRecording = true
        this.recordingSeconds = 0
        updateUI(true)

        // Start timer
        this.recordingTimer = setInterval(() => {
          this.recordingSeconds++
          if (timerEl) {
            timerEl.textContent = formatTime(this.recordingSeconds)
          }
          // Auto-stop at max duration
          if (this.recordingSeconds >= this.maxDuration) {
            sendRecording()
          }
        }, 1000)

      } catch (_err) {
        this.pushEvent('voice_recording_error', { error: 'Microphone access denied' })
      }
    }

    const stopRecording = () => {
      if (this.mediaRecorder && this.isRecording) {
        this.mediaRecorder.stop()
        this.isRecording = false
        clearInterval(this.recordingTimer)
        updateUI(false)
        if (timerEl) timerEl.textContent = '0:00'
      }
    }

    const cancelRecording = () => {
      stopRecording()
      this.audioChunks = []
      this.recordingSeconds = 0
    }

    const sendRecording = async () => {
      if (!this.isRecording && this.audioChunks.length === 0) return

      // Stop if still recording
      if (this.isRecording) {
        this.mediaRecorder.stop()
        this.isRecording = false
        clearInterval(this.recordingTimer)
        updateUI(false)

        // Wait for final data
        await new Promise(resolve => setTimeout(resolve, 100))
      }

      if (this.audioChunks.length === 0) return

      const mimeType = this.mediaRecorder?.mimeType || 'audio/webm'
      const audioBlob = new Blob(this.audioChunks, { type: mimeType })
      const duration = this.recordingSeconds

      // Convert to base64 for sending via LiveView
      const reader = new FileReader()
      reader.onload = () => {
        const base64 = reader.result.split(',')[1]
        this.pushEvent('send_voice_message', {
          audio_data: base64,
          duration: duration,
          mime_type: mimeType
        })
      }
      reader.readAsDataURL(audioBlob)

      // Reset
      this.audioChunks = []
      this.recordingSeconds = 0
      if (timerEl) timerEl.textContent = '0:00'
    }

    // Toggle recording on button click
    this.recordClickHandler = () => {
      if (this.isRecording) {
        sendRecording()
      } else {
        startRecording()
      }
    }
    recordBtn.addEventListener('click', this.recordClickHandler)

    // Cancel button
    if (cancelBtn) {
      this.cancelClickHandler = cancelRecording
      cancelBtn.addEventListener('click', this.cancelClickHandler)
    }

    // Send button (if separate)
    if (sendBtn) {
      this.sendClickHandler = sendRecording
      sendBtn.addEventListener('click', this.sendClickHandler)
    }

    // Handle escape to cancel
    this.escapeKeyHandler = (e) => {
      if (e.key === 'Escape' && this.isRecording) {
        cancelRecording()
      }
    }
    document.addEventListener('keydown', this.escapeKeyHandler)
  },

  destroyed() {
    if (this.recordClickHandler) {
      this.el.removeEventListener('click', this.recordClickHandler)
    }
    if (this.cancelBtn && this.cancelClickHandler) {
      this.cancelBtn.removeEventListener('click', this.cancelClickHandler)
    }
    if (this.sendBtn && this.sendClickHandler) {
      this.sendBtn.removeEventListener('click', this.sendClickHandler)
    }
    if (this.escapeKeyHandler) {
      document.removeEventListener('keydown', this.escapeKeyHandler)
    }
    if (this.recordingTimer) {
      clearInterval(this.recordingTimer)
    }
    if (this.mediaRecorder && this.isRecording) {
      this.mediaRecorder.stop()
    }
  }
}

export const MessageContextMenu = {
  mounted() {
    // Get message info from data attributes
    const messageId = this.el.dataset.messageId
    const senderId = this.el.dataset.senderId

    // Handle right-click context menu
    this.contextMenuHandler = (e) => {
      e.preventDefault()
      const selectedText = selectedTextWithin(this.el)
      // Hide any existing context menus first
      this.pushEvent("hide_context_menu", {})
      this.pushEvent("show_message_context_menu", {
        message_id: parseInt(messageId),
        sender_id: parseInt(senderId),
        selected_text: selectedText,
        x: e.clientX,
        y: e.clientY
      })
    }
    this.el.addEventListener("contextmenu", this.contextMenuHandler)

    // Handle custom message context menu event (for backwards compatibility)
    this.customEventHandler = (e) => {
      const { message_id, sender_id, x, y } = e.detail
      // Hide any existing context menus first
      this.pushEvent("hide_context_menu", {})
      this.pushEvent("show_message_context_menu", {
        message_id: message_id,
        sender_id: sender_id,
        x: x,
        y: y
      })
    }
    this.el.addEventListener("phx:show_message_context_menu", this.customEventHandler)

    // Hide context menu immediately on any click
    this.clickHandler = (e) => {
      // Skip if clicking on the context menu itself
      const contextMenu = document.querySelector('[phx-click-away="hide_message_context_menu"]')
      if (contextMenu && !contextMenu.contains(e.target)) {
        this.pushEvent("hide_message_context_menu", {})
      }
    }

    document.addEventListener("click", this.clickHandler)

    // Also hide on scroll for better UX
    this.scrollHandler = () => {
      this.pushEvent("hide_message_context_menu", {})
    }
    this.el.addEventListener("scroll", this.scrollHandler)

    // Hide on Escape key
    this.keyHandler = (e) => {
      if (e.key === "Escape") {
        this.pushEvent("hide_message_context_menu", {})
      }
    }
    document.addEventListener("keydown", this.keyHandler)
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.contextMenuHandler)
    this.el.removeEventListener("phx:show_message_context_menu", this.customEventHandler)
    document.removeEventListener("click", this.clickHandler)
    document.removeEventListener("keydown", this.keyHandler)
    this.el.removeEventListener("scroll", this.scrollHandler)
  }
}

export const CopyChatMessage = {
  mounted() {
    this.copyHandler = () => {
      const text = this.el.dataset.copyContent || ''
      const type = this.el.dataset.copyType || 'message'
      copyToClipboard(text, type)

      const hideEvent = this.el.dataset.hideEvent
      if (hideEvent) {
        this.pushEvent(hideEvent, {})
      }
    }

    this.el.addEventListener('click', this.copyHandler)
  },

  destroyed() {
    this.el.removeEventListener('click', this.copyHandler)
  }
}
