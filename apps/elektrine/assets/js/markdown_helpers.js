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

export function markdownToHtml(markdown) {
  return markdown
    // Headers
    .replace(/^### (.*$)/gm, '<h3>$1</h3>')
    .replace(/^## (.*$)/gm, '<h2>$1</h2>')
    .replace(/^# (.*$)/gm, '<h1>$1</h1>')
    // Bold
    .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
    // Italic
    .replace(/\*(.*?)\*/g, '<em>$1</em>')
    // Links
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" class="text-primary underline">$1</a>')
    // Lists
    .replace(/^- (.*$)/gm, '<li>$1</li>')
    .replace(/(<li>.*<\/li>)/s, '<ul class="list-disc list-inside">$1</ul>')
    // Quotes
    .replace(/^> (.*$)/gm, '<blockquote class="border-l-4 border-primary pl-4 italic">$1</blockquote>')
    // Line breaks
    .replace(/\n/g, '<br>')
}