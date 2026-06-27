import { copyToClipboard } from '../utils/clipboard'

function selectedTextWithin(element) {
  const selection = window.getSelection()

  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return ''

  const text = selection.toString().trim()
  if (!text) return ''

  for (let index = 0; index < selection.rangeCount; index++) {
    const range = selection.getRangeAt(index)
    const container = range.commonAncestorContainer
    const node = container.nodeType === Node.TEXT_NODE ? container.parentElement : container

    if (node && element.contains(node)) {
      return text
    }
  }

  return ''
}

function contextMenuPosition(x, y) {
  const margin = 8
  const estimatedWidth = 224
  const estimatedHeight = 360
  const maxX = Math.max(margin, window.innerWidth - estimatedWidth - margin)
  const maxY = Math.max(margin, window.innerHeight - estimatedHeight - margin)

  return {
    x: Math.min(Math.max(x, margin), maxX),
    y: Math.min(Math.max(y, margin), maxY)
  }
}

export const ContextMenu = {
  mounted() {
    const conversationId = this.el.dataset.conversationId

    this.contextMenuHandler = (e) => {
      e.preventDefault()
      const position = contextMenuPosition(e.clientX, e.clientY)
      this.pushEvent("hide_message_context_menu", {})
      this.pushEvent("show_context_menu", {
        conversation_id: parseInt(conversationId),
        x: position.x,
        y: position.y
      })
    }
    this.el.addEventListener("contextmenu", this.contextMenuHandler)

    this.customEventHandler = (e) => {
      const { conversation_id, x, y } = e.detail
      const position = contextMenuPosition(x, y)
      this.pushEvent("hide_message_context_menu", {})
      this.pushEvent("show_context_menu", {
        conversation_id: conversation_id,
        x: position.x,
        y: position.y
      })
    }
    this.el.addEventListener("phx:show_context_menu", this.customEventHandler)

    this.clickHandler = (e) => {
      const contextMenu = document.querySelector('[phx-click-away="hide_context_menu"]')
      if (contextMenu && !contextMenu.contains(e.target)) {
        this.pushEvent("hide_context_menu", {})
      }
    }

    document.addEventListener("click", this.clickHandler)

    this.scrollHandler = () => {
      this.pushEvent("hide_context_menu", {})
    }
    this.el.addEventListener("scroll", this.scrollHandler)
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.contextMenuHandler)
    this.el.removeEventListener("phx:show_context_menu", this.customEventHandler)
    document.removeEventListener("click", this.clickHandler)
    this.el.removeEventListener("scroll", this.scrollHandler)
  }
}

export const MessageContextMenu = {
  mounted() {
    const messageId = this.el.dataset.messageId
    const senderId = this.el.dataset.senderId

    this.contextMenuHandler = (e) => {
      e.preventDefault()
      const selectedText = selectedTextWithin(this.el)
      const position = contextMenuPosition(e.clientX, e.clientY)
      this.pushEvent("hide_context_menu", {})
      this.pushEvent("show_message_context_menu", {
        message_id: parseInt(messageId),
        sender_id: parseInt(senderId),
        selected_text: selectedText,
        x: position.x,
        y: position.y
      })
    }
    this.el.addEventListener("contextmenu", this.contextMenuHandler)

    this.customEventHandler = (e) => {
      const { message_id, sender_id, x, y } = e.detail
      const position = contextMenuPosition(x, y)
      this.pushEvent("hide_context_menu", {})
      this.pushEvent("show_message_context_menu", {
        message_id: message_id,
        sender_id: sender_id,
        x: position.x,
        y: position.y
      })
    }
    this.el.addEventListener("phx:show_message_context_menu", this.customEventHandler)

    this.clickHandler = (e) => {
      const contextMenu = document.querySelector('[phx-click-away="hide_message_context_menu"]')
      if (contextMenu && !contextMenu.contains(e.target)) {
        this.pushEvent("hide_message_context_menu", {})
      }
    }

    document.addEventListener("click", this.clickHandler)

    this.scrollHandler = () => {
      this.pushEvent("hide_message_context_menu", {})
    }
    this.el.addEventListener("scroll", this.scrollHandler)

    this.keyHandler = (e) => {
      if (e.key === "Escape") {
        this.pushEvent("hide_message_context_menu", {})
      }
    }
    document.addEventListener("keydown", this.keyHandler)
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.contextMenuHandler)
    this.el.removeEventListener("phx:show_message_context_menu", this.customEventHandler)
    document.removeEventListener("click", this.clickHandler)
    document.removeEventListener("keydown", this.keyHandler)
    this.el.removeEventListener("scroll", this.scrollHandler)
  }
}

export const CopyChatMessage = {
  mounted() {
    this.copyHandler = () => {
      const text = this.el.dataset.copyContent || ''
      const type = this.el.dataset.copyType || 'message'
      copyToClipboard(text, type)

      const hideEvent = this.el.dataset.hideEvent
      if (hideEvent) {
        this.pushEvent(hideEvent, {})
      }
    }

    this.el.addEventListener('click', this.copyHandler)
  },

  destroyed() {
    this.el.removeEventListener('click', this.copyHandler)
  }
}
