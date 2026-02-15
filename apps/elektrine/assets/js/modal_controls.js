// Modal controls module for handling modal interactions
export function initModalControls() {
  // Handle modal show buttons
  document.addEventListener('click', (e) => {
    const showModalBtn = e.target.closest('[data-show-modal]');
    if (showModalBtn) {
      const modalId = showModalBtn.dataset.showModal;
      const modal = document.getElementById(modalId);
      if (modal) {
        modal.showModal();
      }
    }

    // Handle modal close buttons
    const closeModalBtn = e.target.closest('[data-close-modal]');
    if (closeModalBtn) {
      const modalId = closeModalBtn.dataset.closeModal;
      const modal = document.getElementById(modalId);
      if (modal) {
        modal.close();
      }
    }
  });

  // Note: Confirmation dialogs should be handled by Phoenix.JS or LiveView
  // This is kept minimal for backward compatibility only
  document.addEventListener('click', (e) => {
    const confirmBtn = e.target.closest('[data-confirm]:not([phx-click])');
    if (confirmBtn && confirmBtn.form) {
      e.preventDefault();
      const message = confirmBtn.dataset.confirm;
      if (confirm(message)) {
        confirmBtn.form.submit();
      }
    }
  });
}