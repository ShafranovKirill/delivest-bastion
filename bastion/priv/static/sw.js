// Bastion service worker: shows alerts pushed by the bastion and opens the instance page.
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

self.addEventListener("push", (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch (_error) {
    data = {title: event.data && event.data.text()}
  }

  event.waitUntil(
    self.registration.showNotification(data.title || "Бастион", {
      body: data.body || "",
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      tag: data.tag,
      renotify: Boolean(data.tag),
      data: {url: data.url || "/"},
    }),
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const url = new URL(event.notification.data.url, self.location.origin).href

  event.waitUntil(
    self.clients.matchAll({type: "window", includeUncontrolled: true}).then((clients) => {
      const client = clients.find((c) => c.url.startsWith(self.location.origin))
      if (client) return client.focus().then((c) => c.navigate(url))
      return self.clients.openWindow(url)
    }),
  )
})
