// Markdown editor functionality for profile descriptions

export function initMarkdownEditor() {
  // Set up tab click handlers
  document.addEventListener('click', (e) => {
    const tabButton = e.target.closest('[data-show-tab]');
    if (tabButton) {
      e.preventDefault();
      const tab = tabButton.getAttribute('data-show-tab');
      showMarkdownTab(tab);
    }
  });

  document.addEventListener('input', (e) => {
    if (e.target.matches('[data-markdown-preview-input]')) {
      updateMarkdownPreview();
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

  const html = renderMarkdownPreview(markdown);
  previewContent.innerHTML = html;
}

function renderMarkdownPreview(markdown) {
  const blocks = [];
  const lines = markdown.split('\n');
  let listItems = [];
  let codeLines = [];
  let inCodeBlock = false;

  const flushList = () => {
    if (listItems.length === 0) return;

    blocks.push(`<ul class="ml-4 list-disc">${listItems.join('')}</ul>`);
    listItems = [];
  };

  const flushCodeBlock = () => {
    if (codeLines.length === 0) return;

    blocks.push(
      `<pre class="bg-base-300 px-3 py-2 rounded text-sm overflow-x-auto"><code>${codeLines.join('\n')}</code></pre>`
    );
    codeLines = [];
  };

  for (const line of lines) {
    if (line.startsWith('```')) {
      flushList();

      if (inCodeBlock) {
        flushCodeBlock();
        inCodeBlock = false;
      } else {
        inCodeBlock = true;
      }

      continue;
    }

    if (inCodeBlock) {
      codeLines.push(escapeHtml(line));
      continue;
    }

    if (line.trim() === '') {
      flushList();
      blocks.push('<br>');
      continue;
    }

    const headingLevel = headingLevelForLine(line);

    if (headingLevel !== null) {
      flushList();
      const content = renderInlineMarkdown(line.slice(headingLevel + 1));
      blocks.push(headingTag(headingLevel, content));
      continue;
    }

    if (line.startsWith('> ')) {
      flushList();
      blocks.push(
        `<blockquote class="border-l-4 border-primary pl-4 italic">${renderInlineMarkdown(line.slice(2))}</blockquote>`
      );
      continue;
    }

    if (line.startsWith('- ') || line.startsWith('* ')) {
      listItems.push(`<li>${renderInlineMarkdown(line.slice(2))}</li>`);
      continue;
    }

    const orderedPrefixLength = orderedListPrefixLength(line);

    if (orderedPrefixLength !== null) {
      listItems.push(`<li>${renderInlineMarkdown(line.slice(orderedPrefixLength))}</li>`);
      continue;
    }

    flushList();
    blocks.push(`<p class="mb-2">${renderInlineMarkdown(line)}</p>`);
  }

  if (inCodeBlock) {
    flushCodeBlock();
  }

  flushList();

  return blocks.join('\n');
}

function headingLevelForLine(line) {
  if (line.startsWith('### ')) return 3;
  if (line.startsWith('## ')) return 2;
  if (line.startsWith('# ')) return 1;
  return null;
}

function headingTag(level, content) {
  if (level === 1) return `<h1 class="text-2xl font-bold mb-3">${content}</h1>`;
  if (level === 2) return `<h2 class="text-xl font-bold mb-2">${content}</h2>`;
  return `<h3 class="text-lg font-bold mb-2">${content}</h3>`;
}

function orderedListPrefixLength(line) {
  let index = 0;

  while (index < line.length && isDigit(line[index])) {
    index += 1;
  }

  if (index === 0) return null;
  if (line[index] !== '.' || line[index + 1] !== ' ') return null;

  return index + 2;
}

function isDigit(character) {
  return character >= '0' && character <= '9';
}

function renderInlineMarkdown(text) {
  let output = '';
  let index = 0;

  while (index < text.length) {
    if (text.startsWith('**', index)) {
      const end = text.indexOf('**', index + 2);

      if (end !== -1) {
        const content = renderInlineMarkdown(text.slice(index + 2, end));
        output += `<strong class="font-bold">${content}</strong>`;
        index = end + 2;
        continue;
      }
    }

    if (text[index] === '*') {
      const end = text.indexOf('*', index + 1);

      if (end !== -1) {
        const content = renderInlineMarkdown(text.slice(index + 1, end));
        output += `<em class="italic">${content}</em>`;
        index = end + 1;
        continue;
      }
    }

    if (text[index] === '`') {
      const end = text.indexOf('`', index + 1);

      if (end !== -1) {
        const content = escapeHtml(text.slice(index + 1, end));
        output += `<code class="bg-base-300 px-1 rounded text-sm">${content}</code>`;
        index = end + 1;
        continue;
      }
    }

    if (text[index] === '[') {
      const closeLabel = text.indexOf(']', index + 1);

      if (closeLabel !== -1 && text[closeLabel + 1] === '(') {
        const closeUrl = text.indexOf(')', closeLabel + 2);

        if (closeUrl !== -1) {
          const label = text.slice(index + 1, closeLabel);
          const href = text.slice(closeLabel + 2, closeUrl).trim();

          if (isSafeHref(href)) {
            output += `<a href="${escapeHtml(href)}" class="text-primary underline" target="_blank" rel="noopener">${renderInlineMarkdown(label)}</a>`;
          } else {
            output += escapeHtml(text.slice(index, closeUrl + 1));
          }

          index = closeUrl + 1;
          continue;
        }
      }
    }

    output += escapeHtml(text[index]);
    index += 1;
  }

  return output;
}

function isSafeHref(href) {
  return (
    href.startsWith('http://') ||
    href.startsWith('https://') ||
    href.startsWith('mailto:') ||
    href.startsWith('/')
  );
}

function escapeHtml(text) {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}
