/**
 * Keyboard UX for the Paige search page.
 *
 * - "/" or Cmd/Ctrl+K focuses the search input from anywhere on the page.
 * - ArrowDown/ArrowUp move between the input and suggestion items.
 * - Escape closes suggestions and returns focus to the input.
 *
 * Client-side only: no per-keystroke events are sent to the server
 * (paige_live_test.exs asserts the input has no keyup bindings).
 */
export const PaigeSearch = {
  mounted() {
    this.onWindowKeydown = (event) => {
      const input = this.input()
      if (!input) return

      const commandK = (event.metaKey || event.ctrlKey) && event.key?.toLowerCase() === "k"
      const slash = event.key === "/" || event.code === "Slash"

      if (commandK || (slash && !this.isEditableElement(event.target))) {
        event.preventDefault()
        event.stopPropagation()
        input.focus()
        input.select()
      }
    }

    this.onKeydown = (event) => {
      if (event.key === "Escape") {
        this.pushEvent("clear_suggestions", {})
        this.input()?.focus()
        return
      }

      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return

      const items = Array.from(this.el.querySelectorAll("[data-suggestion-item]"))
      if (items.length === 0) return

      event.preventDefault()
      const index = items.indexOf(document.activeElement)

      if (event.key === "ArrowDown") {
        const next = index < 0 ? items[0] : items[Math.min(index + 1, items.length - 1)]
        next.focus()
      } else if (index === 0) {
        this.input()?.focus()
      } else if (index > 0) {
        items[index - 1].focus()
      }
    }

    window.addEventListener("keydown", this.onWindowKeydown, { capture: true })
    this.el.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onWindowKeydown, { capture: true })
    this.el.removeEventListener("keydown", this.onKeydown)
  },

  input() {
    return this.el.querySelector("#global-search-input")
  },

  isEditableElement(element) {
    if (!(element instanceof HTMLElement)) return false

    return Boolean(
      element.closest("input, textarea, select, button, a, [contenteditable='true']")
    )
  },
}
