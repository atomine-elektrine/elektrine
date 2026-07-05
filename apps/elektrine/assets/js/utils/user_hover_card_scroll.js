const hooks = new Set();
let listenersInstalled = false;

function dismissForScroll() {
  hooks.forEach((hook) => hook.dismissForScroll?.());
}

function ensureScrollListeners() {
  if (listenersInstalled || typeof window === "undefined") return;

  listenersInstalled = true;
  // js-check: allow-global-listener-singleton
  window.addEventListener("scroll", dismissForScroll, {
    capture: true,
    passive: true,
  });
}

export function registerUserHoverCardHook(hook) {
  hooks.add(hook);
  ensureScrollListeners();
}

export function unregisterUserHoverCardHook(hook) {
  hooks.delete(hook);
}
