export const ProfileLinkReorder = {
  mounted() {
    this.dragging = null

    this.onDragStart = (event) => {
      const row = event.target.closest("[data-profile-link-id]")
      if (!row) return

      this.dragging = row
      row.classList.add("opacity-60")

      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = "move"
        event.dataTransfer.setData("text/plain", row.dataset.profileLinkId || "")
      }
    }

    this.onDragOver = (event) => {
      if (!this.dragging) return

      const row = event.target.closest("[data-profile-link-id]")
      if (!row || row === this.dragging || row.parentElement !== this.el) return

      event.preventDefault()
      const rect = row.getBoundingClientRect()
      const placeAfter = event.clientY > rect.top + rect.height / 2
      this.el.insertBefore(this.dragging, placeAfter ? row.nextSibling : row)
    }

    this.onDrop = (event) => {
      if (!this.dragging) return
      event.preventDefault()
      this.pushOrder()
    }

    this.onDragEnd = () => {
      if (this.dragging) {
        this.dragging.classList.remove("opacity-60")
      }

      this.dragging = null
    }

    this.el.addEventListener("dragstart", this.onDragStart)
    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("drop", this.onDrop)
    this.el.addEventListener("dragend", this.onDragEnd)
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this.onDragStart)
    this.el.removeEventListener("dragover", this.onDragOver)
    this.el.removeEventListener("drop", this.onDrop)
    this.el.removeEventListener("dragend", this.onDragEnd)
  },

  pushOrder() {
    const ids = Array.from(this.el.querySelectorAll("[data-profile-link-id]"))
      .map((row) => row.dataset.profileLinkId)
      .filter(Boolean)

    this.pushEvent("reorder_links", { ids })
  }
}
