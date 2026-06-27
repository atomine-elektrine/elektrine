// Chat-specific LiveView hook

import {
  CHAT_E2EE_MAX_DEVICES,
  CHAT_E2EE_STORAGE_PREFIX,
  arrayBufferFromBytes,
  base64ToBytes,
  bytesToBase64,
  cryptoAvailable,
  deviceFingerprintPayload,
  deviceSignaturePayload,
  devicesHash,
  extractSearchKeywords,
  importAesKey,
  importEcdsaPrivateKey,
  importEcdsaPublicKey,
  importHmacKey,
  importRsaPrivateKey,
  importRsaPublicKey,
  importStoredEcdsaPrivateKey,
  importStoredRsaPrivateKey,
  parseJson,
  randomBytes,
  randomId,
  secureStorageDelete,
  secureStorageGet,
  secureStorageSet,
  sha256Base64Url,
  signingPublicKeyPayload,
  stableDevices,
  stableJson,
  textDecoder,
  textEncoder
} from './chat_e2ee_crypto'
import {
  chatE2EEUnavailableLabel,
  chatE2EEUnavailableTitle,
  conversationKeyPreparationMessage,
  encryptedSendFailureMessage,
  encryptedSubmitBlockedMessage,
  waitingForMemberKeysMessage
} from './chat_e2ee_messages'

export const ChatE2EE = {
  mounted() {
    this.devicePromise = null
    this.lastTypingAt = 0
    this.lastDeviceRegistrationAt = 0
    this.searchTimer = null
    this.unavailableConversationKeys = new Set()
    this.conversationKeyRequests = new Map()
    this.sentPlaintexts = new Map()
    this.preparedConversationKey = null
    this.prepareConversationKeyPromise = null
    this.preparingDeviceCount = 0
    this.cachedDevice = null
    this.currentConversationId = this.conversationId()

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
    this.updateStatusMessage()
    this.syncEncryptedModeAfterPatch()
    this.maybePrepareEnabledConversationKey()
    this.decryptVisibleMessages()
  },

  updated() {
    this.resetConversationKeyCacheIfChanged()
    this.ensureDeviceRegistered()
    this.updateInputMode()
    this.updateToggleState()
    this.updateStatusMessage()
    this.syncEncryptedModeAfterPatch()
    this.maybePrepareEnabledConversationKey()
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

  resetConversationKeyCacheIfChanged() {
    const conversationId = this.conversationId()

    if (this.currentConversationId === conversationId) return

    this.currentConversationId = conversationId
    this.preparedConversationKey = null
    this.prepareConversationKeyPromise = null
    this.preparingDeviceCount = 0
  },

  devices() {
    return parseJson(this.el.dataset.chatE2eeDevices, [])
  },

  serverE2EEReady() {
    return this.el.dataset.chatE2eeReady === 'true'
  },

  localDevice() {
    if (!this.userId()) return null
    return this.cachedDevice
  },

  localDeviceAdvertised() {
    const deviceId = this.localDevice()?.device_id
    const userId = this.userId()

    if (!deviceId || !userId) return false

    return this.devices().some(device => Number(device.user_id) === userId && device.device_id === deviceId)
  },

  localDeviceSetupRequired() {
    return cryptoAvailable() && Boolean(this.userId()) && Boolean(this.conversationId()) && !this.localDeviceAdvertised()
  },

  e2eeStatus() {
    return this.el.dataset.chatE2eeStatus || 'unknown'
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
    if (!cryptoAvailable() || !this.serverE2EEReady() || !this.conversationId()) {
      return false
    }

    const devices = this.devices()
    return devices.length > 0 && devices.length <= CHAT_E2EE_MAX_DEVICES && this.localDeviceAdvertised()
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

    if (!enabled) {
      this.preparedConversationKey = null
      this.preparingDeviceCount = 0
    }
  },

  updateInputMode() {
    const form = this.messageForm()
    const textarea = this.messageInput()
    const encryptedMode = this.e2eeEnabled()

    if (!form || !textarea) return

    if (encryptedMode) {
      form.removeAttribute('phx-change')
      textarea.removeAttribute('phx-change')
    } else {
      form.setAttribute('phx-change', 'validate_upload')
      textarea.setAttribute('phx-change', 'update_message')
    }

    this.el.querySelectorAll('input[type="file"]').forEach(input => {
      input.disabled = encryptedMode
    })

    const submitButton = form.querySelector('button[type="submit"]')
    if (encryptedMode && submitButton) {
      submitButton.disabled = false
    }

    this.syncEncryptedSubmitButton()
  },

  syncEncryptedSubmitButton() {
    const form = this.messageForm()
    const textarea = this.messageInput()
    const submitButton = form?.querySelector('button[type="submit"]')

    if (!form || !textarea || !submitButton) return

    const fileInput = form.querySelector('input[type="file"]')
    const hasUploads = form.dataset.hasUploads === 'true' || (fileInput && fileInput.files.length > 0)
    const loading = form.dataset.messageLoading === 'true'

    if (loading) {
      submitButton.disabled = true
      return
    }

    if (this.e2eeReady() && this.prepareConversationKeyPromise) {
      submitButton.disabled = true
      return
    }

    if (!this.e2eeCapable()) {
      if (this.e2eeEnabled()) {
        submitButton.disabled = true
      } else if (this.serverE2EEReady()) {
        submitButton.disabled = !textarea.value.trim() && !hasUploads
      }

      return
    }

    if (!this.e2eeReady()) {
      submitButton.disabled = !textarea.value.trim() && !hasUploads
      return
    }

    submitButton.disabled = !textarea.value.trim() || hasUploads
  },

  syncEncryptedModeAfterPatch() {
    const sync = () => {
      this.updateInputMode()
      this.updateToggleState()
      this.updateStatusMessage()
    }

    if (typeof window.requestAnimationFrame === 'function') {
      window.requestAnimationFrame(() => window.requestAnimationFrame(sync))
    } else {
      setTimeout(sync, 0)
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
      ? (enabled
        ? 'Encrypted chat is ready and enabled for this browser.'
        : 'Encrypted chat is ready. Click to turn it on for this browser.')
      : chatE2EEUnavailableTitle(this.e2eeStatus(), this.localDeviceSetupRequired())

    if (label) {
      label.textContent = capable
        ? (enabled ? 'Encrypted chat on' : 'Encrypted chat ready')
        : chatE2EEUnavailableLabel(this.e2eeStatus(), this.localDeviceSetupRequired())
    }
  },

  statusElement() {
    return this.el.querySelector('[data-chat-e2ee-status-message="true"]')
  },

  setE2EEStatusMessage(message) {
    const element = this.statusElement()
    if (!element) return

    if (!message) {
      element.textContent = ''
      element.classList.add('hidden')
      return
    }

    element.textContent = message
    element.classList.remove('hidden')
  },

  updateStatusMessage() {
    if (!this.conversationId() || !this.userId()) {
      this.setE2EEStatusMessage(null)
      return
    }

    if (!cryptoAvailable()) {
      this.setE2EEStatusMessage('Encrypted chat is unavailable because this browser does not support the required crypto APIs.')
      return
    }

    if (this.e2eeCapable()) {
      if (this.e2eeEnabled() && this.prepareConversationKeyPromise) {
        this.setE2EEStatusMessage(this.conversationKeyPreparationMessage())
        return
      }

      this.setE2EEStatusMessage(
        this.e2eeEnabled()
          ? 'Ready: encrypted messages will be encrypted before they leave this browser.'
          : 'Ready: click the encrypted chat button to turn encrypted sending on for this browser.'
      )
      return
    }

    if (this.localDeviceSetupRequired()) {
      this.setE2EEStatusMessage(
        this.localDevice()?.device_id
          ? 'Registering this browser for encrypted chat. Encrypted sending will unlock automatically.'
          : 'Generating this browser\'s encrypted chat keys. Encrypted sending will unlock automatically.'
      )
      return
    }

    switch (this.e2eeStatus()) {
      case 'registering_device':
        this.setE2EEStatusMessage('Generating and registering this browser\'s chat encryption keys...')
        break
      case 'waiting_for_remote_keys':
        this.setE2EEStatusMessage('Waiting for the other side to register encryption keys. Ask them to open this chat, then try again.')
        break
      case 'waiting_for_member_keys':
        this.setE2EEStatusMessage(waitingForMemberKeysMessage(this.memberIds(), this.devices()))
        break
      case 'too_many_devices':
        this.setE2EEStatusMessage('Encrypted chat is unavailable because this conversation has too many active devices.')
        break
      default:
        this.setE2EEStatusMessage(null)
        break
    }
  },

  notifyE2EE(message, type = 'info') {
    if (typeof window.showNotification !== 'function') return

    window.showNotification(message, type, {
      title: 'Encrypted chat',
      duration: type === 'error' ? 7000 : 5000
    })
  },

  handleToggle(event) {
    const emojiButton = event.target.closest('[phx-click="insert_emoji"]')
    if (emojiButton && this.el.contains(emojiButton) && this.e2eeReady()) {
      this.handleEncryptedEmojiInsert(event, emojiButton)
      return
    }

    const toggle = event.target.closest('[data-chat-e2ee-toggle="true"]')
    if (!toggle || !this.el.contains(toggle)) return

    event.preventDefault()
    event.stopPropagation()

    if (!this.e2eeCapable()) {
      this.updateStatusMessage()
      this.notifyE2EE(chatE2EEUnavailableTitle(this.e2eeStatus(), this.localDeviceSetupRequired()), 'warning')
      return
    }

    const enabled = !this.e2eeEnabled()

    this.setE2EEEnabled(enabled)
    this.updateInputMode()
    this.updateToggleState()
    this.updateStatusMessage()

    if (enabled) {
      this.prepareConversationKeyPackages()
    }
  },

  handleEncryptedEmojiInsert(event, button) {
    const emoji = button.getAttribute('phx-value-emoji')
    const textarea = this.messageInput()

    if (!emoji || !textarea) return

    event.preventDefault()
    event.stopImmediatePropagation()

    const start = textarea.selectionStart ?? textarea.value.length
    const end = textarea.selectionEnd ?? start
    const nextValue = `${textarea.value.slice(0, start)}${emoji}${textarea.value.slice(end)}`
    const cursorPosition = start + emoji.length

    textarea.value = nextValue
    textarea.focus()
    textarea.setSelectionRange(cursorPosition, cursorPosition)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    this.syncEncryptedSubmitButton()

    this.pushEvent('toggle_emoji_picker', {})
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
          fingerprint: device.fingerprint,
          signing_public_key: {
            version: 1,
            algorithm: 'ECDSA-P256-SHA256',
            key: device.signing_public_key
          },
          device_signature: {
            version: 1,
            algorithm: 'ECDSA-P256-SHA256',
            signature: device.device_signature
          },
          label: device.label
        }, reply => {
          if (reply?.ok) {
            this.lastDeviceRegistrationAt = Date.now()
            this.updateStatusMessage()
          } else {
            const message = 'Could not register this browser for encrypted chat. Try refreshing the chat.'
            this.setE2EEStatusMessage(message)
            this.notifyE2EE(message, 'error')
          }

          resolve({ device, reply })
        })
      }))
      .catch(error => {
        const message = 'Could not set up encrypted chat keys in this browser. Try refreshing the chat.'
        console.warn('Chat E2EE device registration failed', error)
        this.setE2EEStatusMessage(message)
        this.notifyE2EE(message, 'error')
        return null
      })
      .finally(() => {
        this.devicePromise = null
      })

    return this.devicePromise
  },

  async loadOrCreateDevice() {
    const key = this.deviceStorageKey()
    const stored = await this.loadSecureJson(key)

    if (stored?.device_id && (stored?.private_key_crypto || stored?.private_key) && stored?.public_key) {
      const upgraded = await this.upgradeDeviceTrustMaterial(stored)
      this.cachedDevice = upgraded
      return upgraded
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

    const device = await this.upgradeDeviceTrustMaterial({
      device_id: randomId('web-'),
      public_key: bytesToBase64(publicKey),
      private_key_crypto: await importStoredRsaPrivateKey(bytesToBase64(privateKey)),
      key_algorithm: 'RSA-OAEP-SHA256',
      label: this.deviceLabel()
    })

    await secureStorageSet(key, device)
    this.cachedDevice = device
    return device
  },

  async loadSecureJson(key) {
    try {
      const stored = await secureStorageGet(key)
      if (stored) return stored
    } catch (_error) {
      // Fall back to localStorage once so existing browsers can migrate out of it.
    }

    const legacy = parseJson(localStorage.getItem(key), null)
    if (legacy) {
      await secureStorageSet(key, legacy)
      localStorage.removeItem(key)
    }

    return legacy
  },

  async upgradeDeviceTrustMaterial(device) {
    device = await this.migrateDevicePrivateKeys(device)

    if (device.signing_private_key_crypto && device.signing_public_key && device.fingerprint && device.device_signature) {
      return device
    }

    const signingKeyPair = await window.crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify']
    )

    const [signingPublicKey, signingPrivateKey] = await Promise.all([
      window.crypto.subtle.exportKey('spki', signingKeyPair.publicKey),
      window.crypto.subtle.exportKey('pkcs8', signingKeyPair.privateKey)
    ])

    const upgraded = {
      ...device,
      signing_public_key: bytesToBase64(signingPublicKey),
      signing_private_key_crypto: await importStoredEcdsaPrivateKey(bytesToBase64(signingPrivateKey))
    }

    upgraded.fingerprint = await this.deviceFingerprint(upgraded)
    upgraded.device_signature = await this.signDeviceFingerprint(upgraded, upgraded.fingerprint)

    await secureStorageSet(this.deviceStorageKey(), upgraded)
    localStorage.removeItem(this.deviceStorageKey())
    return upgraded
  },

  async migrateDevicePrivateKeys(device) {
    let migrated = { ...device }
    let changed = false

    if (!migrated.private_key_crypto && migrated.private_key) {
      migrated.private_key_crypto = await importStoredRsaPrivateKey(migrated.private_key)
      delete migrated.private_key
      changed = true
    }

    if (!migrated.signing_private_key_crypto && migrated.signing_private_key) {
      migrated.signing_private_key_crypto = await importStoredEcdsaPrivateKey(migrated.signing_private_key)
      delete migrated.signing_private_key
      changed = true
    }

    if (changed) {
      await secureStorageSet(this.deviceStorageKey(), migrated)
      localStorage.removeItem(this.deviceStorageKey())
    }

    return migrated
  },

  async deviceFingerprint(device) {
    return sha256Base64Url(stableJson(deviceFingerprintPayload(device)))
  },

  async signDeviceFingerprint(device, fingerprint) {
    const signingKey = device.signing_private_key_crypto || await importEcdsaPrivateKey(device.signing_private_key)
    const signature = await window.crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      signingKey,
      textEncoder.encode(stableJson(deviceSignaturePayload(device, fingerprint)))
    )

    return bytesToBase64(signature)
  },

  deviceStorageKey() {
    return `${CHAT_E2EE_STORAGE_PREFIX}:user:${this.userId()}:device`
  },

  deviceLabel() {
    const userAgent = navigator.userAgent || 'browser'
    return userAgent.length > 80 ? userAgent.slice(0, 80) : userAgent
  },

  async ensureDevicesTrusted(devices) {
    await Promise.all(stableDevices(devices).map(device => this.ensureDeviceTrusted(device)))
  },

  untrustedDeviceMessage() {
    return 'Encrypted chat was paused because a participant device key changed. Turn encrypted chat off and verify the participant before continuing.'
  },

  async ensureDeviceTrusted(device) {
    const fingerprint = await this.verifiedDeviceFingerprint(device)
    const key = this.deviceTrustStorageKey(device)
    const trusted = await this.loadSecureJson(key)

    if (trusted?.fingerprint && trusted.fingerprint !== fingerprint) {
      throw new Error('untrusted_device')
    }

    if (!trusted?.fingerprint) {
      await secureStorageSet(key, {
        fingerprint,
        device_id: device.device_id,
        trusted_at: new Date().toISOString()
      })
      localStorage.removeItem(key)
    }
  },

  async verifiedDeviceFingerprint(device) {
    const computed = await this.deviceFingerprint(device)
    const advertised = device.fingerprint || computed

    if (advertised !== computed) {
      throw new Error('untrusted_device')
    }

    const signingKeyPayload = signingPublicKeyPayload(device)
    const signaturePayload = device.device_signature
    const signature = signaturePayload?.signature || signaturePayload

    if (signingKeyPayload && signature) {
      const signingKey = await importEcdsaPublicKey(signingKeyPayload)
      const valid = await window.crypto.subtle.verify(
        { name: 'ECDSA', hash: 'SHA-256' },
        signingKey,
        base64ToBytes(signature),
        textEncoder.encode(stableJson(deviceSignaturePayload(device, advertised)))
      )

      if (!valid) {
        throw new Error('untrusted_device')
      }
    }

    return advertised
  },

  deviceTrustStorageKey(device) {
    const owner = device.recipient_handle
      ? `remote:${device.origin_domain || ''}:${device.recipient_handle}`
      : `local:${device.user_id || ''}`

    return `${CHAT_E2EE_STORAGE_PREFIX}:trust:${owner}:device:${device.device_id}`
  },

  handleInput(event) {
    if (event.target === this.messageInput()) {
      this.syncEncryptedSubmitButton()
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

    if (!form || textarea?.closest('form') !== form || !this.e2eeEnabled()) {
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

    if (!this.e2eeReady()) {
      const message = this.localDeviceSetupRequired()
        ? 'Encrypted chat is still setting up this browser. Your message was not sent yet; try again when it says ready.'
        : chatE2EEUnavailableTitle(this.e2eeStatus(), this.localDeviceSetupRequired())

      this.setE2EEStatusMessage(message)
      this.notifyE2EE(message, 'warning')

      if (submitButton) {
        submitButton.disabled = false
      }

      return
    }

    if (!content || content.startsWith('/') || hasUploads) {
      const message = encryptedSubmitBlockedMessage(content, hasUploads)
      console.warn(message)
      this.setE2EEStatusMessage(message)
      this.notifyE2EE(message, 'warning')

      if (submitButton) {
        submitButton.disabled = false
      }

      return
    }

    try {
      this.setE2EEStatusMessage('Encrypting and sending message...')
      const encryptedMessage = await this.encryptMessage(content)
      this.cacheSentPlaintext(encryptedMessage.payload.encrypted_payload, content)

      this.pushEvent('send_client_encrypted_message', encryptedMessage.payload, reply => {
        if (reply?.ok) {
          if (encryptedMessage.devicesHash) {
            this.markPackagesSent(encryptedMessage.keyUid, encryptedMessage.devicesHash)
          }

          textarea.value = ''
          textarea.dispatchEvent(new Event('input', { bubbles: true }))
          this.syncEncryptedSubmitButton()
          this.updateStatusMessage()
        } else {
          this.forgetSentPlaintext(encryptedMessage.payload.encrypted_payload)
          const message = encryptedSendFailureMessage(reply?.error)
          console.warn('Encrypted chat send failed', reply)
          this.setE2EEStatusMessage(message)
          this.notifyE2EE(message, 'error')
        }

        if (submitButton && !reply?.ok) {
          submitButton.disabled = false
        }
      })
    } catch (error) {
      const message = error?.message === 'untrusted_device'
        ? this.untrustedDeviceMessage()
        : 'Could not encrypt this message. Make sure everyone has opened this chat so their keys can register, then try again.'
      console.warn('Could not encrypt chat message', error)
      this.setE2EEStatusMessage(message)
      this.notifyE2EE(message, 'error')
      if (submitButton) {
        submitButton.disabled = false
      }
    }
  },

  conversationKeyPreparationMessage() {
    const deviceCount = this.preparingDeviceCount || this.devices().length
    return conversationKeyPreparationMessage(deviceCount)
  },

  maybePrepareEnabledConversationKey() {
    if (!this.e2eeReady() || this.preparedConversationKey || this.prepareConversationKeyPromise) return

    this.prepareConversationKeyPackages()
  },

  async prepareConversationKeyPackages() {
    if (!this.e2eeReady()) return null

    if (this.prepareConversationKeyPromise) {
      return this.prepareConversationKeyPromise
    }

    const devices = this.devices()

    this.prepareConversationKeyPromise = (async () => {
      await this.ensureDevicesTrusted(devices)
      const { keyUid, rawKeyBytes, packagesNeeded, hash } = await this.conversationKeyForDevices(devices)

      if (!packagesNeeded) {
        this.preparedConversationKey = { keyUid, hash, keyPackages: [] }
        return this.preparedConversationKey
      }

      if (this.preparedConversationKey?.keyUid === keyUid && this.preparedConversationKey?.hash === hash) {
        return this.preparedConversationKey
      }

      this.preparingDeviceCount = devices.length
      this.setE2EEStatusMessage(this.conversationKeyPreparationMessage())
      this.syncEncryptedSubmitButton()

      const keyPackages = await this.wrapConversationKey(rawKeyBytes, devices)
      this.preparedConversationKey = { keyUid, hash, keyPackages }

      return this.preparedConversationKey
    })()
      .catch(error => {
        const message = error?.message === 'untrusted_device'
          ? this.untrustedDeviceMessage()
          : 'Could not prepare encrypted chat keys. Try turning encrypted chat off and on again.'
        console.warn('Could not prepare encrypted chat keys', error)
        this.setE2EEStatusMessage(message)
        this.notifyE2EE(message, 'error')
        return null
      })
      .finally(() => {
        this.prepareConversationKeyPromise = null
        this.preparingDeviceCount = 0
        this.syncEncryptedSubmitButton()
        this.updateStatusMessage()
      })

    return this.prepareConversationKeyPromise
  },

  async encryptMessage(content) {
    const devices = this.devices()
    await this.ensureDevicesTrusted(devices)
    const { keyUid, rawKeyBytes, packagesNeeded, hash } = await this.conversationKeyForDevices(devices)
    const aesKey = await importAesKey(rawKeyBytes, ['encrypt'])
    const iv = randomBytes(12)
    const ciphertext = await window.crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      aesKey,
      textEncoder.encode(content)
    )

    let keyPackages = []

    if (packagesNeeded) {
      let prepared = this.preparedConversationKey

      if (this.prepareConversationKeyPromise) {
        prepared = await this.prepareConversationKeyPromise
      }

      if (prepared?.keyUid === keyUid && prepared?.hash === hash) {
        keyPackages = prepared.keyPackages
      } else {
        this.preparingDeviceCount = devices.length
        this.setE2EEStatusMessage(this.conversationKeyPreparationMessage())

        try {
          keyPackages = await this.wrapConversationKey(rawKeyBytes, devices)
          this.preparedConversationKey = { keyUid, hash, keyPackages }
        } finally {
          this.preparingDeviceCount = 0
        }
      }
    }

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

    if (localKeyPackages.length > 0) {
      payload.local_key_packages = localKeyPackages
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
    const activeKey = await this.loadSecureJson(this.activeKeyStorageKey(conversationId))

    if (activeKey?.key_uid && activeKey.devices_hash === hash) {
      const rawKeyBytes = await this.loadRawConversationKey(conversationId, activeKey.key_uid)

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
    await this.storeRawConversationKey(conversationId, keyUid, rawKeyBytes)
    await this.storeActiveConversationKey(conversationId, keyUid, hash, null)

    return { keyUid, rawKeyBytes, packagesNeeded: true, hash }
  },

  async wrapConversationKey(rawKeyBytes, devices) {
    return Promise.all(stableDevices(devices).map(async device => {
      const publicKey = await importRsaPublicKey(device.public_key)
      const encryptedKey = await window.crypto.subtle.encrypt(
        { name: 'RSA-OAEP' },
        publicKey,
        arrayBufferFromBytes(rawKeyBytes)
      )

      return {
        ...(Number.isInteger(device.user_id) ? { user_id: device.user_id } : {}),
        ...(device.recipient_handle ? { recipient_handle: device.recipient_handle } : {}),
        ...(device.origin_domain ? { origin_domain: device.origin_domain } : {}),
        device_id: device.device_id,
        wrapped_key: {
          version: 1,
          key_algorithm: 'RSA-OAEP-SHA256',
          encrypted_key: bytesToBase64(encryptedKey)
        }
      }
    }))
  },

  async searchTokensForKnownKeys(query) {
    const conversationId = this.conversationId()
    if (!conversationId) return []

    const keyUids = (await this.loadSecureJson(this.keyListStorageKey(conversationId))) || []
    const tokenSets = await Promise.all(keyUids.map(async keyUid => {
      const rawKeyBytes = await this.loadRawConversationKey(conversationId, keyUid)
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

    this.el
      .querySelectorAll('[data-chat-encrypted-message="true"], [data-chat-encrypted-preview="true"]')
      .forEach(element => {
        if (element.dataset.decrypted === 'true' || element.dataset.decrypted === 'failed') return
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

    const sentPlaintext = this.sentPlaintextForPayload(payload)
    if (sentPlaintext) {
      element.textContent = sentPlaintext
      this.showEncryptedMessageElement(element)
      element.dataset.decrypted = 'true'
      return
    }

    if (!payload || !conversationId || !keyUid) {
      this.showEncryptedMessageElement(element)
      return
    }

    try {
      const rawKeyBytes = await this.rawConversationKey(conversationId, keyUid, payload)
      const aesKey = await importAesKey(rawKeyBytes, ['decrypt'])
      const plaintext = await window.crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: base64ToBytes(payload.iv) },
        aesKey,
        arrayBufferFromBytes(base64ToBytes(payload.ciphertext))
      )

      element.textContent = textDecoder.decode(plaintext)
      this.showEncryptedMessageElement(element)
      element.dataset.decrypted = 'true'
    } catch (error) {
      if (error?.code !== 'key_not_found' && error?.message !== 'key_not_found') {
        console.warn('Could not decrypt chat message', error)
      }

      element.textContent = 'Encrypted message'
      this.showEncryptedMessageElement(element)
      element.dataset.decrypted = 'failed'
    }
  },

  showEncryptedMessageElement(element) {
    element.classList.remove('opacity-0', 'opacity-80')
  },

  sentPlaintextCacheKey(payload) {
    if (!payload?.key_uid || !payload?.ciphertext) return null
    return `${payload.key_uid}:${payload.ciphertext}`
  },

  cacheSentPlaintext(payload, plaintext) {
    const key = this.sentPlaintextCacheKey(payload)
    if (!key || !plaintext) return

    this.sentPlaintexts.set(key, plaintext)

    if (this.sentPlaintexts.size > 50) {
      this.sentPlaintexts.delete(this.sentPlaintexts.keys().next().value)
    }

    setTimeout(() => this.sentPlaintexts.delete(key), 5 * 60 * 1000)
  },

  forgetSentPlaintext(payload) {
    const key = this.sentPlaintextCacheKey(payload)
    if (key) this.sentPlaintexts.delete(key)
  },

  sentPlaintextForPayload(payload) {
    const key = this.sentPlaintextCacheKey(payload)
    return key ? this.sentPlaintexts.get(key) : null
  },

  async rawConversationKey(conversationId, keyUid, payload = null) {
    const stored = await this.loadRawConversationKey(conversationId, keyUid)
    if (stored) return stored

    const cacheKey = `${conversationId}:${keyUid}`
    if (this.unavailableConversationKeys.has(cacheKey)) {
      throw new Error('key_not_found')
    }

    const pendingRequest = this.conversationKeyRequests.get(cacheKey)
    if (pendingRequest) return pendingRequest

    const request = (async () => {
      const device = await this.loadOrCreateDevice()
      const inlinePackage = this.inlineKeyPackageForDevice(payload, device.device_id)

      if (inlinePackage?.wrapped_key?.encrypted_key) {
        const rawKeyBytes = await this.decryptWrappedConversationKey(device, inlinePackage.wrapped_key)
        await this.storeRawConversationKey(conversationId, keyUid, rawKeyBytes)
        return rawKeyBytes
      }

      const wrappedKey = await new Promise((resolve, reject) => {
        this.pushEvent(
          'chat_e2ee_key',
          {
            conversation_id: conversationId,
            device_id: device.device_id,
            key_uid: keyUid
          },
          reply => {
            if (reply?.ok && reply.wrapped_key) {
              resolve(reply.wrapped_key)
            } else {
              const error = new Error(reply?.error || 'Wrapped key not found')
              error.code = reply?.error
              reject(error)
            }
          }
        )
      })

      const rawKeyBytes = await this.decryptWrappedConversationKey(device, wrappedKey)

      await this.storeRawConversationKey(conversationId, keyUid, rawKeyBytes)

      const hash = await devicesHash(this.devices())
      await this.storeActiveConversationKey(conversationId, keyUid, hash, hash)

      return rawKeyBytes
    })()
      .catch(error => {
        if (error?.code === 'key_not_found' || error?.message === 'key_not_found') {
          this.unavailableConversationKeys.add(cacheKey)
        }

        throw error
      })
      .finally(() => {
        this.conversationKeyRequests.delete(cacheKey)
      })

    this.conversationKeyRequests.set(cacheKey, request)
    return request
  },

  inlineKeyPackageForDevice(payload, deviceId) {
    const packages = [
      ...(payload?.local_key_packages || payload?.localKeyPackages || []),
      ...(payload?.key_packages || payload?.keyPackages || []),
      ...(payload?.federated_key_packages || payload?.federatedKeyPackages || [])
    ]

    return packages.find(keyPackage => keyPackage?.device_id === deviceId)
  },

  async decryptWrappedConversationKey(device, wrappedKey) {
    const privateKey = device.private_key_crypto || await importRsaPrivateKey(device.private_key)
    const rawKey = await window.crypto.subtle.decrypt(
      { name: 'RSA-OAEP' },
      privateKey,
      arrayBufferFromBytes(base64ToBytes(wrappedKey.encrypted_key))
    )

    return new Uint8Array(rawKey)
  },

  async loadRawConversationKey(conversationId, keyUid) {
    const storageKey = this.rawKeyStorageKey(conversationId, keyUid)
    const cacheKey = this.rawConversationKeyCacheKey(conversationId, keyUid)

    if (!this.rawConversationKeyCache) this.rawConversationKeyCache = new Map()
    if (this.rawConversationKeyCache.has(cacheKey)) return this.rawConversationKeyCache.get(cacheKey)

    let key = null

    try {
      key = await secureStorageGet(storageKey)
    } catch (_error) {
      key = null
    }

    if (key) {
      const bytes = base64ToBytes(key)
      this.rawConversationKeyCache.set(cacheKey, bytes)
      await secureStorageDelete(storageKey)
      return bytes
    }

    const legacyKey = localStorage.getItem(storageKey)
    if (legacyKey) {
      const bytes = base64ToBytes(legacyKey)
      localStorage.removeItem(storageKey)
      this.rawConversationKeyCache.set(cacheKey, bytes)
      return bytes
    }

    return null
  },

  async storeRawConversationKey(conversationId, keyUid, rawKeyBytes) {
    if (!this.rawConversationKeyCache) this.rawConversationKeyCache = new Map()
    this.rawConversationKeyCache.set(this.rawConversationKeyCacheKey(conversationId, keyUid), rawKeyBytes)

    await secureStorageDelete(this.rawKeyStorageKey(conversationId, keyUid))
    localStorage.removeItem(this.rawKeyStorageKey(conversationId, keyUid))

    const listKey = this.keyListStorageKey(conversationId)
    const keyUids = (await this.loadSecureJson(listKey)) || []
    if (!keyUids.includes(keyUid)) {
      await secureStorageSet(listKey, [...keyUids, keyUid])
      localStorage.removeItem(listKey)
    }
  },

  async storeActiveConversationKey(conversationId, keyUid, devicesHashValue, packagesSentHash) {
    const key = this.activeKeyStorageKey(conversationId)
    await secureStorageSet(key, {
      key_uid: keyUid,
      devices_hash: devicesHashValue,
      packages_sent_hash: packagesSentHash
    })
    localStorage.removeItem(key)
  },

  markPackagesSent(keyUid, devicesHashValue) {
    const conversationId = this.conversationId()
    if (!conversationId) return

    this.storeActiveConversationKey(conversationId, keyUid, devicesHashValue, devicesHashValue).catch(() => null)
  },

  rawKeyStorageKey(conversationId, keyUid) {
    return `${CHAT_E2EE_STORAGE_PREFIX}:user:${this.userId()}:conversation:${conversationId}:key:${keyUid}`
  },

  rawConversationKeyCacheKey(conversationId, keyUid) {
    return `${conversationId}:${keyUid}`
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
