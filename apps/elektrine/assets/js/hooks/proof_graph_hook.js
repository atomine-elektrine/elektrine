import { CLUSTERS, EDGE_COLORS, EDGE_DASHARRAY, NODE_STYLES, USER_NODE_KINDS } from "./proof_graph_styles"
import { createGraphDefs, createNodePaints, paletteForNode } from "./proof_graph_paints"
import { svg, setAttributes, setImageHref } from "./proof_graph_dom"

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

function trimText(value, maxLength = 15) {
  if (!value || value.length <= maxLength) return value || ""
  return `${value.slice(0, maxLength - 3)}...`
}

function isUserNode(node) {
  return USER_NODE_KINDS.has(node.kind)
}

function labelMaxLength(node) {
  if (node.kind === "subject") return 12
  if (isUserNode(node)) return 8
  if (node.kind === "aggregate") return 5
  if (node.kind === "trust") return 6
  return 8
}

function subtitleMaxLength(node) {
  if (node.kind === "subject") return 16
  if (isUserNode(node)) return 0
  return 10
}

function layoutForNode(node) {
  if (node.kind === "subject") {
    return {
      labelY: 10,
      subtitleY: 26,
      labelFontSize: 12,
      subtitleFontSize: 8,
      showSubtitle: true
    }
  }

  if (isUserNode(node)) {
    return {
      labelY: 3,
      subtitleY: 0,
      labelFontSize: 9,
      subtitleFontSize: 0,
      showSubtitle: false
    }
  }

  return {
    labelY: -1,
    subtitleY: 13,
    labelFontSize: node.kind === "aggregate" ? 12 : 11,
    subtitleFontSize: 8,
    showSubtitle: true
  }
}

function hashString(value) {
  return Array.from(value || "").reduce((acc, char) => acc * 31 + char.charCodeAt(0), 7)
}

function polarToCartesian(centerX, centerY, radius, angleDeg, yScale = 0.82) {
  const angle = (angleDeg * Math.PI) / 180
  return {
    x: centerX + Math.cos(angle) * radius,
    y: centerY + Math.sin(angle) * radius * yScale
  }
}

function buildEdgePath(source, target, bend) {
  const midX = (source.x + target.x) / 2
  const midY = (source.y + target.y) / 2
  const deltaX = target.x - source.x
  const deltaY = target.y - source.y
  const length = Math.hypot(deltaX, deltaY) || 1
  const normalX = -deltaY / length
  const normalY = deltaX / length
  const controlX = midX + normalX * bend
  const controlY = midY + normalY * bend
  return `M ${source.x} ${source.y} Q ${controlX} ${controlY} ${target.x} ${target.y}`
}

function parseGraphPayload(el) {
  const raw = el.dataset.graph
  if (!raw) return null

  try {
    return JSON.parse(raw)
  } catch (_error) {
    return null
  }
}

function createSceneState(graph, bounds) {
  const center = { x: bounds.width / 2, y: bounds.height / 2 }
  const graphRadius = Math.min(bounds.width, bounds.height) * 0.38
  const nodesByCluster = new Map()

  graph.nodes.forEach((node) => {
    if (!nodesByCluster.has(node.cluster)) nodesByCluster.set(node.cluster, [])
    nodesByCluster.get(node.cluster).push(node)
  })

  const nodes = graph.nodes.map((node) => {
    const config = CLUSTERS[node.cluster] || CLUSTERS.followers
    const clusterNodes = nodesByCluster.get(node.cluster) || [node]
    const index = clusterNodes.findIndex((entry) => entry.id === node.id)
    const spread = config.spread || 0
    const step = clusterNodes.length > 1 ? spread / (clusterNodes.length - 1) : 0
    const startAngle = config.angle - spread / 2
    const angle = clusterNodes.length > 1 ? startAngle + step * index : config.angle
    const anchor =
      node.cluster === "core"
        ? { ...center }
        : polarToCartesian(center.x, center.y, graphRadius * config.radius, angle)
    const seed = hashString(node.id)
    const radius =
      node.kind === "subject"
        ? 54
        : node.kind === "aggregate"
          ? 35 + Math.round((node.weight || 0.6) * 10)
          : 28 + Math.round((node.weight || 0.6) * 8)

    return {
      ...node,
      anchorX: anchor.x,
      anchorY: anchor.y,
      x: anchor.x + ((seed % 13) - 6) * 2.6,
      y: anchor.y + ((seed % 17) - 8) * 2.2,
      vx: 0,
      vy: 0,
      radius,
      seed,
      driftOffset: (seed % 360) * (Math.PI / 180),
      depth: node.cluster === "core" ? 0 : config.radius
    }
  })

  const nodeById = new Map(nodes.map((node) => [node.id, node]))

  const edges = graph.edges
    .map((edge) => ({
      ...edge,
      sourceNode: nodeById.get(edge.source),
      targetNode: nodeById.get(edge.target)
    }))
    .filter((edge) => edge.sourceNode && edge.targetNode)

  return { center, graphRadius, nodes, edges }
}

function createEdgeElement(edge) {
  const path = svg("path")
  const color = EDGE_COLORS[edge.kind] || "#64748b"
  setAttributes(path, {
    fill: "none",
    stroke: color,
    "stroke-width": edge.kind === "trust" ? 2.8 : 2.1,
    "stroke-linecap": "round",
    "stroke-dasharray": EDGE_DASHARRAY[edge.kind] || null,
    opacity: 0.34
  })
  return path
}

function createNodeElements(node) {
  const group = svg("g")
  const halo = svg("circle")
  const body = svg("circle")
  const avatar = node.avatar_url ? svg("image") : null
  const wash = svg("circle")
  const glaze = svg("circle")
  const ring = svg("circle")
  const labelText = svg("text")
  const subtitleText = svg("text")
  const style = NODE_STYLES[node.kind] || NODE_STYLES.signal
  const layout = layoutForNode(node)
  const palette = paletteForNode(node)
  const paints = createNodePaints(this.defs, node, palette)

  group.style.cursor = node.href ? "pointer" : "grab"

  setAttributes(halo, {
    r: node.radius + 16,
    fill: palette.glow,
    opacity: style.haloOpacity ?? (node.kind === "subject" ? 0.3 : 0.08),
    "pointer-events": "none"
  })

  setAttributes(body, {
    r: node.radius,
    fill: paints.fill,
    stroke: palette.stroke,
    "stroke-width": node.kind === "subject" ? 2.8 : 2.2,
    filter: "drop-shadow(0 16px 28px var(--proof-shadow))",
    "pointer-events": "none"
  })

  if (avatar && paints.avatarRadius && paints.avatarClipId) {
    setAttributes(avatar, {
      x: -paints.avatarRadius,
      y: -paints.avatarRadius,
      width: paints.avatarRadius * 2,
      height: paints.avatarRadius * 2,
      preserveAspectRatio: "xMidYMid slice",
      "clip-path": `url(#${paints.avatarClipId})`,
      "pointer-events": "none"
    })

    setImageHref(avatar, node.avatar_url)
  }

  setAttributes(wash, {
    r: Math.max(node.radius - 1.5, 0),
    fill: paints.wash,
    opacity: node.avatar_url ? 0.82 : style.washOpacity ?? 0.84,
    "pointer-events": "none"
  })

  setAttributes(glaze, {
    r: Math.max(node.radius - 4, 0),
    fill: paints.glaze,
    opacity: node.avatar_url ? 0.72 : style.glazeOpacity ?? 0.3,
    "pointer-events": "none"
  })

  setAttributes(ring, {
    r: Math.max(node.radius - (node.kind === "subject" ? 5 : 4), 0),
    fill: "none",
    stroke: palette.ring,
    "stroke-width": node.kind === "subject" ? 1.4 : 1.15,
    opacity: node.kind === "subject" ? 0.9 : 0.72,
    "pointer-events": "none"
  })

  labelText.textContent = trimText(node.label, labelMaxLength(node))
  setAttributes(labelText, {
    "text-anchor": "middle",
    y: layout.labelY,
    "font-size": layout.labelFontSize,
    "font-weight": node.kind === "subject" ? "800" : "700",
    fill: palette.text,
    "pointer-events": "none"
  })
  labelText.style.filter = "drop-shadow(0 2px 8px rgba(2, 6, 23, 0.9))"

  subtitleText.textContent = layout.showSubtitle ? trimText(node.subtitle, subtitleMaxLength(node)) : ""
  setAttributes(subtitleText, {
    "text-anchor": "middle",
    y: layout.subtitleY,
    "font-size": layout.subtitleFontSize,
    "font-weight": "600",
    "letter-spacing": "0.08em",
    fill: palette.subtitle,
    opacity: layout.showSubtitle ? 0.98 : 0,
    "pointer-events": "none"
  })
  subtitleText.style.filter = "drop-shadow(0 2px 6px rgba(2, 6, 23, 0.8))"

  group.appendChild(halo)
  group.appendChild(body)
  if (avatar) group.appendChild(avatar)
  group.appendChild(wash)
  group.appendChild(glaze)
  group.appendChild(ring)
  group.appendChild(labelText)
  group.appendChild(subtitleText)

  return { group, halo, body, avatar, wash, glaze, ring, labelText, subtitleText }
}

function showTooltip(tooltip, event, node) {
  if (!tooltip) return

  const title = document.createElement("div")
  title.className = "font-semibold text-slate-950"
  title.textContent = node.label || ""

  const children = [title]
  const subtitleText = node.subtitle || ""

  if (subtitleText) {
    const subtitle = document.createElement("div")
    subtitle.className = "mt-1 text-slate-600"
    subtitle.textContent = subtitleText
    children.push(subtitle)
  }

  tooltip.replaceChildren(...children)
  tooltip.style.left = `${event.offsetX + 18}px`
  tooltip.style.top = `${event.offsetY + 18}px`
  tooltip.classList.remove("hidden")
}

function hideTooltip(tooltip) {
  if (!tooltip) return
  tooltip.classList.add("hidden")
}

export const ProofGraph = {
  mounted() {
    this.canvas = this.el.querySelector('[data-role="graph-canvas"]')
    this.tooltip = this.el.querySelector('[data-role="graph-tooltip"]')
    this.lastGraphJson = null
    this.pointer = null
    this.draggedNode = null
    this.dragMoved = false
    this.highlightedNodeId = null
    this.renderGraph()
  },

  updated() {
    const rawGraph = this.el.dataset.graph || ""
    if (rawGraph !== this.lastGraphJson) {
      this.renderGraph()
    }
  },

  destroyed() {
    this.teardownScene()
  },

  renderGraph() {
    const graph = parseGraphPayload(this.el)
    if (!graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return

    this.teardownScene()

    this.lastGraphJson = this.el.dataset.graph || ""
    this.graph = graph
    this.svg = svg("svg")
    setAttributes(this.svg, {
      width: "100%",
      height: "100%",
      viewBox: `0 0 ${this.el.clientWidth || 1200} ${this.el.clientHeight || 620}`,
      "aria-label": "Interactive proof graph"
    })
    this.svg.style.display = "block"

    this.defs = createGraphDefs()
    this.edgeLayer = svg("g")
    this.nodeLayer = svg("g")
    this.svg.appendChild(this.defs)
    this.svg.appendChild(this.edgeLayer)
    this.svg.appendChild(this.nodeLayer)
    const mountTarget = this.canvas || this.el
    mountTarget.appendChild(this.svg)

    this.scene = createSceneState(graph, {
      width: Math.max(this.el.clientWidth, 320),
      height: Math.max(this.el.clientHeight, 420)
    })

    this.scene.edges.forEach((edge) => {
      edge.element = createEdgeElement(edge)
      this.edgeLayer.appendChild(edge.element)
    })

    this.scene.nodes.forEach((node) => {
      const elements = createNodeElements.call(this, node)
      Object.assign(node, elements)
      this.nodeLayer.appendChild(node.group)

      node.group.addEventListener("pointerenter", (event) => {
        this.highlightedNodeId = node.id
        showTooltip(this.tooltip, event, node)
      })

      node.group.addEventListener("pointerleave", () => {
        this.highlightedNodeId = null
        hideTooltip(this.tooltip)
      })

      node.group.addEventListener("pointermove", (event) => {
        if (this.highlightedNodeId === node.id) showTooltip(this.tooltip, event, node)
      })

      node.group.addEventListener("pointerdown", (event) => {
        event.preventDefault()
        this.draggedNode = node
        this.dragMoved = false
        node.group.setPointerCapture(event.pointerId)
      })

      node.group.addEventListener("pointerup", (event) => {
        const clickTarget = !this.dragMoved && node.href
        this.draggedNode = null
        this.dragMoved = false
        if (clickTarget) window.location.assign(node.href)
        if (node.group.hasPointerCapture(event.pointerId)) {
          node.group.releasePointerCapture(event.pointerId)
        }
      })
    })

    this.pointerMoveHandler = (event) => {
      const rect = this.el.getBoundingClientRect()
      const point = {
        x: clamp(event.clientX - rect.left, 0, rect.width),
        y: clamp(event.clientY - rect.top, 0, rect.height)
      }

      this.pointer = point

      if (this.draggedNode) {
        this.dragMoved = true
        this.draggedNode.x = point.x
        this.draggedNode.y = point.y
        this.draggedNode.vx = 0
        this.draggedNode.vy = 0
      }
    }

    this.pointerLeaveHandler = () => {
      this.pointer = null
      if (!this.draggedNode) hideTooltip(this.tooltip)
    }

    this.el.addEventListener("pointermove", this.pointerMoveHandler)
    this.el.addEventListener("pointerleave", this.pointerLeaveHandler)

    this.resizeObserver = new ResizeObserver(() => {
      const nextWidth = Math.max(this.el.clientWidth, 320)
      const nextHeight = Math.max(this.el.clientHeight, 420)
      setAttributes(this.svg, { viewBox: `0 0 ${nextWidth} ${nextHeight}` })
      this.reconcileSceneNodes()
    })
    this.resizeObserver.observe(this.el)

    this.animate = this.animate.bind(this)
    this.frame = window.requestAnimationFrame(this.animate)
  },

  reconcileSceneNodes() {
    const oldNodes = new Map((this.scene?.nodes || []).map((node) => [node.id, node]))
    this.scene = createSceneState(this.graph, {
      width: Math.max(this.el.clientWidth, 320),
      height: Math.max(this.el.clientHeight, 420)
    })

    this.scene.edges.forEach((edge, index) => {
      edge.element = this.edgeLayer.children[index] || createEdgeElement(edge)
      if (!edge.element.parentNode) this.edgeLayer.appendChild(edge.element)
    })

    this.scene.nodes.forEach((node, index) => {
      const previous = oldNodes.get(node.id)
      if (previous) {
        node.group = previous.group
        node.halo = previous.halo
        node.body = previous.body
        node.avatar = previous.avatar
        node.wash = previous.wash
        node.glaze = previous.glaze
        node.ring = previous.ring
        node.labelText = previous.labelText
        node.subtitleText = previous.subtitleText
        node.x = previous.x
        node.y = previous.y
        node.vx = previous.vx
        node.vy = previous.vy
      } else {
        const elements = createNodeElements.call(this, node)
        Object.assign(node, elements)
        this.nodeLayer.appendChild(node.group)
      }

      if (!node.group.parentNode) this.nodeLayer.appendChild(node.group)
      if (this.nodeLayer.children[index] !== node.group) {
        this.nodeLayer.appendChild(node.group)
      }
    })
  },

  animate(timestamp) {
    if (!this.scene) return

    const { nodes, edges, center, graphRadius } = this.scene
    const width = Math.max(this.el.clientWidth, 320)
    const height = Math.max(this.el.clientHeight, 420)
    const pointerShiftX = this.pointer ? ((this.pointer.x - center.x) / center.x) * 12 : 0
    const pointerShiftY = this.pointer ? ((this.pointer.y - center.y) / center.y) * 10 : 0

    nodes.forEach((node) => {
      if (node.id === this.highlightedNodeId) {
        node.vx *= 0.82
        node.vy *= 0.82
      }

      if (this.draggedNode && this.draggedNode.id === node.id) return

      const driftX = Math.cos(timestamp / 1350 + node.driftOffset) * (8 + node.depth * 12)
      const driftY = Math.sin(timestamp / 1680 + node.driftOffset) * (6 + node.depth * 10)
      const targetX = node.anchorX + driftX + pointerShiftX * (0.8 + node.depth)
      const targetY = node.anchorY + driftY + pointerShiftY * (0.8 + node.depth)
      const spring = node.cluster === "core" ? 0.12 : 0.045

      node.vx += (targetX - node.x) * spring
      node.vy += (targetY - node.y) * spring
      node.vx *= 0.9
      node.vy *= 0.9
    })

    for (let outer = 0; outer < nodes.length; outer += 1) {
      for (let inner = outer + 1; inner < nodes.length; inner += 1) {
        const first = nodes[outer]
        const second = nodes[inner]
        const deltaX = second.x - first.x
        const deltaY = second.y - first.y
        const distance = Math.hypot(deltaX, deltaY) || 1
        const minimum = first.radius + second.radius + 24

        if (distance < minimum) {
          const force = (minimum - distance) * 0.018
          const forceX = (deltaX / distance) * force
          const forceY = (deltaY / distance) * force

          if (!(this.draggedNode && this.draggedNode.id === first.id) && first.cluster !== "core") {
            first.vx -= forceX
            first.vy -= forceY
          }

          if (!(this.draggedNode && this.draggedNode.id === second.id) && second.cluster !== "core") {
            second.vx += forceX
            second.vy += forceY
          }
        }
      }
    }

    nodes.forEach((node) => {
      if (node.cluster === "core") {
        node.x = center.x
        node.y = center.y
      } else if (!(this.draggedNode && this.draggedNode.id === node.id)) {
        node.x = clamp(node.x + node.vx, 28, width - 28)
        node.y = clamp(node.y + node.vy, 28, height - 28)
      }
    })

    edges.forEach((edge) => {
      const source = edge.sourceNode
      const target = edge.targetNode
      const connected =
        this.highlightedNodeId &&
        (source.id === this.highlightedNodeId || target.id === this.highlightedNodeId)
      const bend = edge.kind === "invite" ? 22 : edge.kind === "trust" ? 12 : 18
      setAttributes(edge.element, {
        d: buildEdgePath(source, target, bend),
        opacity: this.highlightedNodeId ? (connected ? 0.92 : 0.12) : 0.34,
        "stroke-width": connected ? 3.6 : edge.kind === "trust" ? 2.8 : 2.1
      })
    })

    nodes.forEach((node) => {
      const connected =
        !this.highlightedNodeId ||
        node.id === this.highlightedNodeId ||
        edges.some(
          (edge) =>
            (edge.sourceNode.id === node.id || edge.targetNode.id === node.id) &&
            (edge.sourceNode.id === this.highlightedNodeId || edge.targetNode.id === this.highlightedNodeId)
        )
      const scale = this.highlightedNodeId && node.id === this.highlightedNodeId ? 1.08 : 1
      const opacity = connected ? 1 : 0.32
      setAttributes(node.halo, { opacity: connected ? (node.kind === "subject" ? 0.42 : 0.22) : 0.06 })
      setAttributes(node.group, {
        transform: `translate(${node.x}, ${node.y}) scale(${scale})`
      })
      node.group.style.opacity = opacity.toString()
      node.group.style.transition = "opacity 120ms ease"
    })

    this.frame = window.requestAnimationFrame(this.animate)
  },

  teardownScene() {
    if (this.frame) window.cancelAnimationFrame(this.frame)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.pointerMoveHandler) this.el.removeEventListener("pointermove", this.pointerMoveHandler)
    if (this.pointerLeaveHandler) this.el.removeEventListener("pointerleave", this.pointerLeaveHandler)
    hideTooltip(this.tooltip)
    this.frame = null
    this.resizeObserver = null
    this.pointerMoveHandler = null
    this.pointerLeaveHandler = null

    if (this.svg && this.svg.parentNode) {
      this.svg.remove()
    }

    this.svg = null
    this.scene = null
  }
}
