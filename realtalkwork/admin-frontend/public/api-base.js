// API base URL configuration
// The backend API runs on port 8000, admin frontend on port 8080.
// This file is loaded before app.js and sets window.API_BASE.
(function() {
  // 1. Explicit env override (for custom deployments)
  if (window.REACT_APP_API_BASE) {
    window.API_BASE = window.REACT_APP_API_BASE;
    return;
  }

  // 2. Detect environment from port
  // Browser sees admin frontend on :8001, API on :8000 (same host, different port)
  var port = window.location.port;
  if (port === "8080" || port === "8001" || port === "80") {
    // Admin frontend: API is on 8000
    var scheme = window.location.protocol === "https:" ? "https" : "http";
    window.API_BASE = scheme + "://" + window.location.hostname + ":8000";
  } else if (port === "8000") {
    // API itself: use relative
    window.API_BASE = "";
  } else {
    // Fallback: dev server scenario (localhost:xxx)
    window.API_BASE = window.location.hostname === "localhost" || window.location.hostname === "127.0.0.1"
      ? "http://localhost:8000"
      : "";
  }
})();
