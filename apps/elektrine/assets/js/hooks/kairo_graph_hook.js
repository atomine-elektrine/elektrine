/**
 * KairoGraph: a force-directed graph of Kairo sources.
 *
 * The LiveView serves a `data-graph` payload of `{nodes, edges}` where each node
 * is a source (file) and an edge connects two sources that share a tag (edge
 * `weight` = number of shared tags). Layout is a Fruchterman-Reingold force
 * simulation whose per-frame displacement is capped by a cooling "temperature",
 * so it converges quickly and then stops.
 *
 * Rendering is done on a <canvas>: the whole scene is cleared and repainted each
 * frame, which avoids the repaint trails and per-element cost of animating
 * hundreds of SVG nodes. Click a node to open that source; drag to reposition,
 * scroll to zoom, drag the background to pan.
 */

const GRAVITY = 0.04 // pull toward center each frame
const COOLING = 0.95 // temperature decay per frame
const MIN_TEMP = 0.4 // below this the simulation is considered settled
const DRAG_THRESHOLD = 4 // px before a press counts as a drag, not a click

const EDGE_COLOR = "148, 163, 184" // slate-400 as "r, g, b"

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

function parsePayload(el) {
  const raw = el.dataset.graph
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw)
    if (!parsed || !Array.isArray(parsed.nodes)) return null
    return parsed
  } catch (_error) {
    return null
  }
}

export const KairoGraph = {
  mounted() {
    this.lastPayload = null
    this.loop = this.loop.bind(this)
    this.frame = null
    this.drawFrame = null
    this.render()
  },

  updated() {
    if ((this.el.dataset.graph || "") !== this.lastPayload) this.render()
  },

  destroyed() {
    this.teardown()
  },

  render() {
    const graph = parsePayload(this.el)
    this.teardown()
    this.lastPayload = this.el.dataset.graph || ""

    this.dpr = window.devicePixelRatio || 1
    this.labelColor = getComputedStyle(this.el).color || "#64748b"

    this.canvas = document.createElement("canvas")
    this.canvas.style.display = "block"
    this.canvas.style.width = "100%"
    this.canvas.style.height = "100%"
    this.canvas.style.cursor = "grab"
    this.canvas.style.touchAction = "none"
    this.el.appendChild(this.canvas)
    this.ctx = this.canvas.getContext("2d")

    this.scale = 1
    this.tx = 0
    this.ty = 0
    this.hovered = null
    this.running = false
    this.resize()

    if (!graph || graph.nodes.length === 0) {
      this.nodes = []
      this.edges = []
      this.drawEmpty()
      this.bindEvents()
      return
    }

    this.buildScene(graph)
    this.bindEvents()
    this.kick()
  },

  resize() {
    this.width = Math.max(this.el.clientWidth, 320)
    this.height = Math.max(this.el.clientHeight, 360)
    this.canvas.width = Math.round(this.width * this.dpr)
    this.canvas.height = Math.round(this.height * this.dpr)
  },

  buildScene(graph) {
    const cx = this.width / 2
    const cy = this.height / 2
    const ring = Math.min(this.width, this.height) * 0.34
    const count = graph.nodes.length

    this.k = Math.sqrt((this.width * this.height) / Math.max(count, 1)) * 0.55
    this.temp = Math.min(this.width, this.height) * 0.12

    this.nodes = graph.nodes.map((node, index) => {
      const angle = (index / count) * Math.PI * 2
      const jitter = ((index * 37) % 40) - 20
      return {
        ...node,
        degree: 0,
        x: cx + Math.cos(angle) * (ring + jitter),
        y: cy + Math.sin(angle) * (ring + jitter),
        dx: 0,
        dy: 0
      }
    })

    this.nodeById = new Map(this.nodes.map((node) => [node.id, node]))
    this.edges = (graph.edges || [])
      .map((edge) => ({
        weight: edge.weight || 1,
        source: this.nodeById.get(edge.source),
        target: this.nodeById.get(edge.target)
      }))
      .filter((edge) => edge.source && edge.target)

    this.neighbors = new Map(this.nodes.map((node) => [node.id, new Set([node.id])]))
    this.edges.forEach((edge) => {
      edge.source.degree += 1
      edge.target.degree += 1
      this.neighbors.get(edge.source.id).add(edge.target.id)
      this.neighbors.get(edge.target.id).add(edge.source.id)
    })

    this.nodes.forEach((node) => {
      node.r = 5 + Math.sqrt(node.degree) * 1.6
    })

    this.showAllLabels = count <= 45
  },

  bindEvents() {
    this.onPointerDown = (event) => {
      this.canvas.setPointerCapture(event.pointerId)
      const node = this.nodeAt(event)
      if (node) {
        this.dragNode = node
        this.dragMoved = false
        this.pointerStart = { x: event.clientX, y: event.clientY }
      } else {
        this.panning = true
        this.panStart = { x: event.clientX, y: event.clientY }
        this.canvas.style.cursor = "grabbing"
      }
    }

    this.onPointerMove = (event) => {
      if (this.dragNode) {
        if (
          Math.abs(event.clientX - this.pointerStart.x) > DRAG_THRESHOLD ||
          Math.abs(event.clientY - this.pointerStart.y) > DRAG_THRESHOLD
        ) {
          this.dragMoved = true
        }
        const p = this.toLogical(event)
        this.dragNode.x = p.x
        this.dragNode.y = p.y
        this.kick()
      } else if (this.panning) {
        this.tx += event.clientX - this.panStart.x
        this.ty += event.clientY - this.panStart.y
        this.panStart = { x: event.clientX, y: event.clientY }
        this.requestDraw()
      } else {
        const node = this.nodeAt(event)
        const id = node ? node.id : null
        this.canvas.style.cursor = node ? "pointer" : "grab"
        if (id !== this.hovered) {
          this.hovered = id
          this.requestDraw()
        }
      }
    }

    this.onPointerUp = (event) => {
      if (this.canvas.hasPointerCapture(event.pointerId)) {
        this.canvas.releasePointerCapture(event.pointerId)
      }
      if (this.dragNode && !this.dragMoved && this.dragNode.ref != null) {
        this.pushEvent("select_source", { id: String(this.dragNode.ref) })
      }
      this.dragNode = null
      this.panning = false
      this.canvas.style.cursor = "grab"
    }

    this.onPointerCancel = (event) => {
      if (this.canvas.hasPointerCapture(event.pointerId)) {
        this.canvas.releasePointerCapture(event.pointerId)
      }
      this.dragNode = null
      this.panning = false
      this.canvas.style.cursor = "grab"
    }

    this.onWheel = (event) => {
      event.preventDefault()
      const rect = this.canvas.getBoundingClientRect()
      const px = event.clientX - rect.left
      const py = event.clientY - rect.top
      const factor = event.deltaY < 0 ? 1.1 : 1 / 1.1
      const next = clamp(this.scale * factor, 0.25, 4)
      this.tx = px - ((px - this.tx) * next) / this.scale
      this.ty = py - ((py - this.ty) * next) / this.scale
      this.scale = next
      this.requestDraw()
    }

    this.canvas.addEventListener("pointerdown", this.onPointerDown)
    this.canvas.addEventListener("pointermove", this.onPointerMove)
    this.canvas.addEventListener("pointerup", this.onPointerUp)
    this.canvas.addEventListener("pointercancel", this.onPointerCancel)
    this.canvas.addEventListener("wheel", this.onWheel, { passive: false })

    this.resizeObserver = new ResizeObserver(() => {
      const w = Math.max(this.el.clientWidth, 320)
      const h = Math.max(this.el.clientHeight, 360)
      if (w === this.width && h === this.height) return
      this.resize()
      this.kick()
    })
    this.resizeObserver.observe(this.el)
  },

  toLogical(event) {
    const rect = this.canvas.getBoundingClientRect()
    return {
      x: (event.clientX - rect.left - this.tx) / this.scale,
      y: (event.clientY - rect.top - this.ty) / this.scale
    }
  },

  nodeAt(event) {
    const p = this.toLogical(event)
    let best = null
    let bestDist = Infinity
    this.nodes.forEach((node) => {
      const d = Math.hypot(node.x - p.x, node.y - p.y)
      const hit = node.r + 4 / this.scale
      if (d <= hit && d < bestDist) {
        best = node
        bestDist = d
      }
    })
    return best
  },

  kick() {
    this.temp = Math.max(this.temp, Math.min(this.width, this.height) * 0.06)
    if (!this.running) {
      this.running = true
      this.frame = window.requestAnimationFrame(this.loop)
    }
  },

  // One-off repaint when the simulation is settled (hover, pan, zoom).
  requestDraw() {
    if (this.running || this.drawFrame !== null) return
    this.drawFrame = window.requestAnimationFrame(() => {
      this.drawFrame = null
      if (!this.running) this.draw()
    })
  },

  loop() {
    this.frame = null
    if (!this.ctx) return
    this.simulate()
    this.draw()
    this.temp *= COOLING
    if (this.temp > MIN_TEMP || this.dragNode) {
      this.frame = window.requestAnimationFrame(this.loop)
    } else {
      this.running = false
      this.draw() // final frame with labels
    }
  },

  simulate() {
    const nodes = this.nodes
    const k = this.k
    const cx = this.width / 2
    const cy = this.height / 2

    nodes.forEach((node) => {
      node.dx = 0
      node.dy = 0
    })

    for (let i = 0; i < nodes.length; i += 1) {
      for (let j = i + 1; j < nodes.length; j += 1) {
        const a = nodes[i]
        const b = nodes[j]
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dist = Math.hypot(dx, dy)
        if (dist < 0.5) {
          dx = ((i % 7) - 3) * 0.1 + 0.05
          dy = ((j % 7) - 3) * 0.1 + 0.05
          dist = Math.hypot(dx, dy)
        }
        const rep = (k * k) / dist
        const fx = (dx / dist) * rep
        const fy = (dy / dist) * rep
        a.dx += fx
        a.dy += fy
        b.dx -= fx
        b.dy -= fy
      }
    }

    this.edges.forEach((edge) => {
      const a = edge.source
      const b = edge.target
      const dx = a.x - b.x
      const dy = a.y - b.y
      const dist = Math.hypot(dx, dy) || 0.5
      const att = (dist * dist) / k
      const fx = (dx / dist) * att
      const fy = (dy / dist) * att
      a.dx -= fx
      a.dy -= fy
      b.dx += fx
      b.dy += fy
    })

    nodes.forEach((node) => {
      node.dx += (cx - node.x) * GRAVITY
      node.dy += (cy - node.y) * GRAVITY
    })

    // Integrate, capping per-frame movement by temperature, and keep nodes
    // inside the viewport so the area-tuned layout fills the frame at scale 1
    // instead of expanding off-screen.
    const m = 24
    nodes.forEach((node) => {
      if (this.dragNode === node) return
      const disp = Math.hypot(node.dx, node.dy) || 1
      const limit = Math.min(disp, this.temp)
      node.x = clamp(node.x + (node.dx / disp) * limit, m, this.width - m)
      node.y = clamp(node.y + (node.dy / disp) * limit, m, this.height - m)
    })
  },

  draw() {
    const ctx = this.ctx
    if (!ctx) return

    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    ctx.clearRect(0, 0, this.width, this.height)
    ctx.translate(this.tx, this.ty)
    ctx.scale(this.scale, this.scale)

    const active = this.hovered
    const lit = active ? this.neighbors.get(active) : null

    // Edges.
    ctx.lineCap = "round"
    this.edges.forEach((edge) => {
      const on = !active || edge.source.id === active || edge.target.id === active
      const alpha = active ? (on ? 0.7 : 0.04) : 0.22
      ctx.strokeStyle = `rgba(${EDGE_COLOR}, ${alpha})`
      ctx.lineWidth = clamp(edge.weight, 1, 4)
      ctx.beginPath()
      ctx.moveTo(edge.source.x, edge.source.y)
      ctx.lineTo(edge.target.x, edge.target.y)
      ctx.stroke()
    })

    // Nodes.
    this.nodes.forEach((node) => {
      const on = !active || lit.has(node.id)
      ctx.globalAlpha = on ? 1 : 0.2
      ctx.beginPath()
      ctx.arc(node.x, node.y, node.r, 0, Math.PI * 2)
      ctx.fillStyle = node.color || "#9ca3af"
      ctx.fill()
      ctx.lineWidth = 1.5
      ctx.strokeStyle = "rgba(0, 0, 0, 0.28)"
      ctx.stroke()
    })
    ctx.globalAlpha = 1

    // Labels only at rest (or zoomed in / hovered neighborhood), cheap to draw
    // on canvas with no trails, but skipping them keeps motion frames light.
    const showLabels = !this.running || this.scale > 1.4 || active
    if (showLabels) {
      ctx.fillStyle = this.labelColor
      ctx.textAlign = "center"
      ctx.textBaseline = "top"
      ctx.font = "10px ui-sans-serif, system-ui, sans-serif"
      const zoomedIn = this.scale > 1.4
      this.nodes.forEach((node) => {
        const show = (!this.running && this.showAllLabels) || zoomedIn || (active && lit.has(node.id))
        if (!show || !node.label) return
        ctx.globalAlpha = active && !lit.has(node.id) ? 0.2 : 0.85
        ctx.fillText(node.label, node.x, node.y + node.r + 2)
      })
      ctx.globalAlpha = 1
    }
  },

  drawEmpty() {
    const ctx = this.ctx
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    ctx.clearRect(0, 0, this.width, this.height)
    ctx.fillStyle = `rgba(${EDGE_COLOR}, 0.8)`
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.font = "14px ui-sans-serif, system-ui, sans-serif"
    ctx.fillText("No sources to graph yet.", this.width / 2, this.height / 2)
  },

  teardown() {
    this.running = false
    if (this.frame !== null) window.cancelAnimationFrame(this.frame)
    if (this.drawFrame !== null) window.cancelAnimationFrame(this.drawFrame)
    this.frame = null
    this.drawFrame = null
    if (this.resizeObserver) this.resizeObserver.disconnect()
    this.resizeObserver = null
    this.dragNode = null
    this.panning = false
    if (this.canvas && this.canvas.parentNode) this.canvas.remove()
    this.canvas = null
    this.ctx = null
  }
}
