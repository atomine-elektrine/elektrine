/**
 * LiveView hooks for WebRTC calling functionality.
 */

import { WebRTCClient } from '../webrtc_client'
import { Socket } from 'phoenix'
import { globalRingtone } from '../ringtone_player'

function createSocket(userToken) {
  const socket = new Socket("/socket", { params: { token: userToken } })
  socket.connect()
  return socket
}

function mapCallError(error) {
  if (!error) {
    return "Unable to start call."
  }

  const message = error.message || "Unable to start call."

  if (error.name === "NotAllowedError" || message.includes("Permission denied")) {
    return "Microphone/camera access denied. Please allow access in your browser settings and try again."
  }

  if (error.name === "NotFoundError") {
    return "No microphone or camera found. Please connect a device and try again."
  }

  if (message.includes("secure origin")) {
    return "Calls require HTTPS. Please use a secure connection."
  }

  return message
}

function setMediaElementsFromStream(stream) {
  if (!stream) {
    return
  }

  const hasVideo = stream.getVideoTracks().length > 0

  if (hasVideo) {
    const videoElement = document.getElementById("remote-video")
    if (videoElement) {
      videoElement.srcObject = stream
      videoElement.play().catch(() => {})
    }
    return
  }

  const audioElement = document.getElementById("remote-audio")
  if (audioElement) {
    audioElement.srcObject = stream
    audioElement.play().catch(() => {})
  }
}

/**
 * Hook for initiating and managing outgoing calls.
 */
export const CallInitiator = {
  mounted() {
    this.handleEvent("start_call", ({ call_id, call_type, ice_servers, user_token }) => {
      this.startCall(call_id, call_type, ice_servers, user_token)
    })
  },

  async startCall(callId, callType, iceServers, userToken) {
    this.cleanup()

    try {
      globalRingtone.playOutgoing()

      const socket = createSocket(userToken)
      const client = new WebRTCClient(socket, callId, null, iceServers)

      this.client = client
      window.activeCallClient = client

      client.onRemoteStream((stream) => {
        this.pushEvent("remote_stream_ready", {})
        this.setRemoteStream(stream)
      })

      client.onCallEnded((reason) => {
        if (reason !== "rejected") {
          globalRingtone.playEnded()
        } else {
          globalRingtone.stop()
        }

        this.pushEvent("call_ended", { reason })
        this.cleanup()
      })

      client.onConnectionEstablished(() => {
        globalRingtone.stop()
        globalRingtone.playConnected()
        this.pushEvent("call_connected", {})
      })

      await client.initialize()
      await client.startCall(callType)
      this.setLocalStream(client.getLocalStream())

      this.pushEvent("call_started", {})
    } catch (error) {
      globalRingtone.stop()
      this.pushEvent("call_error", { error: mapCallError(error) })

      if (this.client) {
        this.client.endCall()
      }
    }
  },

  setLocalStream(stream) {
    const videoElement = document.getElementById("local-video")
    if (videoElement) {
      videoElement.srcObject = stream
      videoElement.play().catch(() => {})
    }
  },

  setRemoteStream(stream) {
    setMediaElementsFromStream(stream)
  },

  cleanup() {
    globalRingtone.stop()

    if (this.client) {
      this.client.cleanup()
      this.client = null
    }

    window.activeCallClient = null
  },

  destroyed() {
    this.cleanup()
  }
}

/**
 * Hook for receiving and answering incoming calls.
 */
export const CallReceiver = {
  mounted() {
    this.handleEvent("answer_call", ({ call_id, ice_servers, user_token }) => {
      this.answerCall(call_id, ice_servers, user_token)
    })

    this.handleEvent("reject_call", ({ call_id, user_token }) => {
      this.rejectCall(call_id, user_token)
    })

    this.handleEvent("play_incoming_ringtone", () => {
      globalRingtone.playIncoming()
    })

    this.handleEvent("stop_ringtone", () => {
      globalRingtone.stop()
    })
  },

  async answerCall(callId, iceServers, userToken) {
    this.cleanup()

    try {
      globalRingtone.stop()

      const socket = createSocket(userToken)
      const client = new WebRTCClient(socket, callId, null, iceServers)

      this.client = client
      window.activeCallClient = client

      client.onRemoteStream((stream) => {
        this.pushEvent("remote_stream_ready", {})
        this.setRemoteStream(stream)
      })

      client.onCallEnded((reason) => {
        if (reason !== "rejected") {
          globalRingtone.playEnded()
        } else {
          globalRingtone.stop()
        }

        this.pushEvent("call_ended", { reason })
        this.cleanup()
      })

      client.onConnectionEstablished(() => {
        globalRingtone.playConnected()
        this.pushEvent("call_connected", {})
      })

      await client.initialize()
      client.channel.push("ready_to_receive", {})
      this.pushEvent("call_answered", {})
    } catch (error) {
      globalRingtone.stop()
      this.pushEvent("call_error", { error: mapCallError(error) })

      if (this.client) {
        this.client.endCall()
      }
    }
  },

  async rejectCall(callId, userToken) {
    this.cleanup()

    try {
      globalRingtone.stop()

      const socket = createSocket(userToken)
      const client = new WebRTCClient(socket, callId, null, [])

      await client.initialize()
      client.rejectCall()
      this.pushEvent("call_rejected", {})
    } catch (_error) {
      globalRingtone.stop()
    }
  },

  setRemoteStream(stream) {
    setMediaElementsFromStream(stream)
  },

  cleanup() {
    globalRingtone.stop()

    if (this.client) {
      this.client.cleanup()
      this.client = null
    }

    window.activeCallClient = null
  },

  destroyed() {
    this.cleanup()
  }
}

/**
 * Hook for managing active call controls.
 */
export const CallControls = {
  mounted() {
    this.handleToggleAudio = (e) => {
      e.preventDefault()
      const client = window.activeCallClient

      if (client) {
        const enabled = client.toggleAudio()
        this.pushEvent("audio_toggled", { enabled })
      }
    }

    this.handleToggleVideo = (e) => {
      e.preventDefault()
      const client = window.activeCallClient

      if (client) {
        const enabled = client.toggleVideo()
        this.pushEvent("video_toggled", { enabled })
      }
    }

    this.handleEndCall = (e) => {
      e.preventDefault()
      const client = window.activeCallClient

      if (client) {
        client.endCall()
      }

      this.pushEvent("call_ended_by_user", {})
    }

    this.audioButton = this.el.querySelector('[data-action="toggle-audio"]')
    this.videoButton = this.el.querySelector('[data-action="toggle-video"]')
    this.endButton = this.el.querySelector('[data-action="end-call"]')

    this.audioButton?.addEventListener("click", this.handleToggleAudio)
    this.videoButton?.addEventListener("click", this.handleToggleVideo)
    this.endButton?.addEventListener("click", this.handleEndCall)
  },

  destroyed() {
    this.audioButton?.removeEventListener("click", this.handleToggleAudio)
    this.videoButton?.removeEventListener("click", this.handleToggleVideo)
    this.endButton?.removeEventListener("click", this.handleEndCall)
  }
}

/**
 * Hook for displaying video streams.
 */
export const VideoDisplay = {
  mounted() {
    const localVideo = this.el.querySelector("#local-video")
    const remoteVideo = this.el.querySelector("#remote-video")

    if (localVideo) {
      localVideo.muted = true
      localVideo.autoplay = true
      localVideo.playsInline = true
    }

    if (remoteVideo) {
      remoteVideo.autoplay = true
      remoteVideo.playsInline = true
    }

    window.videoDisplay = this.el
  },

  destroyed() {
    window.videoDisplay = null
  }
}

/**
 * Hook for displaying call duration timer.
 */
export const CallTimer = {
  mounted() {
    this.startTime = null
    this.timerInterval = null

    const status = this.el.dataset.status

    if (status === "connected") {
      this.startTimer()
    }
  },

  updated() {
    const status = this.el.dataset.status

    if (status === "connected" && !this.timerInterval) {
      this.startTimer()
    } else if (status !== "connected" && this.timerInterval) {
      this.stopTimer()
    }
  },

  startTimer() {
    this.startTime = Date.now()
    this.timerInterval = setInterval(() => {
      const elapsed = Math.floor((Date.now() - this.startTime) / 1000)
      this.el.textContent = this.formatDuration(elapsed)
    }, 1000)
  },

  stopTimer() {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
      this.timerInterval = null
    }
  },

  formatDuration(seconds) {
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60

    if (hours > 0) {
      return `${hours}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`
    }

    return `${minutes}:${String(secs).padStart(2, '0')}`
  },

  destroyed() {
    this.stopTimer()
  }
}
