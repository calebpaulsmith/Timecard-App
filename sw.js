// sw.js — app-shell service worker.
// Cache-first for our own files, network-first fallback for everything else.

const CACHE_VERSION = 'maxiflex-v8';
const SHELL = [
  './',
  './index.html',
  './styles.css',
  './time.js',
  './db.js',
  './app.js',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  'https://unpkg.com/dexie@3.2.4/dist/dexie.min.js',
];

self.addEventListener('install', (ev) => {
  ev.waitUntil(
    caches.open(CACHE_VERSION).then(cache =>
      // Bypass HTTP cache when populating shell, so a freshly bumped SW always
      // pulls the latest files instead of inheriting stale browser-cached ones.
      Promise.all(SHELL.map(url => {
        const req = new Request(url, { cache: 'reload' });
        return fetch(req)
          .then(resp => resp && resp.ok ? cache.put(url, resp) : null)
          .catch(err => console.warn('SW cache skip:', url, err));
      }))
    ).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (ev) => {
  ev.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_VERSION).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (ev) => {
  const req = ev.request;
  if (req.method !== 'GET') return;
  ev.respondWith(
    caches.match(req).then(cached => {
      if (cached) return cached;
      return fetch(req).then(resp => {
        // Cache successful same-origin responses opportunistically.
        if (resp && resp.status === 200 && resp.type === 'basic') {
          const clone = resp.clone();
          caches.open(CACHE_VERSION).then(c => c.put(req, clone));
        }
        return resp;
      }).catch(() => caches.match('./index.html'));
    })
  );
});
