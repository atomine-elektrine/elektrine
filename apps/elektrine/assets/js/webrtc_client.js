/**
 * WebRTC Client for peer-to-peer audio/video calling
 * Handles signaling, media, recovery, and cleanup.
 */

const CHANNEL_JOIN_DELAY_MS = 100
const ICE_RESTART_DELAY_MS = 1200
const MAX_ICE_RESTART_ATTEMPTS = 2

export class WebRTCClient {
  constructor(socket, callId, userId, iceServers) {
    this.socket = socket
    this.callId = callId
    this.userId = userId
    this.iceServers = iceServers || []
    this.channel = null
    this.peerConnection = null
    this.localStream = null
    this.remoteStream = null
    this.onRemoteStreamCallback = null
    this.onCallEndedCallback = null
    this.onConnectionEstablishedCallback = null
    this.iceCandidateQueue = []
    this.remoteDescriptionSet = false
    this.pendingOffer = null
    this.disposed = false
    this.cleanupStarted = false
    this.callEndedNotified = false
    this.iceRestartAttempts = 0
    this.connectionEstablishedNotified = false
    this.iceRestartTimer = null
    this.onlineHandler = null
    this.offlineHandler = null
  }

  /**
   * Initialize the call channel and set up event handlers.
   */
  async initialize() {
    if (this.disposed) {
      throw new Error("Client already cleaned up")
    }

    this.channel = this.socket.channel(`call:${this.callId}`, {})
    this.setupChannelHandlers()
    this.setupNetworkHandlers()

    return new Promise((resolve, reject) => {
      this.channel
        .join()
        .receive("ok", () => {
          setTimeout(() => resolve(), CHANNEL_JOIN_DELAY_MS)
        })
        .receive("error", (resp) => {
          reject(new Error(resp?.reason || "Failed to join call channel"))
        })
        .receive("timeout", () => {
          reject(new Error("Call channel join timed out"))
        })
    })
  }

  /**
   * Set up Phoenix Channel event handlers for signaling.
   */
  setupChannelHandlers() {
    this.channel.on("peer_ready", async () => {
      await this.flushPendingOffer()
    })

    this.channel.on("offer", async ({ sdp }) => {
      try {
        await this.handleOffer(sdp)
      } catch (_error) {
        this.finishCall("failed")
      }
    })

    this.channel.on("answer", async ({ sdp }) => {
      try {
        await this.handleAnswer(sdp)
      } catch (_error) {
        this.finishCall("failed")
      }
    })

    this.channel.on("ice_candidate", async ({ candidate }) => {
      try {
        await this.handleIceCandidate(candidate)
      } catch (_error) {
        // Ignore malformed candidates from remote peer.
      }
    })

    this.channel.on("call_rejected", () => this.finishCall("rejected"))
    this.channel.on("call_ended", ({ reason }) => this.finishCall(reason || "ended"))
    this.channel.on("call_missed", () => this.finishCall("missed"))
  }

  setupNetworkHandlers() {
    if (this.onlineHandler || this.offlineHandler || typeof window === "undefined") {
      return
    }

    this.onlineHandler = () => {
      if (!this.disposed && this.peerConnection && this.remoteDescriptionSet) {
        this.scheduleIceRestart("network_recovered")
      }
    }

    this.offlineHandler = () => {
      if (!this.disposed) {
        this.finishCall("network_offline")
      }
    }

    window.addEventListener("online", this.onlineHandler)
    window.addEventListener("offline", this.offlineHandler)
  }

  teardownNetworkHandlers() {
    if (typeof window === "undefined") {
      return
    }

    if (this.onlineHandler) {
      window.removeEventListener("online", this.onlineHandler)
      this.onlineHandler = null
    }

    if (this.offlineHandler) {
      window.removeEventListener("offline", this.offlineHandler)
      this.offlineHandler = null
    }
  }

  /**
   * Create a new RTCPeerConnection.
   */
  createPeerConnection() {
    if (this.peerConnection) {
      return this.peerConnection
    }

    this.peerConnection = new RTCPeerConnection({ iceServers: this.iceServers })
    this.connectionEstablishedNotified = false

    this.peerConnection.onicecandidate = (event) => {
      if (event.candidate && this.channel && this.channel.state === "joined") {
        this.channel.push("ice_candidate", { candidate: event.candidate })
      }
    }

    this.peerConnection.ontrack = (event) => {
      if (!this.remoteStream) {
        this.remoteStream = new MediaStream()
      }
      this.remoteStream.addTrack(event.track)

      if (this.onRemoteStreamCallback) {
        this.onRemoteStreamCallback(this.remoteStream)
      }
    }

    this.peerConnection.onconnectionstatechange = () => {
      if (!this.peerConnection) {
        return
      }

      const state = this.peerConnection.connectionState

      if (state === "connected") {
        this.iceRestartAttempts = 0
        if (!this.connectionEstablishedNotified && this.onConnectionEstablishedCallback) {
          this.connectionEstablishedNotified = true
          this.onConnectionEstablishedCallback()
        }
      }

      if (state === "disconnected") {
        this.scheduleIceRestart("disconnected")
      }

      if (state === "failed") {
        this.scheduleIceRestart("failed")
      }
    }

    this.peerConnection.oniceconnectionstatechange = () => {
      if (!this.peerConnection) {
        return
      }

      const state = this.peerConnection.iceConnectionState
      if (state === "disconnected" || state === "failed") {
        this.scheduleIceRestart(state)
      }
    }

    return this.peerConnection
  }

  /**
   * Start a call as caller (create offer).
   */
  async startCall(callType = "video") {
    if (this.disposed) {
      throw new Error("Client already cleaned up")
    }

    await this.getUserMedia(callType)

    const peer = this.createPeerConnection()
    this.attachLocalTracks(peer)

    const offer = await peer.createOffer()
    await peer.setLocalDescription(offer)

    this.pendingOffer = offer
    await this.flushPendingOffer()
  }

  /**
   * Handle incoming offer (callee).
   */
  async handleOffer(offer) {
    if (!offer || typeof offer.sdp !== "string") {
      return
    }

    const callType = offer.sdp.includes("m=video") ? "video" : "audio"
    await this.getUserMedia(callType)

    const peer = this.createPeerConnection()
    this.attachLocalTracks(peer)

    await peer.setRemoteDescription(new RTCSessionDescription(offer))
    this.remoteDescriptionSet = true
    await this.processIceCandidateQueue()

    const answer = await peer.createAnswer()
    await peer.setLocalDescription(answer)

    if (this.channel && this.channel.state === "joined") {
      this.channel.push("answer", { sdp: answer })
    }
  }

  /**
   * Handle incoming answer (caller).
   */
  async handleAnswer(answer) {
    if (!this.peerConnection || !answer) {
      return
    }

    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(answer))
    this.remoteDescriptionSet = true
    await this.processIceCandidateQueue()
  }

  /**
   * Handle incoming ICE candidate.
   */
  async handleIceCandidate(candidate) {
    if (!candidate) {
      return
    }

    if (this.remoteDescriptionSet && this.peerConnection) {
      await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate))
      return
    }

    this.iceCandidateQueue.push(candidate)
  }

  /**
   * Process queued ICE candidates.
   */
  async processIceCandidateQueue() {
    if (!this.peerConnection) {
      this.iceCandidateQueue = []
      return
    }

    for (const candidate of this.iceCandidateQueue) {
      try {
        await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate))
      } catch (_error) {
        // Ignore stale/invalid candidate entries from race conditions.
      }
    }

    this.iceCandidateQueue = []
  }

  /**
   * Get user media (camera/microphone).
   */
  async getUserMedia(callType) {
    if (this.localStream) {
      return this.localStream
    }

    const constraints = {
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
        sampleRate: 48000,
        channelCount: 1
      },
      video:
        callType === "video"
          ? {
              width: { ideal: 1280 },
              height: { ideal: 720 },
              facingMode: "user"
            }
          : false
    }

    this.localStream = await navigator.mediaDevices.getUserMedia(constraints)
    return this.localStream
  }

  attachLocalTracks(peerConnection) {
    if (!this.localStream || !peerConnection) {
      return
    }

    const existingTrackIds = new Set(
      peerConnection
        .getSenders()
        .map((sender) => sender.track?.id)
        .filter(Boolean)
    )

    this.localStream.getTracks().forEach((track) => {
      if (!existingTrackIds.has(track.id)) {
        peerConnection.addTrack(track, this.localStream)
      }
    })
  }

  async flushPendingOffer() {
    if (!this.pendingOffer || !this.channel || this.channel.state !== "joined") {
      return
    }

    this.channel.push("offer", { sdp: this.pendingOffer })
    this.pendingOffer = null
  }

  scheduleIceRestart(_reason) {
    if (this.disposed || this.cleanupStarted || !this.peerConnection || !this.remoteDescriptionSet) {
      return
    }

    if (this.iceRestartAttempts >= MAX_ICE_RESTART_ATTEMPTS) {
      this.finishCall("failed")
      return
    }

    if (this.iceRestartTimer) {
      return
    }

    this.iceRestartTimer = window.setTimeout(async () => {
      this.iceRestartTimer = null
      await this.restartIce()
    }, ICE_RESTART_DELAY_MS)
  }

  async restartIce() {
    if (
      this.disposed ||
      this.cleanupStarted ||
      !this.peerConnection ||
      !this.channel ||
      this.channel.state !== "joined"
    ) {
      return
    }

    try {
      this.iceRestartAttempts += 1
      const offer = await this.peerConnection.createOffer({ iceRestart: true })
      await this.peerConnection.setLocalDescription(offer)
      this.channel.push("offer", { sdp: offer })
    } catch (_error) {
      if (this.iceRestartAttempts >= MAX_ICE_RESTART_ATTEMPTS) {
        this.finishCall("failed")
      }
    }
  }

  /**
   * Toggle video track.
   */
  toggleVideo() {
    if (this.localStream) {
      const videoTrack = this.localStream.getVideoTracks()[0]
      if (videoTrack) {
        videoTrack.enabled = !videoTrack.enabled
        return videoTrack.enabled
      }
    }
    return false
  }

  /**
   * Toggle audio track.
   */
  toggleAudio() {
    if (this.localStream) {
      const audioTrack = this.localStream.getAudioTracks()[0]
      if (audioTrack) {
        audioTrack.enabled = !audioTrack.enabled
        return audioTrack.enabled
      }
    }
    return false
  }

  /**
   * End the call.
   */
  endCall() {
    if (this.channel && this.channel.state === "joined") {
      this.channel.push("end_call", {})
    }
    this.cleanup()
  }

  /**
   * Reject the call.
   */
  rejectCall() {
    if (this.channel && this.channel.state === "joined") {
      this.channel.push("reject_call", {})
    }
    this.cleanup()
  }

  finishCall(reason) {
    this.cleanup()

    if (!this.callEndedNotified && this.onCallEndedCallback) {
      this.callEndedNotified = true
      this.onCallEndedCallback(reason || "ended")
    }
  }

  /**
   * Clean up resources.
   */
  cleanup() {
    if (this.cleanupStarted) {
      return
    }

    this.cleanupStarted = true
    this.disposed = true

    if (this.iceRestartTimer) {
      clearTimeout(this.iceRestartTimer)
      this.iceRestartTimer = null
    }

    this.teardownNetworkHandlers()

    if (this.localStream) {
      this.localStream.getTracks().forEach((track) => track.stop())
      this.localStream = null
    }

    if (this.peerConnection) {
      this.peerConnection.onicecandidate = null
      this.peerConnection.ontrack = null
      this.peerConnection.onconnectionstatechange = null
      this.peerConnection.oniceconnectionstatechange = null
      this.peerConnection.close()
      this.peerConnection = null
    }

    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }

    if (this.socket) {
      this.socket.disconnect()
    }

    this.remoteStream = null
    this.pendingOffer = null
    this.iceCandidateQueue = []
    this.remoteDescriptionSet = false
  }

  /**
   * Set callback for when remote stream is received.
   */
  onRemoteStream(callback) {
    this.onRemoteStreamCallback = callback
  }

  /**
   * Set callback for when call ends.
   */
  onCallEnded(callback) {
    this.onCallEndedCallback = callback
  }

  /**
   * Set callback for when connection is established.
   */
  onConnectionEstablished(callback) {
    this.onConnectionEstablishedCallback = callback
  }

  /**
   * Get local stream.
   */
  getLocalStream() {
    return this.localStream
  }

  /**
   * Get remote stream.
   */
  getRemoteStream() {
    return this.remoteStream
  }
}
