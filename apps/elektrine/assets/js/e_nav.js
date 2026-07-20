/**
 * E-nav (product modes toolbar) scroll behavior.
 *
 * The primary tabs scroll horizontally with the scrollbar hidden, so on
 * narrow screens two things need JS help:
 * - the active tab is centered into view on load (it can otherwise sit
 *   offscreen when it lives far down the list), and
 * - edge fade classes signal that more tabs exist past either edge.
 */

const SCROLLER_SELECTOR = ".e-nav .e-nav-scroll"

// Small tolerance so sub-pixel scroll positions don't flicker the fades.
const EDGE_TOLERANCE = 4

let resizeBound = false

function updateOverflowFades(scroller) {
  const maxScroll = scroller.scrollWidth - scroller.clientWidth
  scroller.classList.toggle("e-nav-fade-start", scroller.scrollLeft > EDGE_TOLERANCE)
  scroller.classList.toggle(
    "e-nav-fade-end",
    scroller.scrollLeft < maxScroll - EDGE_TOLERANCE
  )
}

function centerActiveTab(scroller) {
  const active = scroller.querySelector('[aria-current="page"]')
  if (!active) return

  const scrollerRect = scroller.getBoundingClientRect()
  const activeRect = active.getBoundingClientRect()
  const activeLeft = activeRect.left - scrollerRect.left + scroller.scrollLeft

  scroller.scrollLeft = activeLeft - (scroller.clientWidth - activeRect.width) / 2
}

export function initENav() {
  document.querySelectorAll(SCROLLER_SELECTOR).forEach((scroller) => {
    if (scroller.dataset.eNavInit !== "true") {
      scroller.dataset.eNavInit = "true"
      scroller.addEventListener("scroll", () => updateOverflowFades(scroller), {
        passive: true
      })
      centerActiveTab(scroller)
    }

    updateOverflowFades(scroller)
  })

  if (!resizeBound) {
    resizeBound = true
    window.addEventListener("resize", () => {
      document.querySelectorAll(SCROLLER_SELECTOR).forEach(updateOverflowFades)
    })
  }
}
