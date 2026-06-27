export const FileExplorer = {
  mounted() {
    this.searchInput = this.el.querySelector('#file-explorer-search')
    this.interactiveSelector = 'a, button, input, select, textarea, summary, label, [data-row-ignore]'
    this.treeLayout = this.el.querySelector('[data-tree-layout]')
    this.treePane = this.el.querySelector('[data-tree-pane]')
    this.treeResizer = this.el.querySelector('[data-tree-resizer]')
    this.activeRowIndex = -1
    this.anchorRowIndex = null
    this.draggingTokens = null
    this.draggingRow = null
    this.lastDropTarget = null

    this.applyTreeWidth = (width) => {
      if (!this.treeLayout) return
      const clamped = Math.max(224, Math.min(width, 480))
      this.treeLayout.style.setProperty('--files-tree-width', `${clamped}px`)
      window.localStorage?.setItem('files-tree-width', String(clamped))
    }

    this.restoreTreeWidth = () => {
      const savedWidth = window.localStorage?.getItem('files-tree-width')
      if (!savedWidth) return

      const parsed = Number(savedWidth)
      if (Number.isFinite(parsed)) this.applyTreeWidth(parsed)
    }

    this.refreshRows = () => {
      this.rows = Array.from(this.el.querySelectorAll('[data-row-token]'))

      this.rows.forEach((row, index) => {
        row.dataset.rowIndex = String(index)
        row.tabIndex = index === this.activeRowIndex ? 0 : -1
      })

      if (this.rows.length === 0) {
        this.activeRowIndex = -1
        this.anchorRowIndex = null
      } else if (this.activeRowIndex < 0 || this.activeRowIndex >= this.rows.length) {
        this.setActiveRow(0, false)
      }
    }

    this.setActiveRow = (index, focus = true) => {
      if (!this.rows || this.rows.length === 0) return

      const boundedIndex = Math.max(0, Math.min(index, this.rows.length - 1))
      this.activeRowIndex = boundedIndex

      this.rows.forEach((row, rowIndex) => {
        row.tabIndex = rowIndex === boundedIndex ? 0 : -1
      })

      if (focus) {
        this.rows[boundedIndex].focus()
      }
    }

    this.setSelection = (tokens) => {
      this.pushEvent('set_selection', { tokens })
    }

    this.getSelectedTokens = () => {
      return this.rows
        .filter(row => row.dataset.rowSelected === 'true')
        .map(row => row.dataset.rowToken)
    }

    this.openRow = (row) => {
      if (!row || !row.dataset.rowOpenEvent) return

      const payload = {}
      if (row.dataset.rowOpenPath) payload.path = row.dataset.rowOpenPath
      if (row.dataset.rowOpenId) payload.id = row.dataset.rowOpenId
      this.pushEvent(row.dataset.rowOpenEvent, payload)
    }

    this.selectRangeTo = (targetIndex) => {
      if (!this.rows || this.rows.length === 0) return

      const anchor = this.anchorRowIndex == null ? this.activeRowIndex : this.anchorRowIndex
      const start = Math.min(anchor, targetIndex)
      const end = Math.max(anchor, targetIndex)
      const tokens = this.rows.slice(start, end + 1).map(row => row.dataset.rowToken)
      this.setSelection(tokens)
    }

    this.onClick = (event) => {
      const row = event.target.closest('[data-row-token]')
      if (!row || row.contains(event.target.closest(this.interactiveSelector))) return

      const rowIndex = Number(row.dataset.rowIndex || 0)
      this.setActiveRow(rowIndex)

      if (event.shiftKey) {
        this.selectRangeTo(rowIndex)
      } else if (event.metaKey || event.ctrlKey) {
        this.anchorRowIndex = rowIndex
        this.pushEvent('toggle_select', { token: row.dataset.rowToken })
      } else {
        this.anchorRowIndex = rowIndex
        this.setSelection([row.dataset.rowToken])
      }
    }

    this.onDoubleClick = (event) => {
      const row = event.target.closest('[data-row-token]')
      if (!row || row.contains(event.target.closest(this.interactiveSelector))) return

      this.openRow(row)
    }

    this.clearDropTarget = () => {
      if (!this.lastDropTarget) return
      this.lastDropTarget.classList.remove('bg-primary/15', 'ring-1', 'ring-primary/30')
      this.lastDropTarget = null
    }

    this.onDragStart = (event) => {
      const row = event.target.closest('[draggable="true"][data-row-token]')
      if (!row || event.target.closest(this.interactiveSelector)) {
        event.preventDefault()
        return
      }

      const rowToken = row.dataset.rowToken
      const selectedTokens = row.dataset.rowSelected === 'true' ? this.getSelectedTokens() : []
      this.draggingTokens = selectedTokens.length > 0 ? selectedTokens : [rowToken]
      this.draggingRow = row
      row.classList.add('opacity-60')

      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = 'move'
        event.dataTransfer.setData('text/plain', this.draggingTokens.join(','))
      }
    }

    this.onDragEnd = () => {
      if (this.draggingRow) this.draggingRow.classList.remove('opacity-60')
      this.draggingTokens = null
      this.draggingRow = null
      this.clearDropTarget()
    }

    this.onDragOver = (event) => {
      if (!this.draggingTokens || this.draggingTokens.length === 0) return
      const target = event.target.closest('[data-tree-folder-drop-path]')
      if (!target) return

      event.preventDefault()
      if (this.lastDropTarget && this.lastDropTarget !== target) this.clearDropTarget()
      this.lastDropTarget = target
      target.classList.add('bg-primary/15', 'ring-1', 'ring-primary/30')
    }

    this.onDragLeave = (event) => {
      const target = event.target.closest('[data-tree-folder-drop-path]')
      if (!target || target !== this.lastDropTarget) return

      const related = event.relatedTarget
      if (related instanceof HTMLElement && target.contains(related)) return
      this.clearDropTarget()
    }

    this.onDrop = (event) => {
      if (!this.draggingTokens || this.draggingTokens.length === 0) return
      const target = event.target.closest('[data-tree-folder-drop-path]')
      if (!target) return

      event.preventDefault()
      const folderPath = target.dataset.treeFolderDropPath || ''
      this.pushEvent('drag_move_items', { tokens: this.draggingTokens, folder: folderPath })
      this.onDragEnd()
    }

    this.onResizeStart = (event) => {
      if (!this.treeLayout || !this.treeResizer) return

      event.preventDefault()
      const startX = event.clientX
      const startWidth = this.treePane?.getBoundingClientRect().width || 288

      const onPointerMove = moveEvent => {
        const nextWidth = startWidth + (moveEvent.clientX - startX)
        this.applyTreeWidth(nextWidth)
      }

      const onPointerUp = () => {
        window.removeEventListener('pointermove', onPointerMove)
        window.removeEventListener('pointerup', onPointerUp)
        document.body.classList.remove('select-none', 'cursor-col-resize')
      }

      document.body.classList.add('select-none', 'cursor-col-resize')
      window.addEventListener('pointermove', onPointerMove)
      window.addEventListener('pointerup', onPointerUp)
    }

    this.onKeyDown = (event) => {
      const target = event.target
      const isTypingTarget =
        target instanceof HTMLElement &&
          (target.tagName === 'INPUT' ||
            target.tagName === 'TEXTAREA' ||
            target.tagName === 'SELECT' ||
            target.isContentEditable)

      if (event.key === '/' && !isTypingTarget && !event.metaKey && !event.ctrlKey && !event.altKey) {
        event.preventDefault()
        this.focusSearch()
        return
      }

      if ((event.key.toLowerCase() === 'f' && (event.metaKey || event.ctrlKey)) && !event.altKey) {
        event.preventDefault()
        this.focusSearch()
        return
      }

      if (event.key.toLowerCase() === 'n' && !isTypingTarget && !event.metaKey && !event.ctrlKey && !event.altKey) {
        event.preventDefault()
        this.pushEvent('toggle_new_folder', {})
        return
      }

      if (event.key === 'Escape' && !isTypingTarget) {
        this.pushEvent('cancel_new_folder', {})
        return
      }

      if (isTypingTarget || !this.rows || this.rows.length === 0) return

      if (event.key === 'ArrowDown') {
        event.preventDefault()
        const nextIndex = this.activeRowIndex < 0 ? 0 : this.activeRowIndex + 1

        if (event.shiftKey) {
          this.setActiveRow(nextIndex)
          this.selectRangeTo(this.activeRowIndex)
        } else {
          this.anchorRowIndex = Math.max(0, Math.min(nextIndex, this.rows.length - 1))
          this.setActiveRow(nextIndex)
        }

        return
      }

      if (event.key === 'ArrowUp') {
        event.preventDefault()
        const nextIndex = this.activeRowIndex < 0 ? 0 : this.activeRowIndex - 1

        if (event.shiftKey) {
          this.setActiveRow(nextIndex)
          this.selectRangeTo(this.activeRowIndex)
        } else {
          this.anchorRowIndex = Math.max(0, nextIndex)
          this.setActiveRow(nextIndex)
        }

        return
      }

      if (event.key === 'Home') {
        event.preventDefault()
        this.anchorRowIndex = 0
        this.setActiveRow(0)
        return
      }

      if (event.key === 'End') {
        event.preventDefault()
        this.anchorRowIndex = this.rows.length - 1
        this.setActiveRow(this.rows.length - 1)
        return
      }

      if (event.key === 'Enter') {
        event.preventDefault()
        this.openRow(this.rows[this.activeRowIndex])
        return
      }

      if (event.key === 'F2') {
        event.preventDefault()
        const row = this.rows[this.activeRowIndex]
        if (!row) return

        if (row.dataset.rowKind === 'folder') {
          this.pushEvent('open_manage_folder', { path: row.dataset.rowOpenPath })
          this.pushEvent('start_rename', { type: 'folder', path: row.dataset.rowOpenPath })
        } else {
          this.pushEvent('open_manage_file', { id: row.dataset.rowOpenId })
          this.pushEvent('start_rename', { type: 'file', id: row.dataset.rowOpenId })
        }

        return
      }

      if (event.key === ' ') {
        event.preventDefault()
        const row = this.rows[this.activeRowIndex]
        if (row) {
          this.anchorRowIndex = this.activeRowIndex
          this.pushEvent('toggle_select', { token: row.dataset.rowToken })
        }
      }
    }

    this.el.addEventListener('click', this.onClick)
    this.el.addEventListener('dblclick', this.onDoubleClick)
    this.el.addEventListener('dragstart', this.onDragStart)
    this.el.addEventListener('dragend', this.onDragEnd)
    this.el.addEventListener('dragover', this.onDragOver)
    this.el.addEventListener('dragleave', this.onDragLeave)
    this.el.addEventListener('drop', this.onDrop)
    if (this.treeResizer) this.treeResizer.addEventListener('pointerdown', this.onResizeStart)
    window.addEventListener('keydown', this.onKeyDown)
    this.restoreTreeWidth()
    this.refreshRows()
  },

  updated() {
    this.searchInput = this.el.querySelector('#file-explorer-search')
    this.refreshRows()
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener('click', this.onClick)
    if (this.onDoubleClick) this.el.removeEventListener('dblclick', this.onDoubleClick)
    if (this.onDragStart) this.el.removeEventListener('dragstart', this.onDragStart)
    if (this.onDragEnd) this.el.removeEventListener('dragend', this.onDragEnd)
    if (this.onDragOver) this.el.removeEventListener('dragover', this.onDragOver)
    if (this.onDragLeave) this.el.removeEventListener('dragleave', this.onDragLeave)
    if (this.onDrop) this.el.removeEventListener('drop', this.onDrop)
    if (this.treeResizer && this.onResizeStart) this.treeResizer.removeEventListener('pointerdown', this.onResizeStart)
    if (this.onKeyDown) window.removeEventListener('keydown', this.onKeyDown)
  },

  focusSearch() {
    if (!this.searchInput) return

    this.searchInput.focus()
    const length = this.searchInput.value.length
    this.searchInput.setSelectionRange(length, length)
  }
}
