// Form helper functions for various UI interactions
export function initFormHelpers() {
  // Handle copy to clipboard
  document.addEventListener('click', (e) => {
    const copyBtn = e.target.closest('[data-copy-to-clipboard]');
    if (copyBtn) {
      e.preventDefault();
      const text = copyBtn.dataset.copyToClipboard;
      navigator.clipboard.writeText(text).then(() => {
        // Optional: Show feedback
        const originalText = copyBtn.textContent;
        copyBtn.textContent = 'Copied!';
        setTimeout(() => {
          copyBtn.textContent = originalText;
        }, 2000);
      });
    }
  });

  // Handle select all checkboxes
  document.addEventListener('change', (e) => {
    if (e.target.matches('[data-select-all]')) {
      const targetClass = e.target.dataset.selectAll;
      const checkboxes = document.querySelectorAll(`.${targetClass}`);
      checkboxes.forEach(cb => cb.checked = e.target.checked);
    }
  });

  // Handle form submit confirmations
  document.addEventListener('submit', (e) => {
    const form = e.target;
    const confirmMessage = form.dataset.submitConfirm;
    if (confirmMessage && !confirm(confirmMessage)) {
      e.preventDefault();
    }
  });

  // Handle toggle visibility
  document.addEventListener('click', (e) => {
    const toggleBtn = e.target.closest('[data-toggle-visibility]');
    if (toggleBtn) {
      e.preventDefault();
      const targetId = toggleBtn.dataset.toggleVisibility;
      const target = document.getElementById(targetId);
      if (target) {
        target.classList.toggle('hidden');
      }
    }
  });

  // Handle auto-submit toggles
  document.addEventListener('change', (e) => {
    if (e.target.matches('[data-auto-submit]')) {
      const targetId = e.target.dataset.autoSubmit;
      const targetInput = document.getElementById(targetId);
      if (targetInput) {
        targetInput.value = e.target.checked ? 'true' : 'false';
      }
      // Submit the form
      const form = e.target.closest('form');
      if (form) {
        form.submit();
      }
    }
  });

  // Handle auto-submit selects (replaces onchange="this.form.submit()")
  document.addEventListener('change', (e) => {
    if (e.target.matches('select[data-submit-on-change]')) {
      const form = e.target.closest('form');
      if (form) {
        form.submit();
      }
    }
  });

  // Handle dialog modal open/close (replaces onclick="document.getElementById('x').showModal()")
  document.addEventListener('click', (e) => {
    const openBtn = e.target.closest('[data-open-modal]');
    if (openBtn) {
      const modal = document.getElementById(openBtn.dataset.openModal);
      if (modal) modal.showModal();
    }

    const closeBtn = e.target.closest('[data-close-modal]');
    if (closeBtn) {
      const modal = document.getElementById(closeBtn.dataset.closeModal);
      if (modal) modal.close();
    }
  });

  // Handle external links
  document.addEventListener('click', (e) => {
    const externalLink = e.target.closest('[data-external-link]');
    if (externalLink) {
      e.preventDefault();
      const url = externalLink.dataset.externalLink;
      window.open(url, '_blank');
    }
  });
}