import { submitFormPreservingEvents } from './utils/form_submission'

// Modal controls module for handling modal interactions
export function initModalControls() {
  // Note: Confirmation dialogs should be handled by Phoenix.JS or LiveView
  // This is kept minimal for backward compatibility only
  document.addEventListener('click', (e) => {
    const confirmBtn = e.target.closest('[data-confirm]:not([phx-click])');
    if (confirmBtn && confirmBtn.form) {
      e.preventDefault();
      const message = confirmBtn.dataset.confirm;
      if (confirm(message)) {
        submitFormPreservingEvents(confirmBtn.form, confirmBtn);
      }
    }
  });
}
