/**
 * Profile Hooks
 * Hooks related to user profiles and status display.
 */

/**
 * Typewriter Effect Hook
 * Animates text to appear as if being typed
 */
export const TypewriterHook = {
  mounted() {
    this.hasCompleted = false
    this.startTypewriter()
  },

  updated() {
    const newText = this.el.dataset.text

    if (this.hasCompleted && this.lastText === newText) {
      if (this.el.textContent !== newText) {
        this.el.textContent = newText
        this.el.classList.remove('typewriter-cursor')

        const effectClass = this.el.dataset.effectClass || ''
        const effectStyle = this.el.dataset.effectStyle || ''
        const dataText = this.el.dataset.dataText || newText

        if (effectClass) {
          effectClass.split(' ').filter(c => c.trim()).forEach(c => this.el.classList.add(c))
        }

        if (effectStyle) {
          effectStyle.split(';').filter(s => s.trim()).forEach(s => {
            const [prop, value] = s.split(':').map(p => p.trim())
            if (prop && value) this.el.style.setProperty(prop, value)
          })
        }

        if (dataText && (effectClass.includes('glitch') || effectClass.includes('double'))) {
          this.el.setAttribute('data-text', dataText)
        }
      }
      return
    }

    if (this.timeout) clearTimeout(this.timeout)
    this.hasCompleted = false
    this.startTypewriter()
  },

  destroyed() {
    if (this.timeout) clearTimeout(this.timeout)
  },

  startTypewriter() {
    const text = this.el.dataset.text
    const speed = this.el.dataset.speed || 'normal'
    const effectClass = this.el.dataset.effectClass || ''
    const effectStyle = this.el.dataset.effectStyle || ''
    const dataText = this.el.dataset.dataText || text

    this.lastText = text

    if (!text) {
      this.el.textContent = ' '
      return
    }

    const speeds = { slow: 100, normal: 50, fast: 25 }
    const delay = speeds[speed] || speeds.normal

    this.el.textContent = text
    this.el.style.opacity = '0'
    this.el.offsetHeight
    this.el.textContent = ''
    this.el.style.opacity = '1'
    this.el.style.minHeight = '1em'

    if (effectClass) {
      effectClass.split(' ').filter(c => c.trim()).forEach(c => this.el.classList.add(c))
    }

    if (effectStyle) {
      effectStyle.split(';').filter(s => s.trim()).forEach(s => {
        const [prop, value] = s.split(':').map(p => p.trim())
        if (prop && value) this.el.style.setProperty(prop, value)
      })
    }

    if (dataText && (effectClass.includes('glitch') || effectClass.includes('double'))) {
      this.el.setAttribute('data-text', dataText)
    }

    this.el.classList.add('typewriter-cursor')

    let index = 0
    const typeChar = () => {
      if (index < text.length) {
        this.el.textContent = text.substring(0, index + 1)
        if (dataText && (effectClass.includes('glitch') || effectClass.includes('double'))) {
          this.el.setAttribute('data-text', text.substring(0, index + 1))
        }
        index++
        this.timeout = setTimeout(typeChar, delay)
      } else {
        this.el.classList.remove('typewriter-cursor')
        this.hasCompleted = true
      }
    }

    this.timeout = setTimeout(typeChar, 500)
  }
}

/**
 * Tab Title Typewriter Effect
 * Animates the browser tab title with typewriter effect
 */
export const TabTitleTypewriter = {
  mounted() {
    const text = this.el.dataset.text
    const speed = this.el.dataset.speed || 'normal'
    const speeds = { slow: 150, normal: 100, fast: 50 }
    const delay = speeds[speed] || speeds.normal

    this.originalTitle = document.title

    let index = 0
    const typeChar = () => {
      if (index <= text.length) {
        document.title = text.substring(0, index) + (index < text.length ? '|' : '')
        index++
        setTimeout(typeChar, delay)
      } else {
        document.title = text
      }
    }

    typeChar()
  },

  destroyed() {
    if (this.originalTitle) document.title = this.originalTitle
  }
}

/**
 * Video Background Hook
 * Ensures background videos autoplay reliably across all browsers
 */
export const VideoBackground = {
  mounted() {
    this.video = this.el
    this.isPlaying = false
    this.setupEventListeners()
    if (this.video.readyState >= 1) this.tryPlay()
  },

  destroyed() {
    if (this.visibilityHandler) {
      document.removeEventListener('visibilitychange', this.visibilityHandler)
    }
  },

  setupEventListeners() {
    this.video.addEventListener('loadedmetadata', () => this.tryPlay())
    this.video.addEventListener('playing', () => { this.isPlaying = true })
    this.video.addEventListener('pause', () => { this.isPlaying = false })
    this.video.addEventListener('ended', () => this.tryPlay())

    this.visibilityHandler = () => {
      if (!document.hidden && !this.isPlaying) this.tryPlay()
    }
    document.addEventListener('visibilitychange', this.visibilityHandler)
  },

  tryPlay() {
    if (!this.video.paused) return

    const playPromise = this.video.play()
    if (playPromise !== undefined) {
      playPromise
        .then(() => { this.isPlaying = true })
        .catch(() => {
          this.isPlaying = false
          setTimeout(() => { if (!this.isPlaying) this.tryPlay() }, 1000)
        })
    }
  }
}

/**
 * Status Selector Hook
 * Updates UI immediately when status changes
 */
export const StatusSelector = {
  mounted() {
    this.handleEvent("status_updated", ({ status }) => this.updateStatusUI(status))

    this.formSubmitHandlers = new Map()
    const forms = this.el.querySelectorAll('form[action="/account/status"]')
    forms.forEach(form => {
      const handler = (e) => {
        e.preventDefault()

        const statusInput = form.querySelector('input[name="status"]')
        const status = statusInput?.value
        if (!status) return

        this.updateStatusUI(status)
        this.submitStatus(form, status)
      }

      form.addEventListener('submit', handler)
      this.formSubmitHandlers.set(form, handler)
    })
  },

  destroyed() {
    if (this.formSubmitHandlers) {
      this.formSubmitHandlers.forEach((handler, form) => {
        form.removeEventListener('submit', handler)
      })
      this.formSubmitHandlers.clear()
    }
  },

  async submitStatus(form, status) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const headers = csrfToken ? { 'X-CSRF-Token': csrfToken } : {}

    try {
      await fetch(form.action, {
        method: 'POST',
        headers,
        body: new FormData(form),
        credentials: 'same-origin'
      })

      const idleDetector = document.getElementById('idle-detector')
      if (idleDetector) {
        idleDetector.dataset.userStatus = status
      }
    } catch (error) {
      console.error('Failed to update status:', error)
    }
  },

  updateStatusUI(status) {
    const indicator = this.el.querySelector('.status-indicator')
    if (indicator) {
      indicator.classList.remove('bg-success', 'bg-warning', 'bg-error', 'bg-gray-400', 'bg-base-300')
      switch(status) {
        case 'online': indicator.classList.add('bg-success'); break
        case 'away': indicator.classList.add('bg-warning'); break
        case 'dnd': indicator.classList.add('bg-error'); break
        case 'offline': indicator.classList.add('bg-base-300'); break
      }
    }

    const buttons = this.el.querySelectorAll('form[action="/account/status"] button')
    buttons.forEach(button => {
      const form = button.closest('form')
      const statusInput = form.querySelector('input[name="status"]')
      if (statusInput) {
        const buttonStatus = statusInput.value
        button.classList.remove(
          'bg-success/10', 'text-success', 'border-success/30',
          'bg-warning/10', 'text-warning', 'border-warning/30',
          'bg-error/10', 'text-error', 'border-error/30',
          'bg-base-300/20', 'bg-base-300/50'
        )
        button.classList.add('border', 'border-base-300')

        if (buttonStatus === status) {
          button.classList.remove('border-base-300')
          switch(status) {
            case 'online': button.classList.add('bg-success/10', 'text-success', 'border-success/30'); break
            case 'away': button.classList.add('bg-warning/10', 'text-warning', 'border-warning/30'); break
            case 'dnd': button.classList.add('bg-error/10', 'text-error', 'border-error/30'); break
            case 'offline': button.classList.add('bg-base-300/20'); break
          }
        }
      }
    })
  }
}
