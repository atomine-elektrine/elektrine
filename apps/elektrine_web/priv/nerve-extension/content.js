(function contentScript() {
  const DIRECT_FILL_MESSAGE = "fill_credentials"
  const MESSAGE_TYPES = {
    OPEN_OPTIONS: "ui:open-options",
    OPEN_MANAGER: "ui:open-manager",
    GET_THEME: "nerve:get-theme",
    GET_SUGGESTIONS: "nerve:get-suggestions",
    FILL_ENTRY: "nerve:fill-entry",
    STAGE_ENTRY_FILL: "nerve:stage-entry-fill",
    RESOLVE_STAGED_FILL: "nerve:resolve-staged-fill",
    CLEAR_STAGED_FILL: "nerve:clear-staged-fill",
    RECORD_SUBMISSION: "nerve:record-submission",
    RESOLVE_PENDING_SAVE: "nerve:resolve-pending-save",
    SAVE_PENDING: "nerve:save-pending",
    DISMISS_PENDING_SAVE: "nerve:dismiss-pending-save",
    UNLOCK_SESSION: "nerve:unlock-session",
    SESSION_CHANGED: "nerve:session-changed",
    GET_PAGE_CAPTURE: "kairo:get-page-capture"
  }

  const DEFAULT_THEME_VALUES = {
    color_primary: "#5f87b8",
    color_secondary: "#c9853f",
    color_accent: "#7d99bb",
    color_base_100: "#121214",
    color_base_200: "#1a1a1d",
    color_base_300: "#2a2a31",
    color_base_content: "#e5e2e1",
    color_info: "#6f95c4",
    color_success: "#6f8b74",
    color_warning: "#c99152",
    color_error: "#a56b68"
  }

  const CSS_VAR_BY_THEME_KEY = {
    color_primary: "--primary",
    color_secondary: "--secondary",
    color_accent: "--accent",
    color_base_100: "--bg",
    color_base_200: "--bg-elevated",
    color_base_300: "--bg-muted",
    color_base_content: "--text",
    color_info: "--info",
    color_success: "--success",
    color_warning: "--warning",
    color_error: "--error"
  }

  const HEX_COLOR_PATTERN = /^#[0-9a-f]{6}$/i

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
    applyInlineTheme(null)
    void refreshInlineTheme()
    bindExtensionMessages()
    bindPageEvents()
    refreshLoginBindings()
    scheduleStagedFillCheck(0)
    maybeShowPendingSavePrompt()
  }

  function bindExtensionMessages() {
    chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      if (message?.type === MESSAGE_TYPES.SESSION_CHANGED) {
        Promise.resolve()
          .then(async () => {
            await handleSessionChanged(message.status)
            sendResponse({ ok: true })
          })
          .catch((error) => {
            sendResponse({ ok: false, error: error.message })
          })

        return true
      }

      if (message?.type === MESSAGE_TYPES.GET_PAGE_CAPTURE) {
        sendResponse({
          ok: true,
          capture: pageCapturePayload()
        })
        return true
      }

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

  function pageCapturePayload() {
    return {
      url: location.href,
      title: document.title || location.hostname || "Captured page",
      selectionText: selectedText()
    }
  }

  function selectedText() {
    const active = document.activeElement

    if (active && selectionCapableField(active)) {
      const start = Number.isInteger(active.selectionStart) ? active.selectionStart : 0
      const end = Number.isInteger(active.selectionEnd) ? active.selectionEnd : 0
      const value = typeof active.value === "string" ? active.value : ""

      if (end > start) {
        return value.slice(start, end).trim()
      }
    }

    return String(window.getSelection?.().toString() || "").trim()
  }

  function selectionCapableField(element) {
    return element instanceof HTMLTextAreaElement ||
      (element instanceof HTMLInputElement && textInputType(element.type))
  }

  function textInputType(type) {
    return ["", "email", "search", "tel", "text", "url"].includes(String(type || "").toLowerCase())
  }

  async function handleSessionChanged(status) {
    await refreshInlineTheme()

    if (status === "locked") {
      if (ui.popover.style.display === "block") {
        renderInlineState("locked")
      }

      if (state.pendingBanner) {
        await maybeShowPendingSavePrompt()
      }

      return
    }

    scheduleStagedFillCheck(0)
    await maybeShowPendingSavePrompt()

    if (ui.popover.style.display === "block" && state.suggestionsContext) {
      await renderSuggestions()
    }
  }

  function bindPageEvents() {
    document.addEventListener("focusin", handleFocusIn, true)
    document.addEventListener("focusout", handleFocusOut, true)
    document.addEventListener("click", handleDocumentClick, true)
    window.addEventListener("scroll", updateInlineUiPosition, true)
    window.addEventListener("resize", updateInlineUiPosition)
    window.visualViewport?.addEventListener("scroll", updateInlineUiPosition)
    window.visualViewport?.addEventListener("resize", updateInlineUiPosition)
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
    ui.host.id = "elektrine-nerve-inline-root"
    document.documentElement.appendChild(ui.host)

    ui.shadow = ui.host.attachShadow({ mode: "closed" })
    ui.shadow.innerHTML = `
      <style>
        :host {
          all: initial;
          color-scheme: dark;
          --bg: #121214;
          --bg-elevated: #1a1a1d;
          --bg-muted: #2a2a31;
          --panel: color-mix(in srgb, var(--bg-elevated) 90%, var(--bg-muted) 10%);
          --panel-subtle: color-mix(in srgb, var(--panel) 78%, var(--bg) 22%);
          --field: color-mix(in srgb, var(--bg-elevated) 78%, var(--bg) 22%);
          --field-hover: color-mix(in srgb, var(--bg-muted) 84%, var(--bg-elevated) 16%);
          --text: #e5e2e1;
          --muted: #e5e2e1b3;
          --muted-strong: #e5e2e1db;
          --line: color-mix(in srgb, var(--bg-muted) 88%, var(--primary) 12%);
          --line-strong: color-mix(in srgb, var(--bg-muted) 72%, var(--primary) 28%);
          --primary: #5f87b8;
          --secondary: #c9853f;
          --accent: #7d99bb;
          --info: #6f95c4;
          --primary-strong: color-mix(in srgb, var(--primary) 78%, #ffffff 22%);
          --primary-soft: color-mix(in srgb, var(--primary) 14%, var(--bg-elevated) 86%);
          --success: #6f8b74;
          --warning: #c99152;
          --error: #a56b68;
          --shadow: 0 18px 40px rgba(0, 0, 0, 0.28), 0 0 0 1px color-mix(in srgb, var(--primary) 10%, transparent);
        }

        .nerve-button,
        .nerve-popover,
        .nerve-banner,
        .nerve-popover *,
        .nerve-banner * {
          box-sizing: border-box;
        }

        .nerve-button,
        .nerve-popover,
        .nerve-banner {
          font-family: "Geist", ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          color: var(--text);
        }

        .nerve-button {
          position: fixed;
          z-index: 2147483646;
          display: none;
          align-items: center;
          justify-content: center;
          width: var(--inline-size, 28px);
          height: var(--inline-size, 28px);
          padding: 0;
          border: 1px solid var(--inline-border, var(--line));
          border-radius: var(--inline-radius, 9px);
          background: var(--inline-bg, color-mix(in srgb, var(--field) 82%, var(--primary) 18%));
          color: var(--inline-fg, var(--muted-strong));
          box-shadow: var(--inline-shadow, 0 2px 8px rgba(0, 0, 0, 0.16));
          cursor: pointer;
          opacity: 0.82;
          transition:
            opacity 120ms ease,
            border-color 120ms ease,
            background 120ms ease,
            box-shadow 120ms ease;
        }

        .nerve-button:hover,
        .nerve-button:focus-visible {
          opacity: 1;
          border-color: color-mix(in srgb, var(--primary) 44%, var(--inline-border, var(--line)) 56%);
          background: color-mix(in srgb, var(--inline-bg, var(--field)) 78%, var(--primary) 22%);
          box-shadow: 0 2px 10px rgba(0, 0, 0, 0.22);
        }

        .nerve-button:focus-visible {
          outline: 2px solid color-mix(in srgb, var(--primary) 36%, transparent);
          outline-offset: 2px;
        }

        .nerve-logo {
          width: calc(var(--inline-size, 28px) * 0.62);
          height: calc(var(--inline-size, 28px) * 0.58);
          display: block;
          fill: currentColor;
        }

        .nerve-popover {
          position: fixed;
          z-index: 2147483646;
          display: none;
          width: var(--popover-width, 320px);
          overflow: hidden;
          border: 1px solid var(--line);
          border-radius: 12px;
          background: var(--panel);
          box-shadow: var(--shadow);
        }

        .nerve-popover header {
          padding: 10px 12px 8px;
          border-bottom: 1px solid var(--line);
        }

        .nerve-title {
          margin: 0;
          font-size: 13px;
          font-weight: 700;
          letter-spacing: 0;
        }

        .nerve-subtitle {
          margin: 3px 0 0;
          color: var(--muted);
          font-size: 11px;
        }

        .nerve-list,
        .nerve-empty,
        .nerve-state {
          padding: 6px;
        }

        .nerve-item {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 10px;
          min-height: 44px;
          padding: 8px;
          border-radius: 9px;
          transition:
            background 120ms ease;
        }

        .nerve-item:hover {
          background: color-mix(in srgb, var(--accent) 8%, transparent);
        }

        .nerve-item-title {
          margin: 0;
          font-size: 13px;
          font-weight: 700;
        }

        .nerve-item-meta {
          margin: 4px 0 0;
          color: var(--muted);
          font-size: 12px;
        }

        .nerve-action,
        .nerve-link,
        .nerve-banner button {
          border: 1px solid transparent;
          border-radius: 8px;
          cursor: pointer;
          font: inherit;
          font-weight: 700;
          transition:
            transform 120ms ease,
            border-color 120ms ease,
            background 120ms ease;
        }

        .nerve-action,
        .nerve-banner button.primary {
          padding: 7px 10px;
          background: var(--primary-soft);
          color: var(--text);
          border-color: color-mix(in srgb, var(--primary) 28%, var(--line) 72%);
        }

        .nerve-link,
        .nerve-banner button.secondary {
          padding: 7px 10px;
          background: color-mix(in srgb, var(--accent) 7%, var(--bg-elevated) 93%);
          color: var(--muted-strong);
          border-color: color-mix(in srgb, var(--accent) 18%, var(--line) 82%);
        }

        .nerve-action:hover,
        .nerve-link:hover,
        .nerve-banner button:hover {
          transform: translateY(-1px);
        }

        .nerve-action:hover,
        .nerve-banner button.primary:hover {
          border-color: color-mix(in srgb, var(--primary) 42%, var(--line) 58%);
          background: color-mix(in srgb, var(--primary) 20%, var(--bg-elevated) 80%);
        }

        .nerve-state p,
        .nerve-empty p {
          margin: 0 0 10px;
          color: var(--muted);
          font-size: 12px;
          line-height: 1.5;
        }

        .nerve-state-actions,
        .nerve-banner-actions {
          display: flex;
          gap: 8px;
          flex-wrap: wrap;
        }

        .nerve-banner {
          position: fixed;
          top: 20px;
          right: 20px;
          z-index: 2147483646;
          display: none;
          width: min(360px, calc(100vw - 32px));
          padding: 14px;
          border: 1px solid var(--line);
          border-radius: 18px;
          background: var(--panel);
          box-shadow: var(--shadow);
        }

        .nerve-banner h3 {
          margin: 0 0 6px;
          font-size: 15px;
          letter-spacing: -0.02em;
        }

        .nerve-banner p {
          margin: 0 0 12px;
          color: var(--muted);
          font-size: 12px;
          line-height: 1.5;
        }

        .nerve-banner label {
          display: block;
          margin-bottom: 4px;
          color: var(--muted-strong);
          font-size: 11px;
          font-weight: 700;
          text-transform: uppercase;
          letter-spacing: 0.08em;
        }

        .nerve-banner input {
          width: 100%;
          margin-bottom: 10px;
          padding: 9px 11px;
          border: 1px solid var(--line-strong);
          border-radius: 14px;
          background: var(--field);
          font: inherit;
          color: var(--text);
          box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.03);
        }

        .nerve-banner input:focus {
          outline: 2px solid color-mix(in srgb, var(--primary) 34%, transparent);
          border-color: color-mix(in srgb, var(--primary) 52%, transparent);
        }

        .nerve-banner-status {
          margin-bottom: 10px;
          color: var(--primary-strong);
          font-size: 12px;
          font-weight: 700;
        }
      </style>
      <button class="nerve-button" type="button" aria-label="Fill with Elektrine" title="Fill with Elektrine">
        <svg class="nerve-logo" viewBox="0 0 72 66" aria-hidden="true">
          <path d="M15.872 0V38.784L55.168 21.248V0H71.168V31.616L31.744 49.152H71.168V65.152H0V0H15.872Z" />
        </svg>
      </button>
      <div class="nerve-popover" role="dialog" aria-label="Elektrine inline nerve"></div>
      <div class="nerve-banner" role="dialog" aria-label="Elektrine save login"></div>
    `

    ui.button = ui.shadow.querySelector(".nerve-button")
    ui.popover = ui.shadow.querySelector(".nerve-popover")
    ui.banner = ui.shadow.querySelector(".nerve-banner")

    ui.button.addEventListener("click", handleInlineButtonClick)
    ui.shadow.addEventListener("click", handleShadowClick)
    ui.shadow.addEventListener("keydown", handleShadowKeydown)
  }

  async function refreshInlineTheme() {
    try {
      const response = await runtimeMessage({ type: MESSAGE_TYPES.GET_THEME })

      if (response.ok) {
        applyInlineTheme(response.theme || null)
      }
    } catch (_error) {
      applyInlineTheme(null)
    }
  }

  function applyInlineTheme(theme) {
    if (!ui.host) return

    const values = {
      ...DEFAULT_THEME_VALUES,
      ...(normalizeTheme(theme)?.values || {})
    }

    for (const [themeKey, cssVar] of Object.entries(CSS_VAR_BY_THEME_KEY)) {
      ui.host.style.setProperty(cssVar, values[themeKey])
    }

    ui.host.style.setProperty("--muted", `${values.color_base_content}b3`)
    ui.host.style.setProperty("--muted-strong", `${values.color_base_content}db`)
  }

  function normalizeTheme(theme) {
    const values = theme?.values && typeof theme.values === "object" ? theme.values : theme

    if (!values || typeof values !== "object") {
      return null
    }

    const normalized = {}

    for (const key of Object.keys(DEFAULT_THEME_VALUES)) {
      const value = values[key]

      if (typeof value === "string" && HEX_COLOR_PATTERN.test(value.trim())) {
        normalized[key] = value.trim().toLowerCase()
      }
    }

    return { values: normalized }
  }

  function refreshLoginBindings() {
    Array.from(document.forms).forEach((form) => {
      if (form.dataset.elektrineNerveBound === "true") return
      if (!findPasswordField({ form })) return

      form.addEventListener("submit", handleFormSubmit, true)
      form.dataset.elektrineNerveBound = "true"
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

  function handleFocusOut(event) {
    if (event.target !== state.activeField) {
      return
    }

    window.setTimeout(() => {
      const active = document.activeElement

      if (active === ui.host) {
        return
      }

      if (!(active instanceof HTMLInputElement) || !loginContextForField(active)) {
        state.activeField = null
        state.activeContext = null
        state.suggestionsContext = null
        hideInlineButton()
      }
    }, 0)
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
        <p class="nerve-title">Elektrine fill</p>
        <p class="nerve-subtitle">Checking your nerve...</p>
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
            <p class="nerve-title">Elektrine fill</p>
            <p class="nerve-subtitle">${escapeHtml(hostLabel())}</p>
          </header>
          <div class="nerve-empty">
            <p>No matching nerve entries found for this page yet.</p>
          </div>
        `
        positionPopover()
        return
      }

      ui.popover.innerHTML = `
        <header>
          <p class="nerve-title">Elektrine fill</p>
          <p class="nerve-subtitle">${escapeHtml(hostLabel())}</p>
        </header>
        <div class="nerve-list">
          ${response.entries.map(renderSuggestionItem).join("")}
        </div>
      `
      positionPopover()
    } catch (error) {
      renderInlineState("error", error.message)
      positionPopover()
    }
  }

  function renderInlineState(status, errorMessage = "") {
    let title = "Elektrine fill"
    let message = ""
    let actions = ""

    if (status === "locked") {
      message = "Unlock Elektrine in the extension manager, then try again."
      actions = '<button class="nerve-link" data-action="open-manager" type="button">Open manager</button>'
    } else if (status === "disconnected") {
      message = "Sign in to Elektrine in extension settings before inline fill can work."
      actions = '<button class="nerve-link" data-action="open-options" type="button">Open settings</button>'
    } else if (status === "unconfigured") {
      message = "Set up account-password encryption in Elektrine before inline fill can work."
    } else {
      title = "Elektrine error"
      message = errorMessage || "Could not load nerve entries."
    }

    ui.popover.innerHTML = `
      <header>
        <p class="nerve-title">${escapeHtml(title)}</p>
        <p class="nerve-subtitle">${escapeHtml(hostLabel())}</p>
      </header>
      <div class="nerve-state">
        <p>${escapeHtml(message)}</p>
        <div class="nerve-state-actions">${actions}</div>
      </div>
    `
    positionPopover()
  }

  function renderSuggestionItem(entry) {
    return `
      <div class="nerve-item">
        <div>
          <p class="nerve-item-title">${escapeHtml(entry.title)}</p>
          <p class="nerve-item-meta">${escapeHtml(entry.login_username || entry.website || "")}</p>
        </div>
        <button class="nerve-action" data-action="fill-entry" data-entry-id="${entry.id}" type="button">
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

    if (action === "open-manager") {
      await runtimeMessage({ type: MESSAGE_TYPES.OPEN_MANAGER })
      return
    }

    if (action === "dismiss-save") {
      await dismissPendingSavePrompt()
      return
    }

    if (action === "unlock-pending") {
      await handleUnlockPendingAction(target)
      return
    }

    if (action === "save-pending") {
      await handleSavePendingAction()
    }
  }

  async function handleShadowKeydown(event) {
    if (event.key !== "Enter" || event.target?.id !== "elektrine-unlock-password") {
      return
    }

    event.preventDefault()
    const unlockButton = ui.shadow.querySelector('[data-action="unlock-pending"]')

    if (unlockButton) {
      await handleUnlockPendingAction(unlockButton)
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
        entryId,
        pageUrl: location.href
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
    renderPendingBanner(response.nerveStatus, response.pending)
  }

  function renderPendingBanner(nerveStatus, pending) {
    if (nerveStatus === "ready") {
      ui.banner.innerHTML = `
        <h3>${pending.mode === "update" ? "Update password in Elektrine?" : "Save login to Elektrine?"}</h3>
        <p>${escapeHtml(pending.website)}</p>
        <label for="elektrine-save-title">Title</label>
        <input id="elektrine-save-title" value="${escapeAttribute(pending.title)}" />
        <label for="elektrine-save-username">Username</label>
        <input id="elektrine-save-username" value="${escapeAttribute(pending.username || "")}" />
        <div class="nerve-banner-actions">
          <button class="primary" data-action="save-pending" type="button">
            ${pending.mode === "update" ? "Update" : "Save"}
          </button>
          <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
        </div>
      `
    } else if (nerveStatus === "locked") {
      renderLockedPendingBanner()
    } else if (nerveStatus === "disconnected") {
      ui.banner.innerHTML = `
        <h3>Connect Elektrine to save this login</h3>
        <p>Sign in from extension settings first, then come back and retry.</p>
        <div class="nerve-banner-actions">
          <button class="primary" data-action="open-options" type="button">Open settings</button>
          <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
        </div>
      `
    } else {
      ui.banner.innerHTML = `
        <h3>Set up account-password encryption first</h3>
        <p>Set up encrypted data in Elektrine before saving logins from pages.</p>
        <div class="nerve-banner-actions">
          <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
        </div>
      `
    }

    ui.banner.style.display = "block"
  }

  function renderLockedPendingBanner(errorMessage = "") {
    ui.banner.innerHTML = `
      <h3>Unlock Elektrine to save this login</h3>
      <p>Your account is connected. Enter your account password to unlock encrypted data in this browser.</p>
      <label for="elektrine-unlock-password">Account password</label>
      <input
        id="elektrine-unlock-password"
        type="password"
        autocomplete="current-password"
      />
      ${errorMessage ? `<p class="nerve-banner-status">${escapeHtml(errorMessage)}</p>` : ""}
      <div class="nerve-banner-actions">
        <button class="primary" data-action="unlock-pending" type="button">Unlock</button>
        <button class="secondary" data-action="dismiss-save" type="button">Dismiss</button>
      </div>
    `
    ui.banner.style.display = "block"
    ui.shadow.querySelector("#elektrine-unlock-password")?.focus()
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

  async function handleUnlockPendingAction(button) {
    const passwordInput = ui.shadow.querySelector("#elektrine-unlock-password")
    const passphrase = passwordInput?.value || ""

    if (!passphrase) {
      renderLockedPendingBanner("Enter your account password.")
      return
    }

    button.disabled = true

    const response = await runtimeMessage({
      type: MESSAGE_TYPES.UNLOCK_SESSION,
      passphrase
    })

    if (!response.ok) {
      renderLockedPendingBanner(response.error || "Could not unlock Elektrine.")
      return
    }

    await handleSavePendingAction()
  }

  async function dismissPendingSavePrompt() {
    await runtimeMessage({ type: MESSAGE_TYPES.DISMISS_PENDING_SAVE })
    hideBanner()
  }

  function showBannerStatus(message) {
    ui.banner.innerHTML = `
      <h3>Elektrine</h3>
      <p class="nerve-banner-status">${escapeHtml(message)}</p>
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
    const viewport = viewportRect()

    if (
      rect.bottom <= viewport.top ||
      rect.top >= viewport.bottom ||
      rect.right <= viewport.left ||
      rect.left >= viewport.right
    ) {
      hideInlineButton()
      return
    }

    const size = inlineButtonSize(rect)
    const position = inlineButtonPosition(field, rect, size, viewport)

    applyInlineFieldStyle(field, size)

    ui.button.style.display = "inline-flex"
    ui.button.style.top = `${position.top}px`
    ui.button.style.left = `${position.left}px`
  }

  function hideInlineButton() {
    ui.button.style.display = "none"
    hidePopover()
  }

  function positionPopover() {
    const rect = state.activeField?.getBoundingClientRect()

    if (!rect) return

    const viewport = viewportRect()
    const popoverWidth = clamp(rect.width, 280, Math.min(360, viewport.width - 16))
    const popoverHeight = ui.popover.offsetHeight || 220
    const belowTop = rect.bottom + 6
    const aboveTop = rect.top - popoverHeight - 6
    const top =
      belowTop + popoverHeight <= viewport.bottom - 8 || aboveTop < viewport.top + 8
        ? Math.min(belowTop, viewport.bottom - popoverHeight - 8)
        : aboveTop
    const left = clamp(rect.left, viewport.left + 8, viewport.right - popoverWidth - 8)

    ui.popover.style.setProperty("--popover-width", `${popoverWidth}px`)
    ui.popover.style.top = `${Math.max(top, viewport.top + 8)}px`
    ui.popover.style.left = `${left}px`
  }

  function hidePopover() {
    ui.popover.style.display = "none"
    ui.popover.innerHTML = ""
  }

  function inlineButtonSize(rect) {
    return Math.round(clamp(rect.height - 8, 22, 30))
  }

  function inlineButtonPosition(field, rect, size, viewport) {
    const inset = Math.max(4, Math.min(8, Math.round(rect.height * 0.18)))
    const centerTop = clamp(
      rect.top + (rect.height - size) / 2,
      viewport.top + 6,
      viewport.bottom - size - 6
    )
    const insideLeft = rect.right - size - inset
    const outsideRight = rect.right + 6
    const outsideLeft = rect.left - size - 6
    const canFitInside = rect.width >= size + inset * 2 + 48
    const canFitRight = outsideRight + size <= viewport.right - 6
    const canFitLeft = outsideLeft >= viewport.left + 6

    if (
      canFitInside &&
      insideLeft >= viewport.left + 6 &&
      insideLeft + size <= viewport.right - 6 &&
      !inlineButtonWouldCoverControl(field, insideLeft, centerTop, size)
    ) {
      return {
        top: centerTop,
        left: insideLeft
      }
    }

    if (canFitRight) {
      return {
        top: centerTop,
        left: outsideRight
      }
    }

    if (canFitLeft) {
      return {
        top: centerTop,
        left: outsideLeft
      }
    }

    return {
      top: centerTop,
      left: clamp(insideLeft, viewport.left + 6, viewport.right - size - 6)
    }
  }

  function inlineButtonWouldCoverControl(field, left, top, size) {
    const x = left + size / 2
    const y = top + size / 2
    const elements = document.elementsFromPoint(x, y)

    return elements.some((element) => {
      if (element === field || field.contains(element)) {
        return false
      }

      if (element === ui.host || ui.host.contains(element)) {
        return false
      }

      return isInteractiveElement(element)
    })
  }

  function isInteractiveElement(element) {
    if (!(element instanceof Element)) {
      return false
    }

    return Boolean(
      element.closest(
        'button, a, input, select, textarea, [role="button"], [role="switch"], [tabindex]:not([tabindex="-1"])'
      )
    )
  }

  function applyInlineFieldStyle(field, size) {
    const style = window.getComputedStyle(field)
    const fieldBg = usableCssColor(style.backgroundColor) ? style.backgroundColor : "var(--field)"
    const fieldFg = usableCssColor(style.color) ? style.color : "var(--muted-strong)"
    const fieldBorder = usableCssColor(style.borderTopColor) ? style.borderTopColor : "var(--line)"
    const radius = normalizeFieldRadius(style.borderTopRightRadius, size)

    ui.button.style.setProperty("--inline-size", `${size}px`)
    ui.button.style.setProperty("--inline-radius", radius)
    ui.button.style.setProperty(
      "--inline-bg",
      `color-mix(in srgb, ${fieldBg} 84%, var(--primary) 16%)`
    )
    ui.button.style.setProperty(
      "--inline-border",
      `color-mix(in srgb, ${fieldBorder} 72%, var(--primary) 28%)`
    )
    ui.button.style.setProperty("--inline-fg", fieldFg)
    ui.button.style.setProperty("--inline-shadow", "0 1px 5px rgba(0, 0, 0, 0.16)")
  }

  function normalizeFieldRadius(value, size) {
    const radius = Number.parseFloat(value)

    if (!Number.isFinite(radius)) {
      return `${Math.round(size * 0.32)}px`
    }

    return `${Math.max(6, Math.min(radius, Math.round(size * 0.45)))}px`
  }

  function usableCssColor(value) {
    if (!value || value === "transparent") {
      return false
    }

    const rgba = value.match(/^rgba?\(([^)]+)\)$/i)

    if (!rgba) {
      return true
    }

    const parts = rgba[1].split(",").map((part) => part.trim())
    const alpha = parts.length >= 4 ? Number.parseFloat(parts[3]) : 1

    return Number.isNaN(alpha) || alpha > 0.08
  }

  function viewportRect() {
    const viewport = window.visualViewport

    if (!viewport) {
      return {
        top: 0,
        right: window.innerWidth,
        bottom: window.innerHeight,
        left: 0,
        width: window.innerWidth,
        height: window.innerHeight
      }
    }

    return {
      top: viewport.offsetTop,
      right: viewport.offsetLeft + viewport.width,
      bottom: viewport.offsetTop + viewport.height,
      left: viewport.offsetLeft,
      width: viewport.width,
      height: viewport.height
    }
  }

  function clamp(value, min, max) {
    if (max < min) {
      return min
    }

    return Math.min(Math.max(value, min), max)
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
      return "Unlock Elektrine in the extension manager to finish filling this sign-in."
    }

    if (status === "disconnected") {
      return "Sign in to Elektrine in extension settings to finish filling this sign-in."
    }

    if (status === "unconfigured") {
      return "Set up account-password encryption in Elektrine before using staged autofill."
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
    return location.protocol === "https:" ||
      (location.protocol === "http:" &&
        ["localhost", "127.0.0.1", "::1"].includes(location.hostname))
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
