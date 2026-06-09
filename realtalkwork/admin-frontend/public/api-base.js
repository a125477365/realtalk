// API base URL configuration
// Admin frontend is served behind nginx which proxies /api, /admin, /payment, /auth
// to the backend. All API calls go through the same origin (no CORS).
(function() {
  // Admin frontend: use relative URLs (proxied by nginx)
  window.API_BASE = "";
})();
