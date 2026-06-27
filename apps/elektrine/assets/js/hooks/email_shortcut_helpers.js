export function isEditableTarget(target) {
  if (!(target instanceof Element)) return false

  if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'SELECT') {
    return true
  }

  if (target.contentEditable === 'true' || target.isContentEditable) {
    return true
  }

  return Boolean(
    target.closest(
      'input, textarea, select, [contenteditable="true"], [contenteditable=""], [role="textbox"], .ProseMirror, .ql-editor'
    )
  )
}

const SHORTCUT_MODAL_SELECTOR = '[data-email-shortcuts-modal], #keyboard-shortcuts-modal'

export function closeExistingShortcutModals() {
  document.querySelectorAll(SHORTCUT_MODAL_SELECTOR).forEach((modal) => modal.remove())
}

export function registerEmailShortcutHelp(owner, callback) {
  window.activeEmailShortcutHelp = { owner, callback }

  return () => {
    if (window.activeEmailShortcutHelp?.owner === owner) {
      delete window.activeEmailShortcutHelp
    }
  }
}

export function isActiveEmailShortcutHelpOwner(owner) {
  return window.activeEmailShortcutHelp?.owner === owner
}
