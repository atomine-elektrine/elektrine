import { svg, setAttributes } from "./proof_graph_dom"

function sanitizeId(value) {
  return String(value || "")
    .trim()
    .replace(/[^a-zA-Z0-9_-]/g, "-")
}

function hashString(value) {
  return Array.from(value || "").reduce((acc, char) => acc * 31 + char.charCodeAt(0), 7)
}

function createGradient(id, tagName, attrs, stops) {
  const gradient = svg(tagName)
  setAttributes(gradient, { id, ...attrs })

  stops.forEach((stopConfig) => {
    const stop = svg("stop")
    setAttributes(stop, { offset: stopConfig.offset, "stop-color": stopConfig.color })

    if (stopConfig.opacity !== undefined) {
      setAttributes(stop, { "stop-opacity": stopConfig.opacity })
    }

    gradient.appendChild(stop)
  })

  return gradient
}

export function paletteForNode(node) {
  const seed = Math.abs(hashString(node.id || node.label || "node"))
  const hue = seed % 360
  const hueShift = (hue + 26 + (seed % 19)) % 360
  const saturation = node.kind === "subject" ? 88 : 78
  const lightness = node.kind === "subject" ? 66 : 60

  return {
    accent: `hsl(${hue}, ${saturation}%, ${lightness}%)`,
    stroke: `hsla(${hue}, ${Math.min(saturation + 6, 96)}%, ${Math.max(lightness - 6, 40)}%, 0.96)`,
    ring: `hsla(${hue}, 95%, 85%, ${node.kind === "subject" ? 0.92 : 0.76})`,
    glow: `hsla(${hue}, 96%, 70%, ${node.kind === "subject" ? 0.34 : 0.22})`,
    fillTop: `hsla(${hue}, 56%, ${node.kind === "subject" ? 28 : 18}%, 0.96)`,
    fillBottom: `hsla(${hueShift}, 62%, 10%, 0.98)`,
    washTop: `hsla(${hue}, 94%, 76%, ${node.kind === "subject" ? 0.18 : 0.14})`,
    washBottom: `hsla(${hueShift}, 88%, 58%, ${node.kind === "subject" ? 0.24 : 0.2})`,
    text: "rgba(248, 250, 252, 0.98)",
    subtitle: "rgba(226, 232, 240, 0.82)"
  }
}

export function createNodePaints(defs, node, palette) {
  const safeId = sanitizeId(node.id)
  const fillId = `proof-node-fill-${safeId}`
  const washId = `proof-node-wash-${safeId}`
  const glazeId = `proof-node-glaze-${safeId}`
  let avatarClipId = null
  let avatarRadius = null

  if (node.avatar_url) {
    avatarClipId = `proof-node-avatar-clip-${safeId}`
    avatarRadius = Math.max(node.radius - (node.kind === "subject" ? 6 : 4), 0)
    const avatarClip = svg("clipPath")
    const avatarClipCircle = svg("circle")

    setAttributes(avatarClip, {
      id: avatarClipId
    })

    setAttributes(avatarClipCircle, {
      r: avatarRadius
    })

    avatarClip.appendChild(avatarClipCircle)
    defs.appendChild(avatarClip)
  }

  defs.appendChild(
    createGradient(fillId, "linearGradient", { x1: "0%", y1: "0%", x2: "100%", y2: "100%" }, [
      { offset: "0%", color: palette.fillTop },
      { offset: "100%", color: palette.fillBottom }
    ])
  )

  defs.appendChild(
    createGradient(washId, "linearGradient", { x1: "0%", y1: "0%", x2: "0%", y2: "100%" }, [
      { offset: "0%", color: node.avatar_url ? "rgba(255, 255, 255, 0.04)" : palette.washTop },
      { offset: "45%", color: node.avatar_url ? "rgba(15, 23, 42, 0.08)" : palette.washTop },
      { offset: "100%", color: node.avatar_url ? "rgba(2, 6, 23, 0.62)" : palette.washBottom }
    ])
  )

  defs.appendChild(
    createGradient(glazeId, "radialGradient", { cx: "32%", cy: "24%", r: "82%" }, [
      { offset: "0%", color: palette.accent, opacity: node.avatar_url ? 0.18 : 0.3 },
      { offset: "36%", color: "#ffffff", opacity: node.avatar_url ? 0.1 : 0.18 },
      { offset: "100%", color: "#ffffff", opacity: 0 }
    ])
  )

  return {
    fill: `url(#${fillId})`,
    wash: `url(#${washId})`,
    glaze: `url(#${glazeId})`,
    avatarClipId,
    avatarRadius
  }
}

export function createGraphDefs() {
  const defs = svg("defs")

  defs.appendChild(
    createGradient(
      "proof-node-gradient-surface",
      "linearGradient",
      { x1: "0%", y1: "0%", x2: "100%", y2: "100%" },
      [
        { offset: "0%", color: "var(--proof-node-surface-top)" },
        { offset: "100%", color: "var(--proof-node-surface-bottom)" }
      ]
    )
  )

  defs.appendChild(
    createGradient(
      "proof-node-gradient-primary",
      "linearGradient",
      { x1: "0%", y1: "0%", x2: "100%", y2: "100%" },
      [
        { offset: "0%", color: "var(--proof-accent-bright)" },
        { offset: "100%", color: "var(--proof-accent-strong)" }
      ]
    )
  )

  defs.appendChild(
    createGradient(
      "proof-node-gradient-ink",
      "linearGradient",
      { x1: "0%", y1: "0%", x2: "100%", y2: "100%" },
      [
        { offset: "0%", color: "rgba(15, 23, 42, 0.96)" },
        { offset: "100%", color: "rgba(30, 41, 59, 0.96)" }
      ]
    )
  )

  defs.appendChild(
    createGradient(
      "proof-node-tint-neutral",
      "linearGradient",
      { x1: "0%", y1: "0%", x2: "100%", y2: "100%" },
      [
        { offset: "0%", color: "var(--proof-neutral-tint)" },
        { offset: "46%", color: "var(--proof-ink-wash)" },
        { offset: "100%", color: "#ffffff", opacity: 0 }
      ]
    )
  )

  defs.appendChild(
    createGradient(
      "proof-node-tint-accent",
      "linearGradient",
      { x1: "0%", y1: "0%", x2: "100%", y2: "100%" },
      [
        { offset: "0%", color: "var(--proof-accent-soft)" },
        { offset: "46%", color: "var(--proof-ink-wash)" },
        { offset: "100%", color: "#ffffff", opacity: 0 }
      ]
    )
  )

  defs.appendChild(
    createGradient(
      "proof-node-tint-primary",
      "linearGradient",
      { x1: "0%", y1: "0%", x2: "100%", y2: "100%" },
      [
        { offset: "0%", color: "var(--proof-accent-text-wash)" },
        { offset: "52%", color: "rgba(255, 255, 255, 0.06)" },
        { offset: "100%", color: "#ffffff", opacity: 0 }
      ]
    )
  )

  defs.appendChild(
    createGradient(
      "proof-node-gloss",
      "radialGradient",
      { cx: "28%", cy: "24%", r: "82%" },
      [
        { offset: "0%", color: "#ffffff", opacity: 0.24 },
        { offset: "38%", color: "#ffffff", opacity: 0.12 },
        { offset: "100%", color: "#ffffff", opacity: 0 }
      ]
    )
  )

  defs.appendChild(
    createGradient(
      "proof-node-gloss-primary",
      "radialGradient",
      { cx: "30%", cy: "22%", r: "84%" },
      [
        { offset: "0%", color: "#ffffff", opacity: 0.3 },
        { offset: "42%", color: "#ffffff", opacity: 0.14 },
        { offset: "100%", color: "#ffffff", opacity: 0 }
      ]
    )
  )

  return defs
}
