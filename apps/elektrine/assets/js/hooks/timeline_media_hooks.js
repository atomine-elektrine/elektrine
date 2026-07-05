import { OverlayPortal } from "../utils/overlay_portal";
import { registerUserHoverCardHook, unregisterUserHoverCardHook } from "../utils/user_hover_card_scroll";

/**
 * User Hover Card Hook
 * Shows a profile preview card when hovering over usernames/avatars
 */
export const UserHoverCard = {
  mounted() {
    this.card = this.el.querySelector("[data-hover-card]");
    if (!this.card) return;

    this.trigger = this.el.querySelector("[data-hover-trigger]") || this.el;
    this.card.__userHoverCard = this;
    this.portal = new OverlayPortal(this.card, {
      portalRoot: this.el.closest("[data-phx-main]") || document.body,
    });
    this.showTimeout = null;
    this.hideTimeout = null;
    this.isCardHovered = false;
    this.isVisible = false;
    registerUserHoverCardHook(this);

    this.handleMouseEnter = () => {
      clearTimeout(this.hideTimeout);
      this.showTimeout = setTimeout(() => this.showCard(), 400);
    };

    this.handleMouseLeave = () => {
      clearTimeout(this.showTimeout);
      this.hideTimeout = setTimeout(() => {
        if (!this.isCardHovered) this.hideCard();
      }, 200);
    };

    this.handleCardEnter = () => {
      this.isCardHovered = true;
      clearTimeout(this.hideTimeout);
    };

    this.handleCardLeave = () => {
      this.isCardHovered = false;
      this.hideTimeout = setTimeout(() => this.hideCard(), 200);
    };

    this.trigger.addEventListener("mouseenter", this.handleMouseEnter);
    this.trigger.addEventListener("mouseleave", this.handleMouseLeave);
    this.card.addEventListener("mouseenter", this.handleCardEnter);
    this.card.addEventListener("mouseleave", this.handleCardLeave);
  },

  showCard() {
    if (this.card) {
      document.querySelectorAll("[data-hover-card]").forEach((card) => {
        if (card !== this.card) {
          if (card.__userHoverCard) {
            card.__userHoverCard.hideCard();
          } else {
            card.classList.remove("visible", "scale-100");
            card.classList.add("invisible", "scale-95");
          }
        }
      });

      this.portal.mount();
      this.portal.positionNear(this.trigger);
      this.card.classList.remove("invisible", "scale-95");
      this.card.classList.add("visible", "scale-100");
      this.isVisible = true;
    }
  },

  hideCard() {
    this.isVisible = false;
    if (this.card) {
      this.card.classList.remove("visible", "scale-100");
      this.card.classList.add("invisible", "scale-95");
      this.portal.restore();
    }
  },

  dismissForScroll() {
    if (!this.showTimeout && !this.hideTimeout && !this.isVisible) return;

    clearTimeout(this.showTimeout);
    clearTimeout(this.hideTimeout);
    this.showTimeout = null;
    this.hideTimeout = null;
    this.isCardHovered = false;
    this.hideCard();
  },

  destroyed() {
    clearTimeout(this.showTimeout);
    clearTimeout(this.hideTimeout);
    unregisterUserHoverCardHook(this);
    this.card?.removeEventListener("mouseenter", this.handleCardEnter);
    this.card?.removeEventListener("mouseleave", this.handleCardLeave);
    this.trigger?.removeEventListener("mouseenter", this.handleMouseEnter);
    this.trigger?.removeEventListener("mouseleave", this.handleMouseLeave);
    this.portal?.restore();
    if (this.card) this.card.__userHoverCard = null;
  },
};

/**
 * Image Modal Hook
 * Adds keyboard and scroll navigation support for image galleries
 */
export const ImageModal = {
  mounted() {
    this.handleKeyDown = (e) => {
      if (e.key === "Escape") this.pushEvent("close_image_modal", {});
      else if (e.key === "ArrowLeft") this.pushEvent("prev_image", {});
      else if (e.key === "ArrowRight") this.pushEvent("next_image", {});
      else if (e.key === "ArrowUp") {
        e.preventDefault();
        this.pushEvent("prev_media_post", {});
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        this.pushEvent("next_media_post", {});
      }
    };

    this.lastScrollTime = 0;
    this.scrollThrottle = 200;

    this.handleWheel = (e) => {
      if (!this.el.contains(e.target)) return;
      const now = Date.now();
      if (now - this.lastScrollTime < this.scrollThrottle) return;
      if (Math.abs(e.deltaY) < 10) return;

      this.lastScrollTime = now;
      e.preventDefault();

      if (e.deltaY < 0) this.pushEvent("prev_image", {});
      else this.pushEvent("next_image", {});
    };

    document.addEventListener("keydown", this.handleKeyDown);
    document.addEventListener("wheel", this.handleWheel, { passive: false });
  },

  destroyed() {
    document.removeEventListener("keydown", this.handleKeyDown);
    document.removeEventListener("wheel", this.handleWheel);
  },
};
