// Markdown editor related hooks

export const MarkdownEditor = {
  mounted() {
    // Regular compose mode only
    this.textarea = this.el
    this.setupPreview()
  },

  setupPreview() {
    // Auto-update preview when typing
    this.el.addEventListener('input', () => {
      const previewPanel = document.getElementById('preview-panel')
      const previewContent = document.getElementById('preview-content')

      if (previewPanel && !previewPanel.classList.contains('hidden')) {
        this.updatePreviewContent(this.el.value, previewContent)
      }
    })

    // Also update preview when mode changes to preview or split
    document.addEventListener('click', (e) => {
      const modeBtn = e.target.closest('[data-editor-mode]')
      if (!modeBtn) return

      const mode = modeBtn.dataset.editorMode
      if (mode === 'preview' || mode === 'split') {
        setTimeout(() => {
          const previewContent = document.getElementById('preview-content')
          if (previewContent) {
            this.updatePreviewContent(this.el.value, previewContent)
          }
        }, 0)
      }
    })
  },

  updatePreviewContent(markdown, previewElement) {
    if (!previewElement) return

    if (!markdown || markdown.trim() === '') {
      previewElement.innerHTML = '<p style="color: hsl(var(--bc) / 0.5);">Start typing to see preview...</p>'
      return
    }

    const html = this.markdownToHtml(markdown)
    previewElement.innerHTML = html
  },

  setupReplyToolbars() {
    // Setup toolbar for reply/forward mode (with data-target attributes)
    const replyToolbar = document.querySelector('[data-target="new-message-area"]')?.closest('.flex')
    if (!replyToolbar) return

    replyToolbar.addEventListener('click', (e) => {
      const button = e.target.closest('[data-format], [data-action]')
      if (!button) return

      e.preventDefault()

      if (button.dataset.format) {
        this.insertFormatInTarget(button.dataset.format, this.el)
      } else if (button.dataset.action === 'preview') {
        this.toggleReplyPreview(this.el)
      }
    })
  },

  setupReplyPreview() {
    // Auto-update preview if it's visible for reply mode
    this.el.addEventListener('input', () => {
      const previewPanel = document.getElementById('reply-preview-panel')
      const previewContent = document.getElementById('reply-preview-content')
      if (previewPanel && !previewPanel.classList.contains('hidden')) {
        const html = this.markdownToHtml(this.el.value)
        previewContent.innerHTML = html
      }
    })
  },

  insertFormatInTarget(format, textarea) {
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
      case 'code':
        replacement = `\`${selectedText || 'code'}\``
        break
      case 'h1':
      case 'heading':
        replacement = `# ${selectedText || 'Heading 1'}`
        break
      case 'h2':
        replacement = `## ${selectedText || 'Heading 2'}`
        break
      case 'h3':
        replacement = `### ${selectedText || 'Heading 3'}`
        break
      case 'link':
        const url = selectedText.startsWith('http') ? selectedText : 'https://example.com'
        const linkText = selectedText.startsWith('http') ? 'link text' : selectedText || 'link text'
        replacement = `[${linkText}](${url})`
        break
      case 'list':
      case 'list-bullet':
        replacement = `- ${selectedText || 'list item'}`
        break
      case 'list-number':
        replacement = `1. ${selectedText || 'list item'}`
        break
      case 'quote':
        replacement = `> ${selectedText || 'quoted text'}`
        break
      case 'code-block':
        replacement = `\`\`\`\n${selectedText || 'code here'}\n\`\`\``
        break
    }

    textarea.value = textarea.value.substring(0, start) + replacement + textarea.value.substring(end)
    textarea.focus()

    // Set cursor position
    const newPos = start + replacement.length
    textarea.setSelectionRange(newPos, newPos)
  },

  toggleReplyPreview(textarea) {
    const previewPanel = document.getElementById('reply-preview-panel')
    const previewContent = document.getElementById('reply-preview-content')

    if (!previewPanel || !previewContent) return

    if (previewPanel.classList.contains('hidden')) {
      // Show preview
      const markdown = textarea.value
      const html = this.markdownToHtml(markdown)
      previewContent.innerHTML = html
      previewPanel.classList.remove('hidden')
    } else {
      // Hide preview
      previewPanel.classList.add('hidden')
    }
  },

  insertFormat(format, targetSelector = null) {
    const textarea = targetSelector ? document.querySelector(targetSelector) : this.el
    if (!textarea) return

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
      case 'code':
        replacement = `\`${selectedText || 'code'}\``
        break
      case 'h1':
      case 'heading':
        replacement = `# ${selectedText || 'Heading 1'}`
        break
      case 'h2':
        replacement = `## ${selectedText || 'Heading 2'}`
        break
      case 'h3':
        replacement = `### ${selectedText || 'Heading 3'}`
        break
      case 'link':
        const url = selectedText.startsWith('http') ? selectedText : 'https://example.com'
        const linkText = selectedText.startsWith('http') ? 'link text' : selectedText || 'link text'
        replacement = `[${linkText}](${url})`
        break
      case 'list':
      case 'list-bullet':
        replacement = `- ${selectedText || 'list item'}`
        break
      case 'list-number':
        replacement = `1. ${selectedText || 'list item'}`
        break
      case 'quote':
        replacement = `> ${selectedText || 'quoted text'}`
        break
      case 'code-block':
        replacement = `\`\`\`\n${selectedText || 'code here'}\n\`\`\``
        break
    }

    textarea.value = textarea.value.substring(0, start) + replacement + textarea.value.substring(end)
    textarea.focus()

    // Set cursor position
    const newPos = start + replacement.length
    textarea.setSelectionRange(newPos, newPos)
  },

  togglePreview(targetSelector = null, previewPanelId = 'preview-panel', previewContentId = 'preview-content') {
    const textarea = targetSelector ? document.querySelector(targetSelector) : this.el
    const previewPanel = document.getElementById(previewPanelId)
    const previewContent = document.getElementById(previewContentId)

    if (!textarea || !previewPanel || !previewContent) return

    if (previewPanel.classList.contains('hidden')) {
      // Show preview
      const markdown = textarea.value
      const html = this.markdownToHtml(markdown)
      previewContent.innerHTML = html
      previewPanel.classList.remove('hidden')
    } else {
      // Hide preview
      previewPanel.classList.add('hidden')
    }
  },

  markdownToHtml(markdown) {
    // Process markdown line by line for better handling
    const lines = markdown.split('\n')
    const htmlLines = []
    let inCodeBlock = false
    let codeBlockLines = []

    for (let line of lines) {
      // Handle code blocks
      if (line.startsWith('```')) {
        if (inCodeBlock) {
          htmlLines.push(`<pre class="bg-base-200 p-3 rounded"><code>${codeBlockLines.join('\n')}</code></pre>`)
          codeBlockLines = []
          inCodeBlock = false
        } else {
          inCodeBlock = true
        }
        continue
      }

      if (inCodeBlock) {
        codeBlockLines.push(this.escapeHtml(line))
        continue
      }

      // Process individual line
      let processedLine = line

      // Headers (must be at line start)
      if (line.startsWith('### ')) {
        processedLine = `<h3 class="text-lg font-semibold">${this.escapeHtml(line.substring(4))}</h3>`
      } else if (line.startsWith('## ')) {
        processedLine = `<h2 class="text-xl font-semibold">${this.escapeHtml(line.substring(3))}</h2>`
      } else if (line.startsWith('# ')) {
        processedLine = `<h1 class="text-2xl font-bold">${this.escapeHtml(line.substring(2))}</h1>`
      }
      // Blockquotes
      else if (line.startsWith('> ')) {
        processedLine = `<blockquote class="border-l-4 border-primary pl-4 italic">${this.processMarkdownInline(line.substring(2))}</blockquote>`
      }
      // Unordered lists
      else if (line.startsWith('- ') || line.startsWith('* ')) {
        processedLine = `<li>${this.processMarkdownInline(line.substring(2))}</li>`
      }
      // Ordered lists
      else if (/^\d+\. /.test(line)) {
        processedLine = `<li>${this.processMarkdownInline(line.replace(/^\d+\. /, ''))}</li>`
      }
      // Regular paragraph
      else if (line.trim() !== '') {
        processedLine = `<p>${this.processMarkdownInline(line)}</p>`
      } else {
        processedLine = ''
      }

      if (processedLine) {
        htmlLines.push(processedLine)
      }
    }

    // Handle any unclosed code block
    if (inCodeBlock && codeBlockLines.length > 0) {
      htmlLines.push(`<pre class="bg-base-200 p-3 rounded"><code>${codeBlockLines.join('\n')}</code></pre>`)
    }

    // Wrap consecutive list items in ul tags
    let finalHtml = htmlLines.join('\n')

    // Group consecutive li elements into ul
    finalHtml = finalHtml.replace(/(<li>[\s\S]*?<\/li>\n?)+/g, (match) => {
      return `<ul class="list-disc list-inside ml-4">${match}</ul>`
    })

    return finalHtml
  },

  processMarkdownInline(text) {
    return this.escapeHtml(text)
      // Bold (must come before italic)
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      // Italic
      .replace(/\*([^*]+)\*/g, '<em>$1</em>')
      // Inline code
      .replace(/`([^`]+)`/g, '<code class="bg-base-200 px-1 rounded">$1</code>')
      // Links
      .replace(/\[([^\]]+)\]\(([^\)]+)\)/g, '<a href="$2" target="_blank" class="text-primary underline">$1</a>')
  },

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}

export const ReplyMarkdownEditor = {
  mounted() {
    // Focus on the textarea when mounted (FocusOnMount functionality)
    this.el.focus()

    // Add event listener to combine new message with original when form is submitted
    const form = this.el.closest('form')
    if (form) {
      form.addEventListener('submit', (e) => {
        const newMessage = this.el.value.trim()
        const hiddenBodyField = form.querySelector('#full-message-body')
        const originalMessage = hiddenBodyField.value

        // Combine new message with original
        if (newMessage) {
          hiddenBodyField.value = newMessage + originalMessage
        } else {
          // If no new message, just use original (for forwarding without adding text)
          hiddenBodyField.value = originalMessage
        }
      })
    }

    // Setup markdown toolbar functionality
    this.setupReplyToolbars()
    this.setupReplyPreview()
    this.setupReplyTabs()
  },

  destroyed() {
    // Clean up event listeners
    const toolbar = document.getElementById('reply-formatting-toolbar')
    if (toolbar && this.toolbarClickHandler) {
      toolbar.removeEventListener('click', this.toolbarClickHandler)
    }

    if (this.tabClickHandler) {
      document.removeEventListener('click', this.tabClickHandler)
    }

    if (this.inputHandler) {
      this.el.removeEventListener('input', this.inputHandler)
    }
  },

  setupReplyTabs() {
    // Handle tab switching for reply editor
    // Remove existing listener if present
    if (this.tabClickHandler) {
      document.removeEventListener('click', this.tabClickHandler)
    }

    this.tabClickHandler = (e) => {
      const tab = e.target.closest('[data-reply-editor-tab]')
      if (!tab) return

      e.preventDefault()
      e.stopPropagation()
      const mode = tab.dataset.replyEditorTab

      // Update tab active states
      document.querySelectorAll('[data-reply-editor-tab]').forEach(t => {
        t.classList.remove('tab-active')
      })
      tab.classList.add('tab-active')

      const writeDiv = document.getElementById('reply-editor-write')
      const previewDiv = document.getElementById('reply-editor-preview')
      const container = document.getElementById('reply-editor-container')

      switch(mode) {
        case 'write':
          writeDiv.classList.remove('hidden')
          previewDiv.classList.add('hidden')
          container.classList.remove('grid', 'grid-cols-2', 'gap-2')
          break
        case 'preview':
          writeDiv.classList.add('hidden')
          previewDiv.classList.remove('hidden')
          container.classList.remove('grid', 'grid-cols-2', 'gap-2')
          this.updateReplyPreview()
          break
        case 'split':
          writeDiv.classList.remove('hidden')
          previewDiv.classList.remove('hidden')
          container.classList.add('grid', 'grid-cols-2', 'gap-2')
          this.updateReplyPreview()
          break
      }
    }

    document.addEventListener('click', this.tabClickHandler)
  },

  setupReplyToolbars() {
    // Setup toolbar for reply/forward mode
    const toolbar = document.getElementById('reply-formatting-toolbar')
    if (!toolbar) {
      return
    }

    // Remove existing listener if present to prevent double-firing
    if (this.toolbarClickHandler) {
      toolbar.removeEventListener('click', this.toolbarClickHandler)
    }

    // Create and store the handler
    this.toolbarClickHandler = (e) => {
      const button = e.target.closest('[data-markdown-format]')
      if (!button) return

      e.preventDefault()
      e.stopPropagation()  // Prevent event from bubbling to prevent double-firing

      const format = button.dataset.markdownFormat
      const target = button.dataset.target
      const textarea = target ? document.getElementById(target) : this.el

      if (textarea) {
        this.insertFormatInTarget(format, textarea)
        // Update preview if visible
        this.updateReplyPreview()
      }
    }

    toolbar.addEventListener('click', this.toolbarClickHandler)
  },

  setupReplyPreview() {
    // Auto-update preview if it's visible for reply mode
    // Remove existing listener if present
    if (this.inputHandler) {
      this.el.removeEventListener('input', this.inputHandler)
    }

    this.inputHandler = () => {
      this.updateReplyPreview()
    }

    this.el.addEventListener('input', this.inputHandler)
  },

  updateReplyPreview() {
    const previewContent = document.getElementById('reply-preview-content')
    const previewDiv = document.getElementById('reply-editor-preview')

    if (previewContent && previewDiv && !previewDiv.classList.contains('hidden')) {
      const html = this.markdownToHtml(this.el.value)
      previewContent.innerHTML = html || '<p class="text-base-content/50">Nothing to preview yet...</p>'
    }
  },

  insertFormatInTarget(format, textarea) {
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
      case 'code':
        replacement = `\`${selectedText || 'code'}\``
        break
      case 'h1':
      case 'heading':
        replacement = `# ${selectedText || 'Heading 1'}`
        break
      case 'h2':
        replacement = `## ${selectedText || 'Heading 2'}`
        break
      case 'h3':
        replacement = `### ${selectedText || 'Heading 3'}`
        break
      case 'link':
        const url = selectedText.startsWith('http') ? selectedText : 'https://example.com'
        const linkText = selectedText.startsWith('http') ? 'link text' : selectedText || 'link text'
        replacement = `[${linkText}](${url})`
        break
      case 'list':
      case 'list-bullet':
        replacement = `- ${selectedText || 'list item'}`
        break
      case 'list-number':
        replacement = `1. ${selectedText || 'list item'}`
        break
      case 'quote':
        replacement = `> ${selectedText || 'quoted text'}`
        break
      case 'code-block':
        replacement = `\`\`\`\n${selectedText || 'code here'}\n\`\`\``
        break
    }

    textarea.value = textarea.value.substring(0, start) + replacement + textarea.value.substring(end)
    textarea.focus()

    // Set cursor position
    const newPos = start + replacement.length
    textarea.setSelectionRange(newPos, newPos)
  },

  toggleReplyPreview(textarea) {
    const previewPanel = document.getElementById('reply-preview-panel')
    const previewContent = document.getElementById('reply-preview-content')

    if (!previewPanel || !previewContent) return

    if (previewPanel.classList.contains('hidden')) {
      // Show preview
      const markdown = textarea.value
      const html = this.markdownToHtml(markdown)
      previewContent.innerHTML = html
      previewPanel.classList.remove('hidden')
    } else {
      // Hide preview
      previewPanel.classList.add('hidden')
    }
  },

  markdownToHtml(markdown) {
    if (!markdown) return ''

    // Process markdown line by line for better handling
    const lines = markdown.split('\n')
    const htmlLines = []
    let inCodeBlock = false
    let codeBlockLines = []

    for (let line of lines) {
      // Handle code blocks
      if (line.startsWith('```')) {
        if (inCodeBlock) {
          htmlLines.push(`<pre class="bg-base-200 p-3 rounded overflow-x-auto"><code>${codeBlockLines.join('\n')}</code></pre>`)
          codeBlockLines = []
          inCodeBlock = false
        } else {
          inCodeBlock = true
        }
        continue
      }

      if (inCodeBlock) {
        codeBlockLines.push(this.escapeHtml(line))
        continue
      }

      // Process individual line
      let processedLine = line

      // Headers (must be at line start)
      if (line.startsWith('### ')) {
        processedLine = `<h3 class="text-lg font-semibold">${this.escapeHtml(line.substring(4))}</h3>`
      } else if (line.startsWith('## ')) {
        processedLine = `<h2 class="text-xl font-semibold">${this.escapeHtml(line.substring(3))}</h2>`
      } else if (line.startsWith('# ')) {
        processedLine = `<h1 class="text-2xl font-bold">${this.escapeHtml(line.substring(2))}</h1>`
      }
      // Blockquotes
      else if (line.startsWith('> ')) {
        processedLine = `<blockquote class="border-l-4 border-primary pl-4 italic">${this.processMarkdownInline(line.substring(2))}</blockquote>`
      }
      // Unordered lists
      else if (line.startsWith('- ') || line.startsWith('* ')) {
        processedLine = `<li>${this.processMarkdownInline(line.substring(2))}</li>`
      }
      // Ordered lists
      else if (/^\d+\. /.test(line)) {
        processedLine = `<li>${this.processMarkdownInline(line.replace(/^\d+\. /, ''))}</li>`
      }
      // Regular paragraph
      else if (line.trim() !== '') {
        processedLine = `<p>${this.processMarkdownInline(line)}</p>`
      } else {
        processedLine = ''
      }

      if (processedLine) {
        htmlLines.push(processedLine)
      }
    }

    // Handle any unclosed code block
    if (inCodeBlock && codeBlockLines.length > 0) {
      htmlLines.push(`<pre class="bg-base-200 p-3 rounded overflow-x-auto"><code>${codeBlockLines.join('\n')}</code></pre>`)
    }

    // Wrap consecutive list items in ul/ol tags
    let finalHtml = htmlLines.join('\n')
    finalHtml = finalHtml.replace(/(<li>[\s\S]*?<\/li>\n?)+/g, (match) => {
      return `<ul class="list-disc list-inside ml-4">${match}</ul>`
    })

    return finalHtml
  },

  processMarkdownInline(text) {
    return this.escapeHtml(text)
      // Bold (must come before italic)
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      // Italic
      .replace(/\*([^*]+)\*/g, '<em>$1</em>')
      // Inline code
      .replace(/`([^`]+)`/g, '<code class="bg-base-200 px-1 rounded">$1</code>')
      // Links
      .replace(/\[([^\]]+)\]\(([^\)]+)\)/g, '<a href="$2" target="_blank" class="text-primary underline">$1</a>')
  },

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}