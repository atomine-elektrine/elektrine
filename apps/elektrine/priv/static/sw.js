// Elektrine service worker: browser Web Push notifications.
// Served undigested at /sw.js so its scope covers the whole origin.

const DEFAULT_ICON = "/images/android-chrome-192x192.png"

self.addEventListener("install", () => {
  self.skipWaiting()
})

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim())
})

function parsePayload(event) {
  if (!event.data) return {}

  try {
    return event.data.json() || {}
  } catch (_error) {
    return { body: event.data.text() }
  }
}

function iconUrl(icon) {
  // Payloads may carry a heroicon name (e.g. "hero-bell") instead of an image URL.
  if (typeof icon === "string" && (icon.startsWith("http") || icon.startsWith("/"))) {
    return icon
  }

  return DEFAULT_ICON
}

self.addEventListener("push", (event) => {
  const payload = parsePayload(event)
  const data = payload.data || {}
  const title = payload.title || "Elektrine"

  const options = {
    body: payload.body || "",
    icon: iconUrl(payload.icon),
    badge: DEFAULT_ICON,
    data,
    tag: data.notification_id ? `elektrine-notification-${data.notification_id}` : undefined,
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const data = event.notification.data || {}
  const target = new URL(data.url || "/notifications", self.location.origin).href

  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((windowClients) => {
        for (const client of windowClients) {
          if (client.url === target && "focus" in client) {
            return client.focus()
          }
        }

        for (const client of windowClients) {
          if ("focus" in client && "navigate" in client) {
            return client.focus().then((focused) => focused.navigate(target))
          }
        }

        return self.clients.openWindow(target)
      })
  )
})
