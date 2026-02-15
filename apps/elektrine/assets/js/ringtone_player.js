/**
 * Ringtone Player for Skype-like call sounds
 * Generates ringtones using Web Audio API
 */

export class RingtonePlayer {
  constructor() {
    this.audioContext = null
    this.oscillator = null
    this.gainNode = null
    this.isPlaying = false
    this.ringtoneInterval = null
  }

  /**
   * Initialize Audio Context (must be called after user interaction)
   */
  init() {
    if (!this.audioContext) {
      this.audioContext = new (window.AudioContext || window.webkitAudioContext)()
    }
  }

  /**
   * Play outgoing call ringtone (Skype-like beep-beep pattern)
   */
  playOutgoing() {
    this.stop() // Stop any current ringtone
    this.init()
    this.isPlaying = true

    const playTone = () => {
      if (!this.isPlaying) return

      // Create oscillator for the tone
      this.oscillator = this.audioContext.createOscillator()
      this.gainNode = this.audioContext.createGain()

      this.oscillator.connect(this.gainNode)
      this.gainNode.connect(this.audioContext.destination)

      // Skype outgoing call tone: 440Hz
      this.oscillator.frequency.value = 440
      this.oscillator.type = 'sine'

      // Volume
      this.gainNode.gain.value = 0.2

      // Play pattern: beep (400ms) - pause (200ms) - beep (400ms) - pause (3000ms)
      const now = this.audioContext.currentTime

      // First beep
      this.oscillator.start(now)
      this.gainNode.gain.setValueAtTime(0.2, now)
      this.gainNode.gain.exponentialRampToValueAtTime(0.01, now + 0.4)

      // Stop after pattern completes
      this.oscillator.stop(now + 0.4)

      // Schedule second beep
      setTimeout(() => {
        if (!this.isPlaying) return

        const osc2 = this.audioContext.createOscillator()
        const gain2 = this.audioContext.createGain()

        osc2.connect(gain2)
        gain2.connect(this.audioContext.destination)

        osc2.frequency.value = 440
        osc2.type = 'sine'

        const now2 = this.audioContext.currentTime
        osc2.start(now2)
        gain2.gain.setValueAtTime(0.2, now2)
        gain2.gain.exponentialRampToValueAtTime(0.01, now2 + 0.4)
        osc2.stop(now2 + 0.4)
      }, 600)
    }

    // Play immediately then repeat every 4 seconds
    playTone()
    this.ringtoneInterval = setInterval(playTone, 4000)
  }

  /**
   * Play incoming call ringtone (Skype-like ring pattern)
   */
  playIncoming() {
    this.stop() // Stop any current ringtone
    this.init()
    this.isPlaying = true

    const playRing = () => {
      if (!this.isPlaying) return

      // Create two-tone ring (like a phone ring)
      const playDualTone = (startTime) => {
        // High frequency
        const osc1 = this.audioContext.createOscillator()
        const gain1 = this.audioContext.createGain()
        osc1.connect(gain1)
        gain1.connect(this.audioContext.destination)
        osc1.frequency.value = 480
        osc1.type = 'sine'
        gain1.gain.value = 0.15

        // Low frequency
        const osc2 = this.audioContext.createOscillator()
        const gain2 = this.audioContext.createGain()
        osc2.connect(gain2)
        gain2.connect(this.audioContext.destination)
        osc2.frequency.value = 440
        osc2.type = 'sine'
        gain2.gain.value = 0.15

        osc1.start(startTime)
        osc2.start(startTime)
        osc1.stop(startTime + 1)
        osc2.stop(startTime + 1)
      }

      const now = this.audioContext.currentTime

      // Ring pattern: ring (1s) - pause (0.5s) - ring (1s) - pause (3s)
      playDualTone(now)
      setTimeout(() => {
        if (this.isPlaying) {
          playDualTone(this.audioContext.currentTime)
        }
      }, 1500)
    }

    // Play immediately then repeat every 5.5 seconds
    playRing()
    this.ringtoneInterval = setInterval(playRing, 5500)
  }

  /**
   * Play call connected sound (single short beep)
   */
  playConnected() {
    this.init()

    const osc = this.audioContext.createOscillator()
    const gain = this.audioContext.createGain()

    osc.connect(gain)
    gain.connect(this.audioContext.destination)

    osc.frequency.value = 800
    osc.type = 'sine'

    const now = this.audioContext.currentTime
    osc.start(now)
    gain.gain.setValueAtTime(0.2, now)
    gain.gain.exponentialRampToValueAtTime(0.01, now + 0.2)
    osc.stop(now + 0.2)
  }

  /**
   * Play call ended sound (descending tone)
   */
  playEnded() {
    this.stop()
    this.init()

    const osc = this.audioContext.createOscillator()
    const gain = this.audioContext.createGain()

    osc.connect(gain)
    gain.connect(this.audioContext.destination)

    osc.type = 'sine'

    const now = this.audioContext.currentTime
    osc.frequency.setValueAtTime(600, now)
    osc.frequency.exponentialRampToValueAtTime(300, now + 0.5)

    gain.gain.setValueAtTime(0.2, now)
    gain.gain.exponentialRampToValueAtTime(0.01, now + 0.5)

    osc.start(now)
    osc.stop(now + 0.5)
  }

  /**
   * Stop all ringtones
   */
  stop() {
    this.isPlaying = false

    if (this.ringtoneInterval) {
      clearInterval(this.ringtoneInterval)
      this.ringtoneInterval = null
    }

    if (this.oscillator) {
      try {
        this.oscillator.stop()
      } catch (e) {
        // Already stopped
      }
      this.oscillator = null
    }

    if (this.gainNode) {
      this.gainNode = null
    }
  }

  /**
   * Cleanup
   */
  destroy() {
    this.stop()
    if (this.audioContext) {
      this.audioContext.close()
      this.audioContext = null
    }
  }
}

// Create a global instance
export const globalRingtone = new RingtonePlayer()
