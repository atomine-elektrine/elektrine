export const CLUSTERS = {
  core: { radius: 0, angle: -90, spread: 0 },
  trust: { radius: 0.28, angle: -88, spread: 18 },
  age: { radius: 0.28, angle: 88, spread: 18 },
  invite: { radius: 0.44, angle: 188, spread: 52 },
  invitee: { radius: 0.63, angle: 214, spread: 88 },
  followers: { radius: 0.58, angle: -18, spread: 94 },
  following: { radius: 0.58, angle: 58, spread: 94 }
}

export const EDGE_COLORS = {
  trust: "var(--proof-edge-strong)",
  signal: "var(--proof-edge-muted)",
  network: "var(--proof-edge-soft)",
  invite: "var(--proof-edge-accent)",
  follow: "var(--proof-edge-muted)"
}

export const EDGE_DASHARRAY = {
  signal: "4 12",
  network: "8 14",
  invite: "10 10",
  follow: "5 10"
}

export const USER_NODE_KINDS = new Set(["subject", "inviter", "invitee", "follower", "following"])

export const NODE_STYLES = {
  subject: {
    fill: "url(#proof-node-gradient-primary)",
    stroke: "var(--proof-accent-strong)",
    ring: "var(--proof-accent-text-soft)",
    wash: "url(#proof-node-tint-primary)",
    washOpacity: 0.12,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow)",
    haloOpacity: 0.24,
    glaze: "url(#proof-node-gloss-primary)",
    glazeOpacity: 0.08
  },
  trust: {
    fill: "url(#proof-node-gradient-ink)",
    stroke: "var(--proof-accent)",
    ring: "var(--proof-accent-soft)",
    wash: "url(#proof-node-tint-accent)",
    washOpacity: 0.16,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow-soft)",
    haloOpacity: 0.08
  },
  signal: {
    fill: "url(#proof-node-gradient-ink)",
    stroke: "var(--proof-node-border-soft)",
    ring: "var(--proof-node-border-soft)",
    wash: "url(#proof-node-tint-neutral)",
    washOpacity: 0.12,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow-soft)",
    haloOpacity: 0.06
  },
  aggregate: {
    fill: "url(#proof-node-gradient-ink)",
    stroke: "var(--proof-accent-soft)",
    ring: "var(--proof-accent-soft)",
    wash: "url(#proof-node-tint-accent)",
    washOpacity: 0.14,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow-soft)",
    haloOpacity: 0.08
  },
  inviter: {
    fill: "url(#proof-node-gradient-ink)",
    stroke: "var(--proof-accent-soft)",
    ring: "var(--proof-accent-soft)",
    wash: "url(#proof-node-tint-accent)",
    washOpacity: 0.14,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow-soft)",
    haloOpacity: 0.08
  },
  invitee: {
    fill: "url(#proof-node-gradient-ink)",
    stroke: "var(--proof-accent-soft)",
    ring: "var(--proof-accent-soft)",
    wash: "url(#proof-node-tint-accent)",
    washOpacity: 0.14,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow-soft)",
    haloOpacity: 0.08
  },
  follower: {
    fill: "url(#proof-node-gradient-ink)",
    stroke: "var(--proof-node-border-soft)",
    ring: "var(--proof-node-border-soft)",
    wash: "url(#proof-node-tint-neutral)",
    washOpacity: 0.12,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow-soft)",
    haloOpacity: 0.06
  },
  following: {
    fill: "url(#proof-node-gradient-ink)",
    stroke: "var(--proof-node-border-soft)",
    ring: "var(--proof-node-border-soft)",
    wash: "url(#proof-node-tint-neutral)",
    washOpacity: 0.12,
    text: "var(--proof-node-text-inverse)",
    subtitle: "var(--proof-node-subtle-inverse)",
    halo: "var(--proof-glow-soft)",
    haloOpacity: 0.06
  }
}
