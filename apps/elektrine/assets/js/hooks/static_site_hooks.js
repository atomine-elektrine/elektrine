// Static site hosting hooks

// DragDrop hook for visual feedback on drag and drop uploads
export const DragDrop = {
  mounted() {
    this.el.addEventListener("dragenter", (e) => {
      e.preventDefault()
      this.pushEvent("dragover", {})
    })

    this.el.addEventListener("dragover", (e) => {
      e.preventDefault()
    })

    this.el.addEventListener("dragleave", (e) => {
      // Only trigger if leaving the drop zone entirely
      if (!this.el.contains(e.relatedTarget)) {
        this.pushEvent("dragleave", {})
      }
    })

    this.el.addEventListener("drop", (e) => {
      this.pushEvent("drop", {})
    })
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
