const SVG_NS = "http://www.w3.org/2000/svg"
const XLINK_NS = "http://www.w3.org/1999/xlink"

export function svg(tagName) {
  return document.createElementNS(SVG_NS, tagName)
}

export function setImageHref(node, url) {
  node.setAttribute("href", url)
  node.setAttributeNS(XLINK_NS, "xlink:href", url)
}

export function setAttributes(node, attrs) {
  Object.entries(attrs).forEach(([key, value]) => {
    if (value === null || value === undefined) return
    node.setAttribute(key, value)
  })
}
