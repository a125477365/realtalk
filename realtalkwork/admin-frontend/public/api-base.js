// API base URL configuration
// Admin frontend is served behind nginx which proxies /api, /admin, /payment, /auth
// to the backend. All API calls go through the same origin (no CORS).
(function() {
  // 本地调试可在控制台执行：localStorage.setItem("realtalk_api_base", "http://127.0.0.1:8000")
  window.API_BASE = (function() {
    try { return localStorage.getItem("realtalk_api_base") || ""; } catch (e) { return ""; }
  })();
})();
