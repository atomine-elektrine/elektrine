export class OverlayPortal {
  constructor(element, options = {}) {
    this.element = element;
    this.originParent = element?.parentNode || null;
    this.originNextSibling = element?.nextSibling || null;
    this.portalRoot = options.portalRoot || this.defaultPortalRoot();
  }

  mount() {
    if (!this.element || !this.portalRoot || this.element.parentNode === this.portalRoot) return;

    this.portalRoot.appendChild(this.element);
  }

  defaultPortalRoot() {
    return this.element?.closest?.("[data-phx-main]") || document.body;
  }

  restore() {
    if (!this.element || !this.originParent || this.element.parentNode === this.originParent) {
      return;
    }

    this.clearPosition();

    if (this.originNextSibling && this.originNextSibling.parentNode === this.originParent) {
      this.originParent.insertBefore(this.element, this.originNextSibling);
    } else {
      this.originParent.appendChild(this.element);
    }
  }

  positionNear(trigger, options = {}) {
    if (!this.element || !trigger) return;

    const margin = options.margin ?? 8;
    const zIndex = options.zIndex ?? 10000;
    const triggerRect = trigger.getBoundingClientRect();
    const elementRect = this.element.getBoundingClientRect();
    const maxLeft = Math.max(margin, window.innerWidth - elementRect.width - margin);
    const align = options.align || "start";
    const leftAnchor =
      align === "end"
        ? triggerRect.right - elementRect.width
        : align === "center"
          ? triggerRect.left + triggerRect.width / 2 - elementRect.width / 2
          : triggerRect.left;
    const left = Math.min(Math.max(leftAnchor, margin), maxLeft);
    const placement = options.placement || "auto";
    const belowTop = triggerRect.bottom + margin;
    const aboveTop = triggerRect.top - elementRect.height - margin;
    const top =
      placement === "top"
        ? aboveTop >= margin
          ? aboveTop
          : belowTop
        : placement === "bottom"
          ? belowTop + elementRect.height <= window.innerHeight - margin
            ? belowTop
            : Math.max(margin, aboveTop)
          : belowTop + elementRect.height <= window.innerHeight - margin
            ? belowTop
            : Math.max(margin, aboveTop);

    Object.assign(this.element.style, {
      position: "fixed",
      left: `${left}px`,
      top: `${top}px`,
      right: "auto",
      bottom: "auto",
      zIndex: String(zIndex),
    });
  }

  clearPosition() {
    if (!this.element) return;

    this.element.style.removeProperty("position");
    this.element.style.removeProperty("left");
    this.element.style.removeProperty("top");
    this.element.style.removeProperty("right");
    this.element.style.removeProperty("bottom");
    this.element.style.removeProperty("z-index");
  }
}
