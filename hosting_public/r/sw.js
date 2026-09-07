const CACHE_NAME = 'smartbizz-menu-v1';
const STATIC_ASSETS = [
  '/r/',
  '/r/index.html',
  '/r/manifest.json',
  'https://cdn.tailwindcss.com',
  'https://unpkg.com/lucide@latest',
  'https://www.gstatic.com/firebasejs/9.23.0/firebase-app-compat.js',
  'https://www.gstatic.com/firebasejs/9.23.0/firebase-firestore-compat.js',
  'https://www.gstatic.com/firebasejs/9.23.0/firebase-functions-compat.js'
];

const OFFLINE_PAGE = '/r/index.html';

// Install — cache static assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(STATIC_ASSETS).catch((err) => {
        console.warn('SW: Some assets failed to cache during install:', err);
      });
    })
  );
  self.skipWaiting();
});

// Activate — clean old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys
          .filter((key) => key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      );
    })
  );
  self.clients.claim();
});

// Fetch — network-first for API, cache-first for static
self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Network-first for Firebase API / Cloud Functions calls
  if (
    url.hostname.includes('cloudfunctions.net') ||
    url.hostname.includes('googleapis.com') ||
    url.hostname.includes('firestore.googleapis.com') ||
    request.method !== 'GET'
  ) {
    event.respondWith(
      fetch(request).catch(() => {
        return caches.match(request);
      })
    );
    return;
  }

  // Cache-first for static assets (CDN scripts, icons, images)
  if (
    url.hostname.includes('gstatic.com') ||
    url.hostname.includes('unpkg.com') ||
    url.hostname.includes('cdn.tailwindcss.com') ||
    url.pathname.match(/\.(js|css|png|jpg|jpeg|svg|gif|woff2?)$/)
  ) {
    event.respondWith(
      caches.match(request).then((cached) => {
        if (cached) return cached;
        return fetch(request).then((response) => {
          if (response && response.status === 200) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
          }
          return response;
        });
      })
    );
    return;
  }

  // Network-first for navigation / HTML
  event.respondWith(
    fetch(request)
      .then((response) => {
        if (response && response.status === 200 && request.mode === 'navigate') {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
        }
        return response;
      })
      .catch(() => {
        return caches.match(request).then((cached) => {
          return cached || caches.match(OFFLINE_PAGE);
        });
      })
  );
});
