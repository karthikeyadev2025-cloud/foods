// Service worker: keeps the app shell and its hashed assets so the phone screens open
// without a connection (data comes from the persisted query cache and the outbox).
// Registered by src/main.tsx on the web build only; the desktop shell loads from disk.
// Replaced at build time with the commit (see vite.config.ts). It MUST change
// every deploy: the browser only installs a new worker when sw.js itself differs
// in bytes, and `activate` below only clears caches whose name is not this one.
// While this was the constant 'erp-shell-v1', neither ever happened — a deployed
// fix could sit there unused behind a worker nobody had a reason to replace.
const CACHE = 'erp-shell-__BUILD_SHA__';
const SHELL = ['/', '/index.html', '/manifest.webmanifest'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Hashed build assets never change: cache first.
  if (url.pathname.startsWith('/assets/') || url.pathname.startsWith('/icons/')) {
    event.respondWith(
      caches.open(CACHE).then(async (c) => {
        const hit = await c.match(req);
        if (hit) return hit;
        const res = await fetch(req);
        if (res.ok) c.put(req, res.clone());
        return res;
      }),
    );
    return;
  }

  // Navigations: network first, the cached shell when offline.
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res.ok) caches.open(CACHE).then((c) => c.put('/index.html', res.clone()));
          return res;
        })
        .catch(() => caches.match('/index.html')),
    );
  }
});
