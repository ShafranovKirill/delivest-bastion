// Turns bastion alerts on this device on and off through the service worker.
const supported = () =>
  "serviceWorker" in navigator && "PushManager" in window && "Notification" in window

const base64ToBytes = (value) => {
  const padded = (value + "=".repeat((4 - (value.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/")
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))
}

const request = (method, body) =>
  fetch("/push/subscriptions", {
    method,
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "x-csrf-token": document.querySelector("meta[name='csrf-token']").getAttribute("content"),
    },
    body: JSON.stringify(body),
  }).then((response) => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
  })

export const registerServiceWorker = () => {
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {})
}

export const PushToggle = {
  async mounted() {
    if (!supported()) {
      this.el.hidden = true
      return
    }

    this.el.addEventListener("click", () => this.toggle())
    this.render(await this.subscription())
  },

  async subscription() {
    const registration = await navigator.serviceWorker.ready
    return registration.pushManager.getSubscription()
  },

  async toggle() {
    this.el.disabled = true

    try {
      const current = await this.subscription()

      if (current) {
        await request("DELETE", {endpoint: current.endpoint})
        await current.unsubscribe()
        this.render(null)
      } else {
        if ((await Notification.requestPermission()) !== "granted") {
          this.render(null, "Уведомления запрещены в настройках браузера")
          return
        }

        const registration = await navigator.serviceWorker.ready
        const subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: base64ToBytes(this.el.dataset.key),
        })

        await request("POST", subscription.toJSON())
        this.render(subscription)
      }
    } catch (error) {
      this.render(await this.subscription(), `Не получилось: ${error.message}`)
    } finally {
      this.el.disabled = false
    }
  },

  render(subscription, problem) {
    const on = Boolean(subscription)
    this.el.classList.toggle("text-primary", on)
    this.el.querySelector("[data-on]").hidden = !on
    this.el.querySelector("[data-off]").hidden = on
    this.el.title =
      problem || (on ? "Уведомления на этом устройстве включены" : "Включить уведомления на этом устройстве")
  },
}
