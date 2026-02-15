// Flash Message Manager for handling multiple flash messages

export class FlashMessageManager {
  constructor() {
    this.messages = new Map()
    this.stackOffset = 0
  }

  addMessage(element, hook) {
    const id = this.generateId()

    // Check if we're in a LiveView context
    const isLiveView = document.querySelector('[data-phx-main]') !== null

    // Ensure proper positioning context
    element.style.position = 'fixed'
    element.style.right = '1rem'
    element.style.zIndex = '1000'
    element.style.maxWidth = '400px'

    // Position message in stack with proper spacing
    const spacing = 4.5 // rem between messages
    element.style.bottom = `${1 + (this.messages.size * spacing)}rem`

    if (isLiveView) {
      // Animate in for LiveView pages
      element.style.opacity = '0'
      element.style.transform = 'translateX(100%)'

      requestAnimationFrame(() => {
        element.style.transition = 'all 0.3s ease-out'
        element.style.opacity = '1'
        element.style.transform = 'translateX(0)'
      })
    } else {
      // No animation for regular pages - just show immediately
      element.style.opacity = '1'
      element.style.transform = 'translateX(0)'
      element.style.transition = 'none'
    }

    this.messages.set(id, { element, hook })
    return id
  }

  removeMessage(element) {
    // Find and remove from map
    for (const [id, { element: el }] of this.messages) {
      if (el === element) {
        this.messages.delete(id)
        break
      }
    }

    // Reposition remaining messages
    this.repositionMessages()
  }

  repositionMessages() {
    const isLiveView = document.querySelector('[data-phx-main]') !== null
    let index = 0
    const spacing = 4.5 // rem between messages

    for (const [id, { element }] of this.messages) {
      if (!element.dataset.hiding) {
        // Ensure positioning is maintained
        element.style.position = 'fixed'
        element.style.right = '1rem'
        element.style.zIndex = `${1000 + index}` // Increment z-index for proper layering
        element.style.bottom = `${1 + (index * spacing)}rem`

        // Add smooth transition for repositioning
        if (isLiveView) {
          element.style.transition = 'bottom 0.3s ease-out'
        } else {
          element.style.transition = 'none'
        }

        index++
      }
    }
  }

  generateId() {
    return `flash-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
  }
}