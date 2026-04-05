(function contentScript() {
  const DIRECT_FILL_MESSAGE = "fill_credentials"
  const MESSAGE_TYPES = {
    OPEN_OPTIONS: "ui:open-options",
    GET_SUGGESTIONS: "vault:get-suggestions",
    FILL_ENTRY: "vault:fill-entry",
    STAGE_ENTRY_FILL: "vault:stage-entry-fill",
    RESOLVE_STAGED_FILL: "vault:resolve-staged-fill",
    CLEAR_STAGED_FILL: "vault:clear-staged-fill",
    RECORD_SUBMISSION: "vault:record-submission",
    RESOLVE_PENDING_SAVE: "vault:resolve-pending-save",
    SAVE_PENDING: "vault:save-pending",
    DISMISS_PENDING_SAVE: "vault:dismiss-pending-save"
  }

  const state = {
    activeField: null,
    activeContext: null,
    suggestionsContext: null,
    pendingBanner: null,
    lastFilled: null,
    stagedFillTimer: null
  }

  const ui = {}
  let mutationObserver = null

  initialize()

  function initialize() {
    if (!isSupportedPage()) return

    ensureUi()
    bindExtensionMessages()
    bindPageEvents()
    refreshLoginBindings()
    scheduleStagedFillCheck(0)
    maybeShowPendingSavePrompt()
  }

  function bindExtensionMessages() {
    chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      if (message?.type !== DIRECT_FILL_MESSAGE) {
        return false
      }

      Promise.resolve()
        .then(async () => {
          const payload = message.payload || {}
          const result = fillCredentials(payload, state.activeContext)

          const stagedResponse = await runtimeMessage(
            result.filled.password
              ? { type: MESSAGE_TYPES.CLEAR_STAGED_FILL }
              : payload.entryId
                ? {
                    type: MESSAGE_TYPES.STAGE_ENTRY_FILL,
                    payload: {
                      entryId: payload.entryId,
                      pageUrl: location.href,
                      website: location.origin
                    }
                  }
                : { type: MESSAGE_TYPES.CLEAR_STAGED_FILL }
          )

          if (!stagedResponse.ok) {
            throw new Error(stagedResponse.error)
          }

          if (result.filled.password) {
            rememberFilledCredentials(payload)
          }

          sendResponse({
            ok: true,
            result,
            staged: !result.filled.password && Boolean(payload.entryId)
          })
        })
        .catch((error) => {
          sendResponse({ ok: false, error: error.message })
        })

      return true
    })
  }

  function bindPageEvents() {
    document.addEventListener("focusin", handleFocusIn, true)
    document.addEventListener("click", handleDocumentClick, true)
    window.addEventListener("scroll", updateInlineUiPosition, true)
    window.addEventListener("resize", updateInlineUiPosition)
    window.addEventListener("pageshow", () => {
      refreshLoginBindings()
      scheduleStagedFillCheck(150)
      maybeShowPendingSavePrompt()
    })

    installHistoryListeners()

    mutationObserver = new MutationObserver(() => {
      refreshLoginBindings()
      updateInlineUiPosition()
      scheduleStagedFillCheck(180)
    })

    mutationObserver.observe(document.documentElement, {
      childList: true,
      subtree: true
    })
  }

  function ensureUi() {
    if (ui.host) return

    ui.host = document.createElement("div")
    ui.host.id = "elektrine-vault-inline-root"
    document.documentElement.appendChild(ui.host)

    ui.shadow = ui.host.attachShadow({ mode: "closed" })
    ui.shadow.innerHTML = `
      <style>
        :host {
          all: initial;
        }

        .vault-button,
        .vault-popover,
        .vault-banner,
        .vault-popover *,
        .vault-banner * {
          box-sizing: border-box;
        }

        .vault-button,
        .vault-popover,
        .vault-banner {
          font-family: "Inter", ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          color: #e5e7eb;
        }

        .vault-button {
          position: fixed;
          z-index: 2147483646;
          display: none;
          align-items: center;
          gap: 6px;
          padding: 8px 12px;
          border: 1px solid rgba(168, 85, 247, 0.42);
          border-radius: 14px;
          background: rgba(168, 85, 247, 0.16);
          box-shadow: 0 10px 24px rgba(0, 0, 0, 0.28);
          cursor: pointer;
          font-size: 12px;
          font-weight: 700;
          letter-spacing: 0.04em;
          text-transform: uppercase;
          transition:
            transform 120ms ease,
            border-color 120ms ease,
            background 120ms ease;
        }

        .vault-button:hover {
          transform: translateY(-1px);
          border-color: rgba(168, 85, 247, 0.6);
          background: rgba(168, 85, 247, 0.24);
        }

        .vault-popover {
          position: fixed;
          z-index: 2147483646;
          display: none;
          width: 320px;
          overflow: hidden;
          border: 1px solid rgba(229, 231, 235, 0.1);
          border-radius: 20px;
          background: rgba(10, 10, 10, 0.96);
          box-shadow: 0 18px 40px rgba(0, 0, 0, 0.34);
        }

        .vault-popover header {
          padding: 14px 16px 10px;
          border-bottom: 1px solid rgba(229, 231, 235, 0.08);
        }

        .vault-title {
          margin: 0;
          font-size: 14px;
          font-weight: 700;
          letter-spacing: -0.02em;
        }

        .vault-subtitle {
          margin: 4px 0 0;
          color: rgba(229, 231, 235, 0.62);
          font-size: 12px;
        }

        .vault-list,
        .vault-empty,
        .vault-state {
          padding: 10px;
        }

        .vault-item {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 10px;
          padding: 10px;
          border-radius: 16px;
          transition:
            background 120ms ease,
            transform 120ms ease;
        }

        .vault-item:hover {
          background: rgba(255, 255, 255, 0.04);
          transform: translateY(-1px);
        }

        .vault-item-title {
          margin: 0;
          font-size: 13px;
          font-weight: 700;
        }

        .vault-item-meta {
          margin: 4px 0 0;
          color: rgba(229, 231, 235, 0.58);
          font-size: 12px;
        }

        .vault-action,
        .vault-link,
        .vault-banner button {
          border: 1px solid transparent;
          border-radius: 12px;
          cursor: pointer;
          font: inherit;
          font-weight: 700;
          transition:
            transform 120ms ease,
            border-color 120ms ease,
            background 120ms ease;
        }

        .vault-action,
        .vault-banner button.primary {
          padding: 8px 12px;
          background: rgba(168, 85, 247, 0.16);
          color: rgba(250, 245, 255, 0.98);
          border-color: rgba(168, 85, 247, 0.38);
        }

        .vault-link,
        .vault-banner button.secondary {
          padding: 8px 12px;
          background: rgba(148, 163, 184, 0.12);
          color: rgba(229, 231, 235, 0.92);
          border-color: rgba(148, 163, 184, 0.2);
        }

        .vault-action:hover,
        .vault-link:hover,
        .vault-banner button:hover {
          transform: translateY(-1px);
        }

        .vault-action:hover,
        .vault-banner button.primary:hover {
          border-color: rgba(168, 85, 247, 0.56);
          background: rgba(168, 85, 247, 0.24);
        }

        .vault-state p,
        .vault-empty p {
          margin: 0 0 10px;
          color: rgba(229, 231, 235, 0.68);
          font-size: 12px;
          line-height: 1.5;
        }

        .vault-state-actions,
        .vault-banner-actions {
          display: flex;
          gap: 8px;
          flex-wrap: wrap;
        }

        .vault-banner {
          position: fixed;
          top: 20px;
          right: 20px;
          z-index: 2147483646;
          display: none;
          width: min(360px, calc(100vw - 32px));
          padding: 14px;
          border: 1px solid rgba(229, 231, 235, 0.1);
          border-radius: 18px;
          background: rgba(10, 10, 10, 0.96);
          box-shadow: 0 18px 40px rgba(0, 0, 0, 0.34);
        }

        .vault-banner h3 {
          margin: 0 0 6px;
          font-size: 15px;
          letter-spacing: -0.02em;
        }

        .vault-banner p {
          margin: 0 0 12px;
          color: rgba(229, 231, 235, 0.68);
          font-size: 12px;
          line-height: 1.5;
        }

        .vault-banner label {
          display: block;
          margin-bottom: 4px;
          color: rgba(229, 231, 235, 0.84);
          font-size: 11px;
          font-weight: 700;
          text-transform: uppercase;
          letter-spacing: 0.08em;
        }

        .vault-banner input {
          width: 100%;
          margin-bottom: 10px;
          padding: 9px 11px;
          border: 1px solid rgba(229, 231, 235, 0.14);
          border-radius: 14px;
          background: linear-gradient(180deg, rgba(10, 10, 10, 0.9), rgba(23, 23, 23, 0.78));
          font: inherit;
          color: #e5e7eb;
          box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04);
        }

        .vault-banner input:focus {
          outline: 2px solid rgba(168, 85, 247, 0.45);
          border-color: rgba(168, 85, 247, 0.56);
        }

        .vault-banner-status {
          margin-bottom: 10px;
          color: #e9d5ff;
          font-size: 12px;
          font-weight: 700;
        }
      </style>
      <button class="vault-button" type="button">Elektrine</button>
      <div class="vault-popover" role="dialog" aria-label="Elektrine inline vault"></div>
      <div class="vault-banner" role="dialog" aria-label="Elektrine save login"></div>
    `

    ui.button = ui.shadow.querySelector(".vault-button")
    ui.popover = ui.shadow.querySelector(".vault-popover")
    ui.banner = ui.shadow.querySelector(".vault-banner")

    ui.button.addEventListener("click", handleInlineButtonClick)
    ui.shadow.addEventListener("click", handleShadowClick)
  }

  function refreshLoginBindings() {
    Array.from(document.forms).forEach((form) => {
      if (form.dataset.elektrineVaultBound === "true") return
      if (!findPasswordField({ form })) return

      form.addEventListener("submit", handleFormSubmit, true)
      form.dataset.elektrineVaultBound = "true"
    })
  }

  function handleFocusIn(event) {
    const field = event.target

    if (!(field instanceof HTMLInputElement)) {
      return
    }

    const context = loginContextForField(field)

    if (!context) {
      hideInlineButton()
      return
    }

    state.activeField = field
    state.activeContext = context
    state.suggestionsContext = context
    showInlineButton(field)

    if (field.type === "password") {
      scheduleStagedFillCheck(0)
    }
  }

  function handleDocumentClick(event) {
    const target = event.target

    if (ui.host.contains(target)) {
      return
    }

    if (state.activeField && target === state.activeField) {
      return
    }

    hidePopover()
  }

  async function handleInlineButtonClick() {
    if (!state.suggestionsContext) {
      return
    }

    if (ui.popover.style.display === "block") {
      hidePopover()
      return
    }

    await renderSuggestions()
  }

  async function renderSuggestions() {
    const query =
      state.suggestionsContext.usernameField?.value?.trim() ||
      state.suggestionsContext.field?.value?.trim() ||
      ""

    ui.popover.innerHTML = `
      <header>
        <p class="vault-title">Elektrine fill</p>
        <p class="vault-subtitle">Checking your vault...</p>
      </header>
    `
    positionPopover()
    ui.popover.style.display = "block"

    try {
      const response = await runtimeMessage({
        type: MESSAGE_TYPES.GET_SUGGESTIONS,
        pageUrl: location.href,
        query
      })

      if (!response.ok) {
        renderInlineState("error", response.error)
        return
      }

      if (response.status !== "ready") {
        renderInlineState(response.status)
        return
      }

      if (!response.entries.length) {
        ui.popover.innerHTML = `
          <header>
            <p class="vault-title">Elektrine fill</p>
            <p class="vault-subtitle">${escapeHtml(hostLabel())}</p>
          </header>
          <div class="vault-empty">
            <p>No matching vault entries found for this page yet.</p>
          </div>
        `
        return
      }

      ui.popover.innerHTML = `
        <header>
          <p class="vault-title">Elektrine fill</p>
          <p class="vault-subtitle">${escapeHtml(hostLabel())}</p>
        </header>
        <div class="vault-list">
          ${response.entries.map(renderSuggestionItem).join("")}
        </div>
      `
    } catch (error) {
      renderInlineState("error", error.message)
    }
  }

  function renderInlineState(status, errorMessage = "") {
    let title = "Elektrine fill"
    let message = ""
    let actions = ""

    if (status === "locked") {
      message = "Unlock the vault from the extension popup, then try again."
    } else if (status === "disconnected") {
      message = "Sign in to Elektrine in extension settings before inline fill can work."
      actions = '<button class="vault-link" data-action="open-options" type="button">Open settings</button>'
    } else if (status === "unconfigured") {
      message = "Set up your vault in the extension popup before inline fill can work."
    } else {
      title = "Elektrine error"
      message = errorMessage || "Could not load vault entries."
    }

    ui.popover.innerHTML = `
      <header>
        <p class="vault-title">${escapeHtml(title)}</p>
        <p class="vault-subtitle">${escapeHtml(hostLabel())}</p>
      </header>
      <div class="vault-state">
        <p>${escapeHtml(message)}</p>
        <div class="vault-state-actions">${actions}</div>
      </div>
    `
  }

  function renderSuggestionItem(entry) {
    return `
      <div class="vault-item">
        <div>
          <p class="vault-item-title">${escapeHtml(entry.title)}</p>
          <p class="vault-item-meta">${escapeHtml(entry.login_username || entry.website || "")}</p>
        </div>
        <button class="vault-action" data-action="fill-entry" data-entry-id="${entry.id}" type="button">
          Fill
        </button>
      </div>
    `
  }

  async function handleShadowClick(event) {
    const target = event.target.closest("[data-action]")

    if (!target) return

    const action = target.dataset.action

    if (action === "fill-entry") {
      await handleFillEntryAction(target)
      return
    }

    if (action === "open-options") {
      await runtimeMessage({ type: MESSAGE_TYPES.OPEN_OPTIONS })
      return
    }

    if (action === "dismiss-save") {
      await dismissPendingSavePrompt()
      return
    }

    if (action === "retry-save") {
      await maybeShowPendingSavePrompt()
      return
    }

    if (action === "save-pending") {
      await handleSavePendingAction()
    }
  }

  async function handleFillEntryAction(button) {
    const entryId = Number.parseInt(button.dataset.entryId || "", 10)

    if (Number.isNaN(entryId)) {
      return
    }

    button.disabled = true

    try {
      const response = await runtimeMessage({
        type: MESSAGE_TYPES.FILL_ENTRY,
        entryId
      })

      if (!response.ok) {
        throw new Error(response.error)
      }

      const context = state.suggestionsContext
      const shouldStage = shouldStageSelectedEntry(context)

      const stagedResponse = await runtimeMessage(
        shouldStage
          ? {
              type: MESSAGE_TYPES.STAGE_ENTRY_FILL,
              payload: {
                entryId,
                pageUrl: location.href,
                website: location.origin
              }
            }
          : {
              type: MESSAGE_TYPES.CLEAR_STAGED_FILL
            }
      )

      if (!stagedResponse.ok) {
        throw new Error(stagedResponse.error)
      }

      const result = fillCredentials(response.credentials, context)

      if (result.filled.password) {
        rememberFilledCredentials(response.credentials)
      }

      hidePopover()
      showBannerStatus(successMessageForFill(result, shouldStage))
    } catch (error) {
      renderInlineState("error", error.message)
    } finally {
      button.disabled = false
    }
  }

  async function handleFormSubmit(event) {
    const form = event.target

    if (!(form instanceof HTMLFormElement)) {
      return
    }

    const submission = captureSubmission(form)

    if (!submission) {
      return
    }

    const response = await runtimeMessage({
      type: MESSAGE_TYPES.RECORD_SUBMISSION,
      payload: submission
    })

    if (response.ok && response.recorded) {
      schedulePendingSaveCheck()
    }
  }

  function captureSubmission(form) {
    const passwordFields = Array.from(form.querySelectorAll('input[type="password"]')).filter(validField)

    if (!passwordFields.length || looksLikePasswordChange(passwordFields)) {
      return null
    }

    const passwordField = rankPasswordCandidates(passwordFields)[0]
    const password = passwordField?.value || ""

    if (!password) {
      return null
    }

    const usernameField = findUsernameField(passwordField)

    const submission = {
      submitUrl: location.href,
      website: location.origin,
      username: usernameField?.value?.trim() || "",
      password,
      pageTitle: document.title || hostLabel()
    }

    if (shouldSuppressSavePrompt(submission)) {
      submission.skipSave = true
    }

    return submission
  }

  async function maybeCompleteStagedFill() {
    const passwordField = findPasswordField()

    if (!passwordField) {
      return
    }

    const response = await runtimeMessage({
      type: MESSAGE_TYPES.RESOLVE_STAGED_FILL,
      page: {
        url: location.href,
        hasVisiblePasswordField: true
      }
    })

    if (!response.ok) {
      return
    }

    if (response.status === "none" || response.status === "waiting") {
      return
    }

    if (response.status !== "ready") {
      showBannerStatus(stagedFillBlockedMessage(response.status))
      return
    }

    const context = loginContextForField(passwordField) || {
      field: passwordField,
      form: passwordField.form || document,
      passwordField,
      usernameField: findUsernameField(passwordField)
    }

    const result = fillCredentials(response.credentials, context)

    if (result.filled.password) {
      rememberFilledCredentials(response.credentials)
      showBannerStatus(successMessageForFill(result, false))
    }
  }

  async function maybeShowPendingSavePrompt() {
    const response = await runtimeMessage({
      type: MESSAGE_TYPES.RESOLVE_PENDING_SAVE,
      page: {
        url: location.href,
        hasVisiblePasswordField: Boolean(findPasswordField())
      }
    })

    if (!response.ok || response.status !== "prompt") {
      hideBanner()
      return
    }

    state.pendingBanner = response.pending
    renderPendingBanner(response.vaultStatus, response.pending)
  }

  function renderPendingBanner(vaultStatus, pending) {
    if (vaultStatus === "ready") {
      ui.banner.innerHTML = `
        <h3>${pending.mode === "update" ? "Update password in Elektrine?" : "Save login to Elektrine?"}</h3>
        <p>${escapeHtml(pending.website)}</p>
        <label for="elektrine-save-title">Title</label>
        <input id="elektrine-save-title" value="${escapeAttribute(pending.title)}" />
        <label for="elektrine-save-username">Username</label>
        <input id="elektrine-save-username" value="${escapeAttribute(pending.username || "")}" />
        <div class="vault-banner-actions">
          <button class="primary" data-action="save-pending" type="button">
            ${pending.mode === "update" ? "Update" : "Save"}
          </button>
          <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
        </div>
      `
    } else if (vaultStatus === "locked") {
      ui.banner.innerHTML = `
        <h3>Unlock Elektrine to save this login</h3>
        <p>Open the extension popup, unlock your vault, then click retry here.</p>
        <div class="vault-banner-actions">
          <button class="primary" data-action="retry-save" type="button">Retry</button>
          <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
        </div>
      `
    } else if (vaultStatus === "disconnected") {
      ui.banner.innerHTML = `
        <h3>Connect Elektrine to save this login</h3>
        <p>Sign in from extension settings first, then come back and retry.</p>
        <div class="vault-banner-actions">
          <button class="primary" data-action="open-options" type="button">Open settings</button>
          <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
        </div>
      `
    } else {
      ui.banner.innerHTML = `
        <h3>Set up your vault first</h3>
        <p>Open the extension popup and finish vault setup before saving logins from pages.</p>
        <div class="vault-banner-actions">
          <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
        </div>
      `
    }

    ui.banner.style.display = "block"
  }

  async function handleSavePendingAction() {
    const titleInput = ui.shadow.querySelector("#elektrine-save-title")
    const usernameInput = ui.shadow.querySelector("#elektrine-save-username")

    const response = await runtimeMessage({
      type: MESSAGE_TYPES.SAVE_PENDING,
      payload: {
        entryId: state.pendingBanner?.entryId,
        title: titleInput?.value?.trim() || state.pendingBanner?.title || "",
        username: usernameInput?.value?.trim() || state.pendingBanner?.username || "",
        website: state.pendingBanner?.website || ""
      }
    })

    if (!response.ok) {
      showBannerStatus(response.error || "Could not save login.")
      return
    }

    showBannerStatus(response.mode === "update" ? "Password updated in Elektrine." : "Login saved to Elektrine.")
    window.setTimeout(hideBanner, 1200)
  }

  async function dismissPendingSavePrompt() {
    await runtimeMessage({ type: MESSAGE_TYPES.DISMISS_PENDING_SAVE })
    hideBanner()
  }

  function showBannerStatus(message) {
    ui.banner.innerHTML = `
      <h3>Elektrine</h3>
      <p class="vault-banner-status">${escapeHtml(message)}</p>
    `
    ui.banner.style.display = "block"
  }

  function hideBanner() {
    state.pendingBanner = null
    ui.banner.style.display = "none"
    ui.banner.innerHTML = ""
  }

  function showInlineButton(field) {
    const rect = field.getBoundingClientRect()
    ui.button.style.display = "inline-flex"
    ui.button.style.top = `${Math.max(rect.top + 8, 8)}px`
    ui.button.style.left = `${Math.max(rect.right - 96, 8)}px`
  }

  function hideInlineButton() {
    ui.button.style.display = "none"
    hidePopover()
  }

  function positionPopover() {
    const rect = state.activeField?.getBoundingClientRect()

    if (!rect) return

    const top = Math.min(rect.bottom + 8, window.innerHeight - 16)
    const left = Math.min(Math.max(rect.left, 8), window.innerWidth - 328)

    ui.popover.style.top = `${top}px`
    ui.popover.style.left = `${left}px`
  }

  function hidePopover() {
    ui.popover.style.display = "none"
    ui.popover.innerHTML = ""
  }

  function updateInlineUiPosition() {
    if (state.activeField && document.contains(state.activeField)) {
      showInlineButton(state.activeField)
      if (ui.popover.style.display === "block") {
        positionPopover()
      }
    } else {
      hideInlineButton()
    }
  }

  function fillCredentials(payload, preferredContext) {
    const password = payload.password || ""
    const username = payload.username || ""
    const passwordField = findPasswordField(preferredContext) || findPasswordField()

    if (!passwordField) {
      const usernameField = findFillableUsernameField(preferredContext)

      if (!usernameField) {
        throw new Error("No visible login field was found on this page.")
      }

      if (username) {
        setFieldValue(usernameField, username)
      }

      usernameField.focus()
      usernameField.scrollIntoView({ block: "center", behavior: "smooth" })

      return {
        filled: {
          username: Boolean(username),
          password: false
        }
      }
    }

    if (!password) {
      throw new Error("The selected entry does not include a password.")
    }

    const usernameField = username ? findUsernameField(passwordField) || findFillableUsernameField(preferredContext) : null

    if (usernameField) {
      setFieldValue(usernameField, username)
    }

    setFieldValue(passwordField, password)
    passwordField.focus()
    passwordField.scrollIntoView({ block: "center", behavior: "smooth" })

    return {
      filled: {
        username: Boolean(usernameField),
        password: true
      }
    }
  }

  function loginContextForField(field) {
    if (!validField(field)) {
      return null
    }

    const form = field.form || document
    const passwordField =
      field.type === "password" ? field : findPasswordField({ form })

    if (!passwordField) {
      const usernameField = isUsernameLikeField(field) ? field : null

      if (!usernameField) {
        return null
      }

      return {
        field,
        form,
        passwordField: null,
        usernameField
      }
    }

    return {
      field,
      form,
      passwordField,
      usernameField: findUsernameField(passwordField)
    }
  }

  function findPasswordField(preferredContext = null) {
    if (preferredContext?.passwordField && validField(preferredContext.passwordField)) {
      return preferredContext.passwordField
    }

    const containers = uniqueContainers(preferredContext?.form)

    for (const container of containers) {
      const candidates = visibleFields(container, 'input[type="password"]')
      const preferred = rankPasswordCandidates(candidates)[0]

      if (preferred) {
        return preferred
      }
    }

    return null
  }

  function findFillableUsernameField(preferredContext = null) {
    if (preferredContext?.usernameField && validField(preferredContext.usernameField)) {
      return preferredContext.usernameField
    }

    if (isUsernameLikeField(preferredContext?.field)) {
      return preferredContext.field
    }

    const containers = uniqueContainers(preferredContext?.form)

    for (const container of containers) {
      const candidate = rankUsernameCandidates(container, preferredContext?.passwordField)[0]?.field

      if (candidate) {
        return candidate
      }
    }

    return null
  }

  function findUsernameField(passwordField) {
    const container = passwordField.form || document
    return rankUsernameCandidates(container, passwordField)[0]?.field || null
  }

  function rankUsernameCandidates(container, passwordField = null) {
    const candidates = visibleFields(
      container,
      'input:not([type="hidden"]):not([type="password"])'
    ).filter(isUsernameLikeField)
    const orderedFields = Array.from(container.querySelectorAll("input"))
    const passwordIndex = passwordField ? orderedFields.indexOf(passwordField) : -1

    return candidates
      .map((field) => ({
        field,
        score: usernameFieldScore(field, orderedFields.indexOf(field), passwordIndex)
      }))
      .sort((left, right) => right.score - left.score)
  }

  function uniqueContainers(preferredForm) {
    const containers = []
    const activeForm = state.activeField?.form

    if (preferredForm) containers.push(preferredForm)
    if (activeForm && !containers.includes(activeForm)) containers.push(activeForm)

    Array.from(document.forms).forEach((form) => {
      if (!containers.includes(form)) {
        containers.push(form)
      }
    })

    containers.push(document)
    return containers
  }

  function visibleFields(root, selector) {
    return Array.from(root.querySelectorAll(selector)).filter(validField)
  }

  function validField(field) {
    if (!(field instanceof HTMLInputElement)) return false
    if (field.disabled || field.readOnly) return false
    return isVisible(field)
  }

  function rankPasswordCandidates(candidates) {
    return candidates.sort((left, right) => passwordFieldScore(right) - passwordFieldScore(left))
  }

  function passwordFieldScore(field) {
    const autocomplete = (field.autocomplete || "").toLowerCase()
    const key = `${field.name} ${field.id} ${field.placeholder}`.toLowerCase()
    let score = 0

    if (autocomplete === "current-password") score += 40
    if (autocomplete === "new-password") score -= 30
    if (/confirm|repeat|new/.test(key)) score -= 20
    if (/pass|login|signin/.test(key)) score += 12

    return score
  }

  function usernameFieldScore(field, fieldIndex, passwordIndex) {
    const autocomplete = (field.autocomplete || "").toLowerCase()
    const key = loginFieldKey(field)
    const type = normalizedFieldType(field)
    let score = 0

    if (autocomplete === "username") score += 40
    if (autocomplete === "email") score += 28
    if (type === "email") score += 18
    if (/user|login|email|identifier|account/.test(key)) score += 20
    if (looksLikeLoginField(field)) score += 12

    if (fieldIndex >= 0 && passwordIndex >= 0) {
      const distance = Math.abs(passwordIndex - fieldIndex)
      score += Math.max(18 - distance, 0)

      if (fieldIndex < passwordIndex) {
        score += 14
      }
    }

    return score
  }

  function shouldStageSelectedEntry(context) {
    return Boolean(context?.usernameField && !findPasswordField(context))
  }

  function rememberFilledCredentials(payload) {
    state.lastFilled = {
      host: location.hostname,
      username: (payload.username || "").trim().toLowerCase(),
      password: payload.password || "",
      filledAt: Date.now()
    }
  }

  function shouldSuppressSavePrompt(submission) {
    const lastFilled = state.lastFilled

    if (!lastFilled?.password) {
      return false
    }

    if (Date.now() - lastFilled.filledAt > 2 * 60 * 1000) {
      return false
    }

    if (submission.password !== lastFilled.password) {
      return false
    }

    const submissionHost = safeHost(submission.submitUrl)

    if (submissionHost && lastFilled.host && !hostsRelated(submissionHost, lastFilled.host)) {
      return false
    }

    const submittedUsername = (submission.username || "").trim().toLowerCase()

    if (lastFilled.username && submittedUsername && lastFilled.username !== submittedUsername) {
      return false
    }

    return true
  }

  function looksLikePasswordChange(passwordFields) {
    if (passwordFields.length < 2) return false

    return passwordFields.some((field) => {
      const key = `${field.name} ${field.id} ${field.placeholder}`.toLowerCase()
      return /new|confirm|repeat|current/.test(key)
    })
  }

  function isVisible(element) {
    const style = window.getComputedStyle(element)
    const rect = element.getBoundingClientRect()

    return (
      style.visibility !== "hidden" &&
      style.display !== "none" &&
      rect.width > 0 &&
      rect.height > 0
    )
  }

  function setFieldValue(element, value) {
    const prototype = Object.getPrototypeOf(element)
    const descriptor = Object.getOwnPropertyDescriptor(prototype, "value")

    if (descriptor?.set) {
      descriptor.set.call(element, value)
    } else {
      element.value = value
    }

    element.dispatchEvent(new Event("input", { bubbles: true }))
    element.dispatchEvent(new Event("change", { bubbles: true }))
  }

  function installHistoryListeners() {
    const pushState = history.pushState
    const replaceState = history.replaceState

    history.pushState = function patchedPushState(...args) {
      const result = pushState.apply(this, args)
      window.dispatchEvent(new Event("elektrine-location-change"))
      return result
    }

    history.replaceState = function patchedReplaceState(...args) {
      const result = replaceState.apply(this, args)
      window.dispatchEvent(new Event("elektrine-location-change"))
      return result
    }

    window.addEventListener("popstate", () => {
      window.dispatchEvent(new Event("elektrine-location-change"))
    })

    window.addEventListener("elektrine-location-change", () => {
      scheduleStagedFillCheck(150)
      schedulePendingSaveCheck()
    })
  }

  function scheduleStagedFillCheck(delayMs = 120) {
    window.clearTimeout(state.stagedFillTimer)
    state.stagedFillTimer = window.setTimeout(() => {
      maybeCompleteStagedFill().catch(() => {})
    }, delayMs)
  }

  function schedulePendingSaveCheck() {
    window.setTimeout(() => {
      maybeShowPendingSavePrompt()
    }, 1200)

    window.setTimeout(() => {
      maybeShowPendingSavePrompt()
    }, 3200)
  }

  function runtimeMessage(message) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage(message, (response) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message))
          return
        }

        resolve(response || { ok: false, error: "No response from extension." })
      })
    })
  }

  function hostLabel() {
    return location.hostname.replace(/^www\./, "")
  }

  function successMessageForFill(result, staged) {
    if (staged) {
      return result.filled.username
        ? "Username filled. Elektrine will fill the password on the next step."
        : "Elektrine will fill the password on the next step."
    }

    return result.filled.username ? "Filled from Elektrine." : "Password filled from Elektrine."
  }

  function stagedFillBlockedMessage(status) {
    if (status === "locked") {
      return "Unlock the vault in the extension popup to finish filling this sign-in."
    }

    if (status === "disconnected") {
      return "Sign in to Elektrine in extension settings to finish filling this sign-in."
    }

    if (status === "unconfigured") {
      return "Set up the vault in the extension popup before using staged autofill."
    }

    return "Elektrine could not finish this staged autofill."
  }

  function normalizedFieldType(field) {
    if (!(field instanceof HTMLInputElement)) {
      return ""
    }

    return (field.getAttribute("type") || "text").toLowerCase()
  }

  function loginFieldKey(field) {
    return `${field.name} ${field.id} ${field.placeholder} ${field.getAttribute("aria-label") || ""}`.toLowerCase()
  }

  function looksLikeLoginField(field) {
    if (!(field instanceof HTMLInputElement)) {
      return false
    }

    const nearbyText = [
      field.form?.getAttribute("action"),
      field.form?.id,
      field.form?.className,
      field.closest("[data-testid]")?.getAttribute("data-testid"),
      field.closest("[aria-label]")?.getAttribute("aria-label")
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase()

    return /(login|signin|sign-in|auth|account|session|continue|next)/.test(nearbyText)
  }

  function isUsernameLikeField(field) {
    if (!validField(field)) {
      return false
    }

    const autocomplete = (field.autocomplete || "").toLowerCase()
    const type = normalizedFieldType(field)
    const key = loginFieldKey(field)

    if (!["text", "email", "search", "tel", "url"].includes(type)) {
      return false
    }

    if (autocomplete === "username" || autocomplete === "email") {
      return true
    }

    return /user|login|email|identifier|account|phone|handle/.test(key) || looksLikeLoginField(field)
  }

  function isSupportedPage() {
    return /^https:\/\//.test(location.href)
  }

  function safeHost(value) {
    try {
      return new URL(value).hostname
    } catch (_error) {
      return ""
    }
  }

  function hostsRelated(left, right) {
    return left === right
  }

  function escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  }

  function escapeAttribute(value) {
    return escapeHtml(value)
  }
})()
