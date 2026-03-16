// Markdown helper functions

export function insertMarkdownFormat(format, textarea) {
  const start = textarea.selectionStart
  const end = textarea.selectionEnd
  const selectedText = textarea.value.substring(start, end)
  let replacement = ''

  switch (format) {
    case 'bold':
      replacement = `**${selectedText || 'bold text'}**`
      break
    case 'italic':
      replacement = `*${selectedText || 'italic text'}*`
      break
    case 'underline':
      replacement = `<u>${selectedText || 'underlined text'}</u>`
      break
    case 'heading':
      replacement = `# ${selectedText || 'Heading'}`
      break
    case 'link':
      const url = selectedText.startsWith('http') ? selectedText : 'https://example.com'
      const linkText = selectedText.startsWith('http') ? 'link text' : selectedText || 'link text'
      replacement = `[${linkText}](${url})`
      break
    case 'list':
      replacement = `- ${selectedText || 'list item'}`
      break
    case 'quote':
      replacement = `> ${selectedText || 'quoted text'}`
      break
  }

  textarea.value = textarea.value.substring(0, start) + replacement + textarea.value.substring(end)
  textarea.focus()

  // Set cursor position
  const newPos = start + replacement.length
  textarea.setSelectionRange(newPos, newPos)
}

export function toggleMarkdownPreview(textarea, targetId) {
  let previewPanelId = 'preview-panel'
  let previewContentId = 'preview-content'

  // Use reply preview for reply/forward mode
  if (targetId === 'new-message-area') {
    previewPanelId = 'reply-preview-panel'
    previewContentId = 'reply-preview-content'
  }

  const previewPanel = document.getElementById(previewPanelId)
  const previewContent = document.getElementById(previewContentId)

  if (!previewPanel || !previewContent) return

  if (previewPanel.classList.contains('hidden')) {
    // Show preview
    const markdown = textarea.value
    const html = markdownToHtml(markdown)
    previewContent.innerHTML = html
    previewPanel.classList.remove('hidden')
  } else {
    // Hide preview
    previewPanel.classList.add('hidden')
  }
}

export function sanitizeMarkdownHref(href) {
  if (typeof href !== 'string') return null

  const trimmedHref = href.trim()
  if (trimmedHref === '') return null

  if (trimmedHref.startsWith('#')) {
    return trimmedHref
  }

  if (trimmedHref.startsWith('/')) {
    return trimmedHref.startsWith('//') ? null : trimmedHref
  }

  // Normalize away ASCII whitespace/control characters for scheme checks.
  const normalizedHref = trimmedHref.replace(/[\u0000-\u001F\u007F\s]+/g, '')
  const schemeMatch = normalizedHref.match(/^([a-zA-Z][a-zA-Z\d+.-]*):/)

  if (!schemeMatch) return null

  const scheme = schemeMatch[1].toLowerCase()
  if (scheme === 'http' || scheme === 'https' || scheme === 'mailto') {
    return trimmedHref
  }

  return null
}

export function markdownToHtml(markdown) {
  if (!markdown) return ''

  const lines = markdown.split('\n')
  const htmlLines = []
  let inCodeBlock = false
  let codeBlockLines = []

  for (const line of lines) {
    if (line.startsWith('```')) {
      if (inCodeBlock) {
        htmlLines.push(`<pre><code>${codeBlockLines.join('\n')}</code></pre>`)
        codeBlockLines = []
        inCodeBlock = false
      } else {
        inCodeBlock = true
      }
      continue
    }

    if (inCodeBlock) {
      codeBlockLines.push(escapeHtml(line))
      continue
    }

    let processedLine = ''

    if (line.startsWith('### ')) {
      processedLine = `<h3>${escapeHtml(line.substring(4))}</h3>`
    } else if (line.startsWith('## ')) {
      processedLine = `<h2>${escapeHtml(line.substring(3))}</h2>`
    } else if (line.startsWith('# ')) {
      processedLine = `<h1>${escapeHtml(line.substring(2))}</h1>`
    } else if (line.startsWith('> ')) {
      processedLine = `<blockquote class="border-l-4 border-primary pl-4 italic">${processMarkdownInline(line.substring(2))}</blockquote>`
    } else if (line.startsWith('- ') || line.startsWith('* ')) {
      processedLine = `<li>${processMarkdownInline(line.substring(2))}</li>`
    } else if (/^\d+\. /.test(line)) {
      processedLine = `<li>${processMarkdownInline(line.replace(/^\d+\. /, ''))}</li>`
    } else if (line.trim() !== '') {
      processedLine = `<p>${processMarkdownInline(line)}</p>`
    } else {
      processedLine = '<br>'
    }

    htmlLines.push(processedLine)
  }

  if (inCodeBlock && codeBlockLines.length > 0) {
    htmlLines.push(`<pre><code>${codeBlockLines.join('\n')}</code></pre>`)
  }

  return htmlLines.join('\n').replace(/(<li>.*<\/li>\n?)+/g, (match) => {
    return `<ul class="list-disc list-inside">${match}</ul>`
  })
}

function processMarkdownInline(text) {
  return escapeHtml(text)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\[([^\]]+)\]\(([^\)]+)\)/g, (match, label, href) => {
      const safeHref = sanitizeMarkdownHref(href)

      if (!safeHref) {
        return match
      }

      return `<a href="${safeHref}" class="text-primary underline" target="_blank" rel="noopener noreferrer">${label}</a>`
    })
}

function escapeHtml(text) {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}
