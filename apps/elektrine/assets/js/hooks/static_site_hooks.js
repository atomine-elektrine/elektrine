// Static site hosting hooks

// DragDrop hook for visual feedback on drag and drop uploads
export const DragDrop = {
  mounted() {
    this.dragDepth = 0

    this.onDragEnter = (e) => {
      e.preventDefault()
      this.dragDepth += 1
      this.pushEvent("dragover", {})
    }

    this.onDragOver = (e) => {
      e.preventDefault()

      if (e.dataTransfer) {
        e.dataTransfer.dropEffect = "copy"
      }
    }

    this.onDragLeave = (e) => {
      e.preventDefault()
      this.dragDepth = Math.max(this.dragDepth - 1, 0)

      if (this.dragDepth === 0) {
        this.pushEvent("dragleave", {})
      }
    }

    this.onDrop = (e) => {
      e.preventDefault()
      this.dragDepth = 0
      this.pushEvent("drop", {})
    }

    this.el.addEventListener("dragenter", this.onDragEnter)
    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("dragleave", this.onDragLeave)
    this.el.addEventListener("drop", this.onDrop)
  },

  destroyed() {
    this.el.removeEventListener("dragenter", this.onDragEnter)
    this.el.removeEventListener("dragover", this.onDragOver)
    this.el.removeEventListener("dragleave", this.onDragLeave)
    this.el.removeEventListener("drop", this.onDrop)
  }
}

// CodeEditor hook for better textarea handling
export const CodeEditor = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      // Handle Tab key to insert spaces instead of changing focus
      if (e.key === "Tab") {
        e.preventDefault()
        const start = this.el.selectionStart
        const end = this.el.selectionEnd
        const value = this.el.value

        // Insert 2 spaces
        this.el.value = value.substring(0, start) + "  " + value.substring(end)
        this.el.selectionStart = this.el.selectionEnd = start + 2
      }

      // Ctrl/Cmd + S to save
      if ((e.ctrlKey || e.metaKey) && e.key === "s") {
        e.preventDefault()
        // Submit the form
        this.el.closest("form").requestSubmit()
      }
    })

    // Auto-resize textarea to fit content (optional)
    this.autoResize()
    this.el.addEventListener("input", () => this.autoResize())
  },

  autoResize() {
    // Keep minimum height but grow with content
    this.el.style.height = "auto"
    const minHeight = 400
    this.el.style.height = Math.max(minHeight, this.el.scrollHeight) + "px"
  }
}
