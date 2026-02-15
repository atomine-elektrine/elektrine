// Tab switcher module for markdown editing
export function initTabSwitcher() {
  document.addEventListener('click', (e) => {
    const tabBtn = e.target.closest('[data-show-tab]');
    if (!tabBtn) return;

    e.preventDefault();
    const tabName = tabBtn.dataset.showTab;

    // Get the tab container
    const tabContainer = tabBtn.closest('.tabs');
    if (!tabContainer) return;

    // Remove active class from all tabs
    tabContainer.querySelectorAll('.tab').forEach(tab => {
      tab.classList.remove('tab-active');
    });

    // Add active class to clicked tab
    tabBtn.classList.add('tab-active');

    // Show/hide content based on tab selection
    if (tabName === 'edit') {
      const editContent = document.getElementById('edit-content');
      const previewContent = document.getElementById('preview-content');

      if (editContent) editContent.classList.remove('hidden');
      if (previewContent) previewContent.classList.add('hidden');
    } else if (tabName === 'preview') {
      const editContent = document.getElementById('edit-content');
      const previewContent = document.getElementById('preview-content');
      const textarea = document.getElementById('profile_bio');
      const previewDiv = document.getElementById('preview-html');

      if (editContent) editContent.classList.add('hidden');
      if (previewContent) previewContent.classList.remove('hidden');

      // Update preview with markdown
      if (textarea && previewDiv) {
        // Simple markdown to HTML conversion
        let html = textarea.value
          .replace(/^### (.*$)/gim, '<h3>$1</h3>')
          .replace(/^## (.*$)/gim, '<h2>$1</h2>')
          .replace(/^# (.*$)/gim, '<h1>$1</h1>')
          .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
          .replace(/\*([^*]+)\*/g, '<em>$1</em>')
          .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
          .replace(/\n/g, '<br>');

        previewDiv.innerHTML = html;
      }
    }
  });
}