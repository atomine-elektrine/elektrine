// Markdown toolbar module for email compose
export function initMarkdownToolbar() {
  // Handle tab switching
  document.addEventListener('click', (e) => {
    const tab = e.target.closest('[data-editor-tab]');
    if (tab) {
      e.preventDefault();
      const mode = tab.dataset.editorTab;

      // Update tab states
      document.querySelectorAll('[data-editor-tab]').forEach(t => {
        t.classList.remove('tab-active');
      });
      tab.classList.add('tab-active');

      const container = document.getElementById('editor-container');
      const writeDiv = document.getElementById('editor-write');
      const previewDiv = document.getElementById('editor-preview');
      const toolbar = document.getElementById('formatting-toolbar');
      const textarea = document.getElementById('html-editor');
      const previewContent = document.getElementById('preview-content');

      // Reset container classes
      container.classList.remove('flex', 'gap-2');
      writeDiv.classList.remove('hidden', 'w-1/2');
      previewDiv.classList.remove('hidden', 'w-1/2');

      if (mode === 'write') {
        writeDiv.classList.remove('hidden');
        previewDiv.classList.add('hidden');
        toolbar.classList.remove('hidden');
      } else if (mode === 'preview') {
        writeDiv.classList.add('hidden');
        previewDiv.classList.remove('hidden');
        toolbar.classList.add('hidden');

        // Update preview
        if (previewContent && textarea) {
          updatePreview(textarea.value, previewContent);
        }
      } else if (mode === 'split') {
        // Split view
        container.classList.add('flex', 'gap-2');
        writeDiv.classList.remove('hidden');
        writeDiv.classList.add('w-1/2');
        previewDiv.classList.remove('hidden');
        previewDiv.classList.add('w-1/2');
        toolbar.classList.remove('hidden');

        // Update preview
        if (previewContent && textarea) {
          updatePreview(textarea.value, previewContent);
        }

        // Auto-update preview on input in split mode
        textarea.oninput = () => {
          updatePreview(textarea.value, previewContent);
        };
      }
    }
  });

  // Handle markdown format buttons
  document.addEventListener('click', (e) => {
    const formatBtn = e.target.closest('[data-markdown-format]');
    if (!formatBtn) return;

    e.preventDefault();
    const format = formatBtn.dataset.markdownFormat;
    const targetId = formatBtn.dataset.target || 'html-editor';
    const textarea = document.getElementById(targetId);

    if (!textarea) return;

    const start = textarea.selectionStart;
    const end = textarea.selectionEnd;
    const selectedText = textarea.value.substring(start, end);
    const beforeText = textarea.value.substring(0, start);
    const afterText = textarea.value.substring(end);

    let newText = '';
    let cursorOffset = 0;

    switch(format) {
      case 'bold':
        newText = selectedText ? `**${selectedText}**` : '**bold text**';
        cursorOffset = selectedText ? 2 + selectedText.length : 2;
        break;

      case 'italic':
        newText = selectedText ? `*${selectedText}*` : '*italic text*';
        cursorOffset = selectedText ? 1 + selectedText.length : 1;
        break;

      case 'code':
        newText = selectedText ? `\`${selectedText}\`` : '`code`';
        cursorOffset = selectedText ? 1 + selectedText.length : 1;
        break;

      case 'code-block':
        newText = selectedText ? `\`\`\`\n${selectedText}\n\`\`\`` : '```\ncode block\n```';
        cursorOffset = selectedText ? 4 : 4;
        break;

      case 'link':
        newText = selectedText ? `[${selectedText}](url)` : '[link text](url)';
        cursorOffset = selectedText ? 3 + selectedText.length : 11;
        break;

      case 'list-bullet':
        const lines = selectedText ? selectedText.split('\n') : [''];
        newText = lines.map(line => `- ${line}`).join('\n');
        cursorOffset = 2;
        break;

      case 'list-number':
        const numberedLines = selectedText ? selectedText.split('\n') : [''];
        newText = numberedLines.map((line, i) => `${i + 1}. ${line}`).join('\n');
        cursorOffset = 3;
        break;

      case 'quote':
        const quoteLines = selectedText ? selectedText.split('\n') : [''];
        newText = quoteLines.map(line => `> ${line}`).join('\n');
        cursorOffset = 2;
        break;

      case 'h1':
        newText = selectedText ? `# ${selectedText}` : '# Heading 1';
        cursorOffset = selectedText ? 2 : 2;
        break;

      case 'h2':
        newText = selectedText ? `## ${selectedText}` : '## Heading 2';
        cursorOffset = selectedText ? 3 : 3;
        break;

      case 'h3':
        newText = selectedText ? `### ${selectedText}` : '### Heading 3';
        cursorOffset = selectedText ? 4 : 4;
        break;

      case 'heading':
        newText = selectedText ? `## ${selectedText}` : '## Heading';
        cursorOffset = selectedText ? 3 : 3;
        break;

      default:
        return;
    }

    textarea.value = beforeText + newText + afterText;
    textarea.selectionStart = start + cursorOffset;
    textarea.selectionEnd = start + cursorOffset;
    textarea.focus();

    // Trigger input event for any listeners
    textarea.dispatchEvent(new Event('input', { bubbles: true }));
  });
}

// Convert markdown to HTML for preview
function updatePreview(markdown, previewElement) {
  if (!previewElement) {
    return;
  }

  if (!markdown || markdown.trim() === '') {
    previewElement.innerHTML = '<p class="text-base-content/50">Nothing to preview yet...</p>';
    return;
  }

  // Process markdown line by line for better handling
  const lines = markdown.split('\n');
  const htmlLines = [];
  let inCodeBlock = false;
  let codeBlockLines = [];

  for (let line of lines) {
    // Handle code blocks
    if (line.startsWith('```')) {
      if (inCodeBlock) {
        htmlLines.push(`<pre><code>${codeBlockLines.join('\n')}</code></pre>`);
        codeBlockLines = [];
        inCodeBlock = false;
      } else {
        inCodeBlock = true;
      }
      continue;
    }

    if (inCodeBlock) {
      codeBlockLines.push(escapeHtml(line));
      continue;
    }

    // Process individual line
    let processedLine = line;

    // Headers (must be at line start)
    if (line.startsWith('### ')) {
      processedLine = `<h3>${escapeHtml(line.substring(4))}</h3>`;
    } else if (line.startsWith('## ')) {
      processedLine = `<h2>${escapeHtml(line.substring(3))}</h2>`;
    } else if (line.startsWith('# ')) {
      processedLine = `<h1>${escapeHtml(line.substring(2))}</h1>`;
    }
    // Blockquotes
    else if (line.startsWith('> ')) {
      processedLine = `<blockquote>${processMarkdownInline(line.substring(2))}</blockquote>`;
    }
    // Unordered lists
    else if (line.startsWith('- ') || line.startsWith('* ')) {
      processedLine = `<li>${processMarkdownInline(line.substring(2))}</li>`;
    }
    // Ordered lists
    else if (/^\d+\. /.test(line)) {
      processedLine = `<li>${processMarkdownInline(line.replace(/^\d+\. /, ''))}</li>`;
    }
    // Regular paragraph
    else if (line.trim() !== '') {
      processedLine = `<p>${processMarkdownInline(line)}</p>`;
    } else {
      processedLine = '<br>';
    }

    htmlLines.push(processedLine);
  }

  // Handle any unclosed code block
  if (inCodeBlock && codeBlockLines.length > 0) {
    htmlLines.push(`<pre><code>${codeBlockLines.join('\n')}</code></pre>`);
  }

  // Wrap consecutive list items in ul tags
  const finalHtml = htmlLines.join('\n').replace(/(<li>.*<\/li>\n)+/g, (match) => {
    return `<ul class="list-disc list-inside">${match}</ul>`;
  });

  previewElement.innerHTML = finalHtml;
}

// Process inline markdown (bold, italic, code, links)
function processMarkdownInline(text) {
  return escapeHtml(text)
    // Bold (must come before italic)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    // Italic
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    // Inline code
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    // Links
    .replace(/\[([^\]]+)\]\(([^\)]+)\)/g, '<a href="$2" target="_blank">$1</a>');
}

// Escape HTML to prevent XSS
function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}