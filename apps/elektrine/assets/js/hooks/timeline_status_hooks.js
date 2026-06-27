function parseCount(value) {
  const parsed = Number.parseInt(String(value ?? "0").replace(/[^\d-]/g, ""), 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

function formatCount(value) {
  return String(value);
}

export const AnimatedCount = {
  mounted() {
    this.animation = null;
    this.currentCount = parseCount(this.el.dataset.count ?? this.el.textContent);
    this.prepareElement();
    this.setCount(this.currentCount);
  },

  updated() {
    const nextCount = parseCount(this.el.dataset.count);
    const fromCount = this.currentCount ?? parseCount(this.el.textContent);

    if (nextCount === fromCount) {
      this.setCount(nextCount);
      return;
    }

    if (window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches) {
      this.setCount(nextCount);
      return;
    }

    this.animateCountChange(fromCount, nextCount);
  },

  destroyed() {
    this.animation?.cancel();
  },

  prepareElement() {
    this.el.style.display = "inline-block";
    this.el.style.overflow = "hidden";
    this.el.style.position = "relative";
    this.el.style.verticalAlign = "bottom";
    this.el.style.fontVariantNumeric = "tabular-nums";
  },

  setCount(count) {
    this.animation?.cancel();
    this.animation = null;
    this.currentCount = count;
    this.el.textContent = "";
    this.el.appendChild(this.buildCountSpan(count));
  },

  buildCountSpan(count) {
    const span = document.createElement("span");
    span.textContent = formatCount(count);
    span.style.display = "block";
    return span;
  },

  animateCountChange(fromCount, toCount) {
    this.animation?.cancel();

    const direction = toCount > fromCount ? -1 : 1;
    const currentSpan = this.buildCountSpan(toCount);
    const previousSpan = this.buildCountSpan(fromCount);

    currentSpan.style.transform = `translateY(${100 * direction}%)`;
    previousSpan.style.position = "absolute";
    previousSpan.style.inset = "0";

    this.el.textContent = "";
    this.el.append(currentSpan, previousSpan);

    const currentAnimation = currentSpan.animate(
      [
        { transform: `translateY(${100 * direction}%)` },
        { transform: "translateY(0%)" },
      ],
      { duration: 200, easing: "ease-out", fill: "forwards" },
    );

    const previousAnimation = previousSpan.animate(
      [
        { transform: "translateY(0%)" },
        { transform: `translateY(${-100 * direction}%)` },
      ],
      { duration: 200, easing: "ease-out", fill: "forwards" },
    );

    this.animation = currentAnimation;
    this.currentCount = toCount;

    Promise.allSettled([currentAnimation.finished, previousAnimation.finished]).then(() => {
      if (this.animation === currentAnimation) this.setCount(toCount);
    });
  },
};

const REMOTE_FOLLOW_BUTTON_CLASSES = [
  "btn-ghost",
  "btn-secondary",
  "btn-primary",
  "btn-disabled",
  "phx-click-loading:bg-base-200",
  "phx-click-loading:text-base-content",
];

const REMOTE_FOLLOW_BUTTON_VARIANTS = {
  timeline: {
    following: { add: ["btn-ghost"], disabled: false },
    pending: { add: ["btn-ghost"], disabled: false },
    none: {
      add: [
        "btn-secondary",
        "phx-click-loading:bg-base-200",
        "phx-click-loading:text-base-content",
      ],
      disabled: false,
    },
  },
  "hover-card": {
    following: { add: ["btn-ghost"], disabled: false },
    pending: { add: ["btn-disabled"], disabled: true },
    none: {
      add: [
        "btn-primary",
        "phx-click-loading:bg-base-200",
        "phx-click-loading:text-base-content",
      ],
      disabled: false,
    },
  },
};

export const RemoteFollowButton = {
  mounted() {
    this.remoteActorId = String(this.el.dataset.remoteActorId || "");

    this.handleEvent("remote_follow_state_changed", ({ remote_actor_id, state }) => {
      if (String(remote_actor_id) !== this.remoteActorId) return;

      this.el.dataset.followState = state;
      this.syncState();
    });

    this.syncState();
  },

  updated() {
    this.syncState();
  },

  syncState() {
    const state = this.el.dataset.followState || "none";
    const variantName = this.el.dataset.followVariant || "timeline";
    const variant =
      REMOTE_FOLLOW_BUTTON_VARIANTS[variantName] ||
      REMOTE_FOLLOW_BUTTON_VARIANTS.timeline;
    const config = variant[state] || variant.none;

    this.el.classList.remove(...REMOTE_FOLLOW_BUTTON_CLASSES);
    this.el.classList.add(...config.add);
    this.el.disabled = !!config.disabled;

    this.el.querySelectorAll("[data-follow-display]").forEach((display) => {
      display.classList.toggle("hidden", display.dataset.followDisplay !== state);
    });
  },
};
