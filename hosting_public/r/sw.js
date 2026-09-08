// SmartDine Customer Web App Service Worker (W-39, W-40, W-41, W-42)
const CACHE_VERSION = '2026.09.08-v2';
const CACHE_NAME = 'smartbizz-menu-' + CACHE_VERSION;

const STATIC_ASSETS = [
  '/r/',
  '/r/index.html',
  '/r/manifest.json',
  'https://cdn.tailwindcss.com',
  'https://unpkg.com/lucide@latest',
  'https://checkout.razorpay.com/v1/checkout.js'
];

const OFFLINE_PAGE = '/r/index.html';

// Install — cache static assets but don't force immediate takeover mid-order
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(STATIC_ASSETS).catch((err) => {
        console.warn('[SW] Some assets failed to cache during install:', err);
      });
    })
  );
  // Do not call self.skipWaiting() unconditionally (W-42)
});

// Allow client app to trigger skipWaiting explicitly when safe
self.addEventListener('message', (event) => {
  if (event.data && event.data.action === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

// Activate — purge obsolete caches from previous versions (W-39)
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys
          .filter((key) => key !== CACHE_NAME)
          .map((key) => {
            console.log('[SW] Purging old cache:', key);
            return caches.delete(key);
          })
      );
    }).then(() => self.clients.claim())
  );
});

// Fetch handler
self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // W-41: Let non-GET requests (POST, PATCH, DELETE) bypass SW completely
  // so network errors propagate natively without respondWith(undefined) TypeErrors
  if (request.method !== 'GET') {
    return;
  }

  // W-39: Never cache sw.js itself to ensure updates are always discovered
  if (url.pathname.endsWith('/sw.js') || url.pathname.endsWith('/r/sw.js')) {
    event.respondWith(fetch(request));
    return;
  }

  // Network-first for dynamic APIs (Apps Script webhook, Firestore, Cloud Functions)
  if (
    url.hostname.includes('script.google.com') ||
    url.hostname.includes('script.googleusercontent.com') ||
    url.hostname.includes('googleapis.com') ||
    url.hostname.includes('cloudfunctions.net') ||
    url.searchParams.has('action')
  ) {
    event.respondWith(
      fetch(request).catch(() => {
        // W-40: Return explicit 503 JSON for failed API calls, NEVER index.html with 200
        return new Response(
          JSON.stringify({ success: false, error: 'OFFLINE_NO_NETWORK', offline: true }),
          { status: 503, headers: { 'Content-Type': 'application/json' } }
        );
      })
    );
    return;
  }

  // Cache-first for static assets (CDN scripts, fonts, images)
  if (
    url.hostname.includes('gstatic.com') ||
    url.hostname.includes('unpkg.com') ||
    url.hostname.includes('cdn.tailwindcss.com') ||
    url.hostname.includes('checkout.razorpay.com') ||
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

  // Navigation requests: Network-first with offline fallback strictly for navigation (W-40)
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response && response.status === 200) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
          }
          return response;
        })
        .catch(() => {
          return caches.match(OFFLINE_PAGE);
        })
    );
    return;
  }

  // Default fallback for other GET requests
  event.respondWith(
    caches.match(request).then((cached) => {
      return cached || fetch(request);
    })
  );
});
