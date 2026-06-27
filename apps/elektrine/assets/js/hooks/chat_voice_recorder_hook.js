export const VoiceRecorder = {
  mounted() {
    this.mediaRecorder = null
    this.audioChunks = []
    this.isRecording = false
    this.recordingTimer = null
    this.recordingSeconds = 0
    this.maxDuration = 120

    const recordBtn = this.el
    const timerEl = document.getElementById('voice-timer')
    const cancelBtn = document.getElementById('voice-cancel')
    const sendBtn = document.getElementById('voice-send')
    const recordingIndicator = document.getElementById('voice-recording-indicator')
    this.cancelBtn = cancelBtn
    this.sendBtn = sendBtn

    const updateUI = (recording) => {
      if (recordingIndicator) {
        recordingIndicator.classList.toggle('hidden', !recording)
      }
      recordBtn.classList.toggle('text-error', recording)
      recordBtn.classList.toggle('animate-pulse', recording)
    }

    const formatTime = (seconds) => {
      const mins = Math.floor(seconds / 60)
      const secs = seconds % 60
      return `${mins}:${secs.toString().padStart(2, '0')}`
    }

    const startRecording = async () => {
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
        this.audioChunks = []

        const mimeType = MediaRecorder.isTypeSupported('audio/webm') ? 'audio/webm' : 'audio/mp4'
        this.mediaRecorder = new MediaRecorder(stream, { mimeType })

        this.mediaRecorder.ondataavailable = (event) => {
          if (event.data.size > 0) {
            this.audioChunks.push(event.data)
          }
        }

        this.mediaRecorder.onstop = () => {
          stream.getTracks().forEach((track) => track.stop())
        }

        this.mediaRecorder.start(100)
        this.isRecording = true
        this.recordingSeconds = 0
        updateUI(true)

        this.recordingTimer = setInterval(() => {
          this.recordingSeconds++
          if (timerEl) {
            timerEl.textContent = formatTime(this.recordingSeconds)
          }

          if (this.recordingSeconds >= this.maxDuration) {
            sendRecording()
          }
        }, 1000)
      } catch (_err) {
        this.pushEvent('voice_recording_error', { error: 'Microphone access denied' })
      }
    }

    const stopRecording = () => {
      if (this.mediaRecorder && this.isRecording) {
        this.mediaRecorder.stop()
        this.isRecording = false
        clearInterval(this.recordingTimer)
        updateUI(false)
        if (timerEl) timerEl.textContent = '0:00'
      }
    }

    const cancelRecording = () => {
      stopRecording()
      this.audioChunks = []
      this.recordingSeconds = 0
    }

    const sendRecording = async () => {
      if (!this.isRecording && this.audioChunks.length === 0) return

      if (this.isRecording) {
        this.mediaRecorder.stop()
        this.isRecording = false
        clearInterval(this.recordingTimer)
        updateUI(false)

        await new Promise((resolve) => setTimeout(resolve, 100))
      }

      if (this.audioChunks.length === 0) return

      const mimeType = this.mediaRecorder?.mimeType || 'audio/webm'
      const audioBlob = new Blob(this.audioChunks, { type: mimeType })
      const duration = this.recordingSeconds
      const reader = new FileReader()

      reader.onload = () => {
        const base64 = reader.result.split(',')[1]
        this.pushEvent('send_voice_message', {
          audio_data: base64,
          duration: duration,
          mime_type: mimeType
        })
      }

      reader.readAsDataURL(audioBlob)
      this.audioChunks = []
      this.recordingSeconds = 0
      if (timerEl) timerEl.textContent = '0:00'
    }

    this.recordClickHandler = () => {
      if (this.isRecording) {
        sendRecording()
      } else {
        startRecording()
      }
    }
    recordBtn.addEventListener('click', this.recordClickHandler)

    if (cancelBtn) {
      this.cancelClickHandler = cancelRecording
      cancelBtn.addEventListener('click', this.cancelClickHandler)
    }

    if (sendBtn) {
      this.sendClickHandler = sendRecording
      sendBtn.addEventListener('click', this.sendClickHandler)
    }

    this.escapeKeyHandler = (event) => {
      if (event.key === 'Escape' && this.isRecording) {
        cancelRecording()
      }
    }
    document.addEventListener('keydown', this.escapeKeyHandler)
  },

  destroyed() {
    if (this.recordClickHandler) {
      this.el.removeEventListener('click', this.recordClickHandler)
    }
    if (this.cancelBtn && this.cancelClickHandler) {
      this.cancelBtn.removeEventListener('click', this.cancelClickHandler)
    }
    if (this.sendBtn && this.sendClickHandler) {
      this.sendBtn.removeEventListener('click', this.sendClickHandler)
    }
    if (this.escapeKeyHandler) {
      document.removeEventListener('keydown', this.escapeKeyHandler)
    }
    if (this.recordingTimer) {
      clearInterval(this.recordingTimer)
    }
    if (this.mediaRecorder && this.isRecording) {
      this.mediaRecorder.stop()
    }
  }
}
