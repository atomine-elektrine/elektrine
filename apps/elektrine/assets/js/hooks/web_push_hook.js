// Browser Web Push subscription hook.
// Registers the service worker, reports per-browser subscription state, and
// handles subscribe/unsubscribe requests pushed from the LiveView.

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const rawData = window.atob(base64)

  return Uint8Array.from([...rawData].map((char) => char.charCodeAt(0)))
}

export const WebPushManager = {
  mounted() {
    this.vapidKey = this.el.dataset.vapidPublicKey || ""

    this.handleEvent("web_push_subscribe", () => this.subscribe())
    this.handleEvent("web_push_unsubscribe", () => this.unsubscribe())

    this.reportState()
  },

  supported() {
    return (
      "serviceWorker" in navigator &&
      "PushManager" in window &&
      "Notification" in window
    )
  },

  registration() {
    return navigator.serviceWorker.register("/sw.js")
  },

  async reportState() {
    if (!this.supported() || !this.vapidKey) {
      this.pushEvent("web_push_state", { supported: false })
      return
    }

    try {
      const registration = await this.registration()
      const subscription = await registration.pushManager.getSubscription()

      this.pushEvent("web_push_state", {
        supported: true,
        subscribed: !!subscription,
        permission: Notification.permission,
      })
    } catch (error) {
      this.pushEvent("web_push_error", {
        reason: error?.message || "registration_failed",
      })
    }
  },

  async subscribe() {
    try {
      const permission = await Notification.requestPermission()

      if (permission !== "granted") {
        this.pushEvent("web_push_error", { reason: "permission_denied" })
        return
      }

      const registration = await this.registration()

      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(this.vapidKey),
      })

      this.pushEvent("web_push_subscribed", { subscription: subscription.toJSON() })
    } catch (error) {
      this.pushEvent("web_push_error", {
        reason: error?.message || "subscribe_failed",
      })
    }
  },

  async unsubscribe() {
    try {
      const registration = await this.registration()
      const subscription = await registration.pushManager.getSubscription()
      const endpoint = subscription ? subscription.endpoint : null

      if (subscription) {
        await subscription.unsubscribe()
      }

      this.pushEvent("web_push_unsubscribed", { endpoint })
    } catch (error) {
      this.pushEvent("web_push_error", {
        reason: error?.message || "unsubscribe_failed",
      })
    }
  },
}
