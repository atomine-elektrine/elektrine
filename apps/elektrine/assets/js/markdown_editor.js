// Markdown editor functionality for profile descriptions

export function initMarkdownEditor() {
  window.showMarkdownTab = showMarkdownTab;
  window.updateMarkdownPreview = updateMarkdownPreview;

  // Set up tab click handlers
  document.addEventListener('click', (e) => {
    const tabButton = e.target.closest('[data-show-tab]');
    if (tabButton) {
      e.preventDefault();
      const tab = tabButton.getAttribute('data-show-tab');
      showMarkdownTab(tab);
    }
  });
}

function showMarkdownTab(tab) {
  const editTab = document.getElementById('edit-tab');
  const previewTab = document.getElementById('preview-tab');
  const editDiv = document.getElementById('markdown-edit');
  const previewDiv = document.getElementById('markdown-preview');
  
  if (tab === 'edit') {
    editTab.classList.add('tab-active');
    previewTab.classList.remove('tab-active');
    editDiv.classList.remove('hidden');
    previewDiv.classList.add('hidden');
  } else {
    editTab.classList.remove('tab-active');
    previewTab.classList.add('tab-active');
    editDiv.classList.add('hidden');
    previewDiv.classList.remove('hidden');
    updateMarkdownPreview();
  }
}

function updateMarkdownPreview() {
  const textarea = document.getElementById('description-textarea');
  const previewContent = document.getElementById('preview-content');
  
  if (!textarea || !previewContent) return;
  
  const markdown = textarea.value.trim();
  
  if (!markdown) {
    previewContent.innerHTML = '<p class="text-base-content/50 italic">Preview will appear here...</p>';
    return;
  }
  
  // Simple client-side markdown rendering for preview
  const html = simpleMarkdownToHtml(markdown);
  previewContent.innerHTML = html;
}

function simpleMarkdownToHtml(markdown) {
  return markdown
    // Headers
    .replace(/^### (.*$)/gim, '<h3 class="text-lg font-bold mb-2">$1</h3>')
    .replace(/^## (.*$)/gim, '<h2 class="text-xl font-bold mb-2">$1</h2>')
    .replace(/^# (.*$)/gim, '<h1 class="text-2xl font-bold mb-3">$1</h1>')
    
    // Bold and italic
    .replace(/\*\*(.*?)\*\*/g, '<strong class="font-bold">$1</strong>')
    .replace(/\*(.*?)\*/g, '<em class="italic">$1</em>')
    
    // Code
    .replace(/`(.*?)`/g, '<code class="bg-base-300 px-1 rounded text-sm">$1</code>')
    
    // Links
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" class="text-primary underline" target="_blank" rel="noopener">$1</a>')
    
    // Line breaks
    .replace(/\n\n/g, '</p><p class="mb-2">')
    .replace(/\n/g, '<br>')
    
    // Lists
    .replace(/^- (.*$)/gim, '<li class="ml-4">• $1</li>')
    
    // Wrap in paragraph
    .replace(/^/, '<p class="mb-2">')
    .replace(/$/, '</p>');
}