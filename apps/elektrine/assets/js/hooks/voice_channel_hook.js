/**
 * LiveView hook for community voice channels (full-mesh WebRTC audio).
 *
 * The LiveView pushes "voice_join" / "voice_leave" / "voice_toggle_mute"
 * events; this hook owns the media session: one Phoenix channel on
 * `voice:<conversation_id>`, one RTCPeerConnection per remote occupant, and
 * one hidden <audio> element per remote stream (appended to the hook root).
 *
 * Initiator rule: for each pair of peers, the one with the greater
 * (joined_at, user_id) presence tuple initiates the offer. Newcomers
 * therefore offer to everyone already present, and concurrent joins are
 * broken deterministically without glare.
 */

import { Socket } from "phoenix"

function mapMediaError(error) {
  if (!error) return "Unable to access microphone."

  const message = error.message || "Unable to access microphone."

  if (error.name === "NotAllowedError" || message.includes("Permission denied")) {
    return "Microphone access denied. Please allow access in your browser settings and try again."
  }

  if (error.name === "NotFoundError") {
    return "No microphone found. Please connect one and try again."
  }

  if (message.includes("secure origin")) {
    return "Voice channels require HTTPS. Please use a secure connection."
  }

  return message
}

export const VoiceChannel = {
  mounted() {
    this.session = null

    this.handleEvent("voice_join", (payload) => {
      this.join(payload)
    })

    this.handleEvent("voice_leave", () => {
      this.teardown()
      this.safePushEvent("voice_left", {})
    })

    this.handleEvent("voice_toggle_mute", () => {
      this.toggleMute()
    })
  },

  destroyed() {
    this.teardown()
  },

  // The LiveView loses its assigns on reconnect while the media session (on
  // its own socket) keeps running; re-sync the connected bar state.
  reconnected() {
    const session = this.session

    if (session) {
      this.safePushEvent("voice_rejoined", {
        conversation_id: session.conversationId,
        muted: session.muted,
      })
    }
  },

  safePushEvent(event, payload) {
    try {
      this.pushEvent(event, payload)
    } catch (_error) {
      // Hook may already be detached (e.g. navigation away).
    }
  },

  async join({ conversation_id, user_id, user_token, ice_servers }) {
    this.teardown()

    let localStream
    try {
      localStream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (error) {
      this.safePushEvent("voice_error", { reason: mapMediaError(error) })
      return
    }

    const socket = new Socket("/socket", { params: { token: user_token } })
    socket.connect()

    const channel = socket.channel(`voice:${conversation_id}`, {})

    this.session = {
      conversationId: conversation_id,
      userId: user_id,
      iceServers: ice_servers || [],
      socket,
      channel,
      localStream,
      peers: new Map(),
      myJoinedAt: Infinity,
      muted: false,
    }

    channel.on("presence_state", (state) => this.handlePresenceState(state))
    channel.on("presence_diff", (diff) => this.handlePresenceDiff(diff))
    channel.on("signal", (payload) => this.handleSignal(payload))

    channel
      .join()
      .receive("ok", () => {
        this.safePushEvent("voice_joined", { conversation_id })
      })
      .receive("error", (resp) => {
        this.teardown()
        this.safePushEvent("voice_error", { reason: resp?.reason || "join_failed" })
      })
      .receive("timeout", () => {
        this.teardown()
        this.safePushEvent("voice_error", { reason: "Connection timed out" })
      })
  },

  presenceEntries(state) {
    return Object.entries(state || {}).map(([key, value]) => {
      const meta = (value.metas && value.metas[0]) || {}
      return {
        userId: meta.user_id || parseInt(key, 10),
        joinedAt: meta.joined_at ?? 0,
      }
    })
  },

  // True when the remote peer's presence tuple sorts before ours, meaning we
  // are the newer side of the pair and must initiate the offer.
  shouldInitiateTo(peer) {
    const session = this.session
    if (!session) return false

    if (peer.joinedAt !== session.myJoinedAt) {
      return peer.joinedAt < session.myJoinedAt
    }

    return peer.userId < session.userId
  },

  handlePresenceState(state) {
    const session = this.session
    if (!session) return

    const entries = this.presenceEntries(state)
    const me = entries.find((entry) => entry.userId === session.userId)

    if (me) {
      session.myJoinedAt = me.joinedAt
    }

    entries
      .filter((entry) => entry.userId !== session.userId)
      .filter((entry) => this.shouldInitiateTo(entry))
      .forEach((entry) => {
        this.createPeer(entry.userId, true)
      })
  },

  handlePresenceDiff(diff) {
    const session = this.session
    if (!session) return

    const joins = diff?.joins || {}
    const leaves = diff?.leaves || {}

    // Presence meta updates (e.g. mute) emit the same key in joins+leaves.
    Object.keys(leaves).forEach((key) => {
      if (key in joins) return

      const meta = (leaves[key].metas && leaves[key].metas[0]) || {}
      const userId = meta.user_id || parseInt(key, 10)

      if (userId !== session.userId) {
        this.closePeer(userId)
      }
    })

    // Concurrent joiners may not have been in our presence_state snapshot;
    // if their tuple sorts before ours we still own the offer.
    this.presenceEntries(joins)
      .filter((entry) => entry.userId !== session.userId)
      .filter((entry) => !session.peers.has(entry.userId))
      .filter((entry) => this.shouldInitiateTo(entry))
      .forEach((entry) => {
        this.createPeer(entry.userId, true)
      })
  },

  getOrCreatePeer(peerId) {
    const session = this.session
    if (!session) return null

    if (session.peers.has(peerId)) {
      return session.peers.get(peerId)
    }

    const pc = new RTCPeerConnection({ iceServers: session.iceServers })
    const peer = { pc, audioEl: null, pendingCandidates: [] }

    session.localStream.getTracks().forEach((track) => {
      pc.addTrack(track, session.localStream)
    })

    pc.onicecandidate = (event) => {
      if (event.candidate) {
        this.pushSignal(peerId, "ice", event.candidate.toJSON())
      }
    }

    pc.ontrack = (event) => {
      const stream = event.streams[0] || new MediaStream([event.track])
      this.attachAudio(peer, peerId, stream)
    }

    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "failed" || pc.connectionState === "closed") {
        this.closePeer(peerId)
      }
    }

    session.peers.set(peerId, peer)
    return peer
  },

  async createPeer(peerId, initiator) {
    const peer = this.getOrCreatePeer(peerId)
    if (!peer || !initiator) return

    try {
      const offer = await peer.pc.createOffer()
      await peer.pc.setLocalDescription(offer)
      this.pushSignal(peerId, "offer", peer.pc.localDescription.toJSON())
    } catch (_error) {
      this.closePeer(peerId)
    }
  },

  pushSignal(peerId, kind, payload) {
    const channel = this.session?.channel

    if (channel && channel.state === "joined") {
      channel.push("signal", { to: peerId, kind, payload })
    }
  },

  async handleSignal({ from, kind, payload }) {
    const session = this.session
    if (!session || from === session.userId) return

    try {
      if (kind === "offer") {
        await this.handleOffer(from, payload)
      } else if (kind === "answer") {
        await this.handleAnswer(from, payload)
      } else if (kind === "ice") {
        await this.handleRemoteCandidate(from, payload)
      }
    } catch (_error) {
      // A broken negotiation with one peer should not take the session down.
    }
  },

  async handleOffer(peerId, sdp) {
    const peer = this.getOrCreatePeer(peerId)
    if (!peer) return

    await peer.pc.setRemoteDescription(new RTCSessionDescription(sdp))
    await this.flushCandidates(peer)

    const answer = await peer.pc.createAnswer()
    await peer.pc.setLocalDescription(answer)
    this.pushSignal(peerId, "answer", peer.pc.localDescription.toJSON())
  },

  async handleAnswer(peerId, sdp) {
    const peer = this.session?.peers.get(peerId)
    if (!peer) return

    await peer.pc.setRemoteDescription(new RTCSessionDescription(sdp))
    await this.flushCandidates(peer)
  },

  async handleRemoteCandidate(peerId, candidate) {
    const peer = this.getOrCreatePeer(peerId)
    if (!peer) return

    if (peer.pc.remoteDescription) {
      await peer.pc.addIceCandidate(new RTCIceCandidate(candidate))
    } else {
      peer.pendingCandidates.push(candidate)
    }
  },

  async flushCandidates(peer) {
    const pending = peer.pendingCandidates.splice(0)

    for (const candidate of pending) {
      try {
        await peer.pc.addIceCandidate(new RTCIceCandidate(candidate))
      } catch (_error) {
        // Ignore malformed candidates from a remote peer.
      }
    }
  },

  attachAudio(peer, peerId, stream) {
    if (!peer.audioEl) {
      const audio = document.createElement("audio")
      audio.id = `voice-audio-${peerId}`
      audio.autoplay = true
      this.el.appendChild(audio)
      peer.audioEl = audio
    }

    peer.audioEl.srcObject = stream
    peer.audioEl.play().catch(() => {})
  },

  closePeer(peerId) {
    const peer = this.session?.peers.get(peerId)
    if (!peer) return

    this.session.peers.delete(peerId)

    try {
      peer.pc.onicecandidate = null
      peer.pc.ontrack = null
      peer.pc.onconnectionstatechange = null
      peer.pc.close()
    } catch (_error) {
      // Already closed.
    }

    if (peer.audioEl) {
      peer.audioEl.srcObject = null
      peer.audioEl.remove()
    }
  },

  toggleMute() {
    const session = this.session
    if (!session) return

    session.muted = !session.muted

    session.localStream.getAudioTracks().forEach((track) => {
      track.enabled = !session.muted
    })

    if (session.channel && session.channel.state === "joined") {
      session.channel.push("set_muted", { muted: session.muted })
    }

    this.safePushEvent("voice_mute_changed", { muted: session.muted })
  },

  teardown() {
    const session = this.session
    if (!session) return

    this.session = null

    Array.from(session.peers.keys()).forEach((peerId) => {
      const peer = session.peers.get(peerId)
      session.peers.delete(peerId)

      try {
        peer.pc.close()
      } catch (_error) {
        // Already closed.
      }

      if (peer.audioEl) {
        peer.audioEl.srcObject = null
        peer.audioEl.remove()
      }
    })

    session.localStream?.getTracks().forEach((track) => track.stop())

    try {
      session.channel?.leave()
    } catch (_error) {
      // Channel may never have joined.
    }

    try {
      session.socket?.disconnect()
    } catch (_error) {
      // Socket may never have connected.
    }
  },
}
