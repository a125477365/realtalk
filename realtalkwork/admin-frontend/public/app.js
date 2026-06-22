"use strict";

// ============================================================
// Config
// ============================================================
var API_BASE = window.API_BASE || "";

// ============================================================
// State
// ============================================================
var state = {
  loggedIn: false,
  sessionChecked: false,
  currentTab: "overview",
  userDetailId: null,
  userPage: 1,
  userQuery: "",
  userLimit: 100,
  orderStatusFilter: "",
  orderMethodFilter: "",
  currentAdminId: null,
  currentAdminUsername: null,
  currentAdminRole: null,
  currentAdminRoleName: null,
};

var _renderGuard = 0;

// ============================================================
// DOM helpers
// ============================================================
function getEl(id) { return document.getElementById(id); }
function html(id, content) {
  var el = getEl(id);
  if (el) el.innerHTML = content;
}

// ============================================================
// API helpers
// ============================================================
function apiFetch(url, options) {
  options = options || {};
  var opts = {
    method: options.method || "GET",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
  };
  if (options.body) {
    if (typeof options.body === "object" && !(options.body instanceof FormData)) {
      opts.body = JSON.stringify(options.body);
    } else {
      opts.body = options.body;
      delete opts.headers["Content-Type"];
    }
  }
  if (options.headers) {
    for (var k in options.headers) opts.headers[k] = options.headers[k];
  }
  return fetch(API_BASE + url, opts);
}

function apiGet(url) { return apiFetch(url); }

function apiPatch(url, body) {
  return apiFetch(url, { method: "PATCH", body: body });
}

function apiPost(url, body) {
  return apiFetch(url, { method: "POST", body: body });
}

function handleApiError(r) {
  if (!r) return Promise.reject();
  if (r.status === 401) {
    state.loggedIn = false;
    state.currentAdminId = null;
    state.currentAdminUsername = null;
    state.currentAdminRole = null;
    renderApp();
    toast("登录已失效，请重新登录", "error");
    return null;
  }
  return r.json().catch(function() { return { detail: "请求失败" }; }).then(function(d) {
    toast(d && d.detail ? d.detail : "请求失败", "error");
    return null;
  });
}

// ============================================================
// Toast notification
// ============================================================
function toast(msg, type) {
  type = type || "";
  var el = getEl("toast");
  if (!el) return;
  el.textContent = msg;
  el.className = "msg-toast show " + type;
  if (el._t) clearTimeout(el._t);
  el._t = setTimeout(function() { el.className = "msg-toast"; }, 3500);
}

// ============================================================
// Utilities
// ============================================================
function esc(s) {
  if (s == null) return "\u2014";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtDT(v) {
  if (!v) return "\u2014";
  return v.slice(0, 19).replace("T", " ");
}

function fmtDate(v) {
  if (!v) return "\u2014";
  return v.slice(0, 10);
}

function fmtYuan(cents) {
  if (cents == null) return "\u2014";
  return "\u00a5" + (cents / 100).toFixed(2);
}

function badge(p) {
  return '<span class="badge badge-' + p + '">' + esc(p) + "</span>";
}

function loadingHTML() {
  return '<div class="loading">加载中</div>';
}

function emptyHTML(msg) {
  msg = msg || "暂无数据";
  return '<div class="empty-state"><div class="icon">\ud83d\udcce</div><div class="msg">' + esc(msg) + "</div></div>";
}

function confirmDialog(title, message, onConfirm) {
  var overlay = document.createElement("div");
  overlay.className = "confirm-overlay show";
  overlay.innerHTML =
    '<div class="confirm-dialog">' +
    "<h3>" + esc(title) + "</h3>" +
    "<p>" + esc(message) + "</p>" +
    '<div class="btn-row">' +
    '<button class="btn btn-secondary" id="confirm-cancel-btn">\u53d6\u6d88</button>' +
    '<button class="btn btn-danger" id="confirm-ok-btn">\u786e\u8ba4</button>' +
    "</div></div>";
  document.body.appendChild(overlay);

  getEl("confirm-cancel-btn").onclick = function() { overlay.remove(); };
  getEl("confirm-ok-btn").onclick = function() { overlay.remove(); onConfirm(); };
  overlay.onclick = function(e) { if (e.target === overlay) overlay.remove(); };
}

function roleName(role) {
  if (role === "superadmin") return "\u8d85\u7ea7\u7ba1\u7406\u5458";
  if (role === "operator") return "\u8fd0\u7ef4";
  return "\u7ba1\u7406\u5458";
}

// ============================================================
// Navigation & Logout
// ============================================================
function navigate(tab) {
  state.currentTab = tab;
  state.userDetailId = null;
  state.userPage = 1;
  renderApp();
}

function resetAdminState() {
  state.loggedIn = false;
  state.currentAdminId = null;
  state.currentAdminUsername = null;
  state.currentAdminRole = null;
  state.currentAdminRoleName = null;
  state.currentTab = "overview";
  state.userDetailId = null;
}

function logout() {
  // 先销毁服务端会话，无论成功与否都回到登录页
  fetch(API_BASE + "/admin/logout", {
    method: "POST",
    credentials: "include",
  }).catch(function() {}).finally(function() {
    resetAdminState();
    renderApp();
    toast("已退出登录", "success");
  });
}

// ============================================================
// Login
// ============================================================
function renderLogin(errorMsg) {
  var errHTML = errorMsg
    ? '<div class="login-error">' + esc(errorMsg) + "</div>"
    : "";
  return [
    '<div class="login-page">',
    '  <div class="login-box">',
    '    <h1>RealTalk \u7ba1\u7406\u540e\u53f0</h1>',
    errHTML,
    '    <form id="login-form">',
    '      <div class="form-group">',
    '        <label for="username">\u7528\u6237\u540d</label>',
    '        <input type="text" id="username" name="username" placeholder="\u8bf7\u8f93\u5165\u7528\u6237\u540d" autocomplete="username" autofocus required />',
    "      </div>",
    '      <div class="form-group">',
    '        <label for="password">\u5bc6\u7801</label>',
    '        <input type="password" id="password" name="password" placeholder="\u8bf7\u8f93\u5165\u5bc6\u7801" autocomplete="current-password" required />',
    "      </div>",
    '      <button type="submit" class="btn btn-primary">\u767b \u5f55</button>',
    "    </form>",
    "  </div>",
    "</div>",
  ].join("");
}

function handleLogin(e) {
  e.preventDefault();
  var username = getEl("username").value.trim();
  var password = getEl("password").value;

  if (!username || !password) {
    toast("\u8bf7\u8f93\u5165\u7528\u6237\u540d\u548c\u5bc6\u7801", "warning");
    return;
  }

  var formData = new FormData();
  formData.append("username", username);
  formData.append("password", password);

  var guard = ++_renderGuard;

  fetch(API_BASE + "/admin/login", {
    method: "POST",
    credentials: "include",
    body: formData,
  }).then(function(r) {
    if (guard !== _renderGuard) return;
    if (r.ok || r.redirected) {
      return r.json().catch(function() { return {}; });
    } else {
      return r.json().catch(function() { return { detail: "\u7528\u6237\u540d\u6216\u5bc6\u7801\u9519\u8bef" }; }).then(function(d) {
        renderApp({ loginError: d.detail || "\u7528\u6237\u540d\u6216\u5bc6\u7801\u9519\u8bef" });
        return null;
      });
    }
  }).then(function(d) {
    if (!d || guard !== _renderGuard) return;
    state.loggedIn = true;
    state.currentAdminId = d.id || null;
    state.currentAdminUsername = d.username || username;
    state.currentAdminRole = d.role || "admin";
    state.currentAdminRoleName = roleName(d.role || "admin");
    renderApp();
  }).catch(function() {
    if (guard !== _renderGuard) return;
    renderApp({ loginError: "\u7f51\u7edc\u9519\u8bef\uff0c\u8bf7\u91cd\u8bd5" });
  });
}

// \u9875\u9762\u52a0\u8f7d/\u5237\u65b0\u65f6\u7528 Cookie \u6062\u590d\u4f1a\u8bdd\uff0c\u907f\u514d\u5237\u65b0\u540e\u88ab\u8e22\u56de\u767b\u5f55\u9875
function restoreSession() {
  return apiFetch("/admin/api/me").then(function(r) {
    if (!r || !r.ok) return false;
    return r.json().then(function(d) {
      state.loggedIn = true;
      state.currentAdminId = d.id || null;
      state.currentAdminUsername = d.username || null;
      state.currentAdminRole = d.role || "admin";
      state.currentAdminRoleName = roleName(d.role || "admin");
      return true;
    });
  }).catch(function() { return false; });
}

// ============================================================
// Sidebar
// ============================================================
function renderSidebar() {
  function nav(id, label, icon) {
    var active = (state.currentTab === id) || (state.currentTab === "user_detail" && id === "users") ? "active" : "";
    return '<a href="#" id="nav-' + id + '" onclick="navigate(\'' + id + '\'); return false;" class="' + active + '">' +
           '<span class="icon">' + icon + '</span><span>' + label + '</span></a>';
  }
  return [
    '<div class="sidebar">',
    '  <div class="sidebar-brand"><h1>RealTalk</h1></div>',
    '  <nav class="sidebar-nav">',
    nav("overview", "\u6570\u636e\u6982\u89c8", "\ud83d\udcca"),
    nav("users", "\u7528\u6237\u7ba1\u7406", "\ud83d\udc65"),
    nav("orders", "\u5145\u503c\u8ba2\u5355", "\ud83d\udcb3"),
    nav("tickets", "\u5ba2\u670d\u5de5\u5355", "\ud83c\udfab"),
    nav("presets", "\u901a\u7528\u573a\u666f", "\ud83d\uddc2\ufe0f"),
    nav("admins", "\u7ba1\u7406\u5458\u7ba1\u7406", "\ud83d\udc64"),
    nav("settings", "\u7cfb\u7edf\u8bbe\u7f6e", "\u2699\ufe0f"),
  "  </nav>",
  '  <div class="sidebar-footer">',
  '    <div class="sidebar-admin-info">',
  '      <span class="sidebar-admin-name" id="sidebar-admin-name"></span>',
  '      <span class="sidebar-admin-role" id="sidebar-admin-role"></span>',
  "    </div>",
  '    <button onclick="openChangePasswordModal()">\u4fee\u6539\u5bc6\u7801</button>',
  '    <button onclick="logout()">\u9000\u51fa\u767b\u5f55</button>',
  "  </div>",
    "</div>",
  ].join("");
}

// ============================================================
// Overview Page
// ============================================================
function renderOverviewPage() {
  return [
    '<div class="page-header"><h1>\u6570\u636e\u6982\u89c8</h1><div class="actions">',
    '<select id="ts-days" onchange="loadOverviewCharts()">',
    '  <option value="14">\u8fd1 14 \u5929</option>',
    '  <option value="30" selected>\u8fd1 30 \u5929</option>',
    '  <option value="90">\u8fd1 90 \u5929</option>',
    "</select>",
    "</div></div>",
    '<div class="card">',
    '  <div class="stat-grid" id="overview-stats">' + loadingHTML() + "</div>",
    "</div>",
    '<div class="chart-grid">',
    '  <div class="card"><h2>\u6536\u5165\u4e0e AI \u652f\u51fa\uff08\u5143/\u65e5\uff09</h2><div id="chart-money">' + loadingHTML() + "</div></div>",
    '  <div class="card"><h2>\u65b0\u589e\u7528\u6237\uff08\u4eba/\u65e5\uff09</h2><div id="chart-users">' + loadingHTML() + "</div></div>",
    '  <div class="card"><h2>\u53e3\u8bed\u7ec3\u4e60\u4f1a\u8bdd\uff08\u6b21/\u65e5\uff09</h2><div id="chart-sessions">' + loadingHTML() + "</div></div>",
    '  <div class="card"><h2>AI \u8c03\u7528\u6b21\u6570\uff08\u6b21/\u65e5\uff09</h2><div id="chart-calls">' + loadingHTML() + "</div></div>",
    "</div>",
    '<div class="card">',
    '  <h2>\u7cfb\u7edf\u7aef\u70b9</h2>',
    '  <div class="system-links">',
    '    <a href="' + API_BASE + '/health" target="_blank" class="btn btn-secondary btn-sm">/health</a>',
    '    <a href="' + API_BASE + '/ready" target="_blank" class="btn btn-secondary btn-sm">/ready</a>',
    '    <a href="' + API_BASE + '/billing/prices" target="_blank" class="btn btn-secondary btn-sm">\u8ba2\u9605\u4ef7\u683c</a>',
    "  </div>",
    "</div>",
  ].join("");
}

function loadOverview() {
  apiGet("/admin/api/overview").then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    r.json().then(function(d) {
      function g(v, l, cls) {
        return '<div class="stat-card ' + (cls || "") + '"><div class="val">' + esc(v) + '</div><div class="lbl">' + esc(l) + "</div></div>";
      }
      var el = getEl("overview-stats");
      if (!el) return;
      el.innerHTML =
        g(d.total_users, "\u603b\u7528\u6237") +
        g("+" + (d.today_new_users || 0), "\u4eca\u65e5\u65b0\u589e") +
        g(d.online_users + "/" + d.online_window_minutes + "min", "\u5728\u7ebf\u7528\u6237") +
        g(fmtYuan(d.paid_recharge_cents), "\u7d2f\u8ba1\u6536\u5165", "stat-good") +
        g(fmtYuan(d.today_revenue_cents || 0), "\u4eca\u65e5\u6536\u5165", "stat-good") +
        g(fmtYuan(Math.round(d.ai_cost_cents || 0)), "AI \u7d2f\u8ba1\u652f\u51fa", "stat-warn") +
        g(fmtYuan(Math.round(d.ai_cost_today_cents || 0)), "AI \u4eca\u65e5\u652f\u51fa", "stat-warn") +
        g(fmtYuan(Math.round(d.gross_margin_cents || 0)), "\u6bdb\u5229\uff08\u6536\u5165-AI \u6210\u672c\uff09") +
        g((d.ai_calls || 0) + " \u6b21 / " + fmtTokens(d.ai_total_tokens), "AI \u8c03\u7528 / Tokens") +
        g(fmtYuan(d.total_balance_cents), "\u7528\u6237\u4f59\u989d\u603b\u8ba1") +
        g(fmtYuan(d.pending_recharge_cents), "\u5f85\u786e\u8ba4\u5145\u503c") +
        g(d.paid_orders, "\u5df2\u652f\u4ed8\u8ba2\u5355") +
        g(d.roleplay_session_count, "\u53e3\u8bed\u4f1a\u8bdd") +
        g(d.practice_result_count, "\u7ec3\u4e60\u8bb0\u5f55") +
        g(d.transcript_count, "\u5bf9\u8bdd\u8bb0\u5f55");
    });
  }).catch(function() {
    var el = getEl("overview-stats");
    if (el) el.innerHTML = emptyHTML("\u52a0\u8f7d\u5931\u8d25\uff0c\u8bf7\u68c0\u67e5\u767b\u5f55\u72b6\u6001");
  });
  loadOverviewCharts();
}

function fmtTokens(n) {
  n = n || 0;
  if (n >= 1000000) return (n / 1000000).toFixed(1) + "M";
  if (n >= 1000) return (n / 1000).toFixed(1) + "K";
  return String(n);
}

function loadOverviewCharts() {
  var ids = ["chart-money", "chart-users", "chart-sessions", "chart-calls"];
  function fail(msg) {
    ids.forEach(function(id) { var el = getEl(id); if (el) el.innerHTML = emptyHTML(msg); });
  }
  var days = parseInt((getEl("ts-days") || { value: "30" }).value) || 30;
  apiGet("/admin/api/stats/timeseries?days=" + days).then(function(r) {
    if (!r) { fail("\u52a0\u8f7d\u5931\u8d25"); return; }
    if (!r.ok) { handleApiError(r); fail("\u52a0\u8f7d\u5931\u8d25"); return; }
    r.json().then(function(d) {
      var items = d.items || [];
      var labels = items.map(function(it) { return it.date.slice(5); });
      drawChart("chart-money", labels, [
        { name: "\u6536\u5165", color: "#16a34a", values: items.map(function(it) { return it.revenue_cents / 100; }) },
        { name: "AI \u652f\u51fa", color: "#dc2626", values: items.map(function(it) { return it.ai_cost_cents / 100; }) },
      ]);
      drawChart("chart-users", labels, [
        { name: "\u65b0\u589e\u7528\u6237", color: "#2563eb", values: items.map(function(it) { return it.new_users; }) },
      ]);
      drawChart("chart-sessions", labels, [
        { name: "\u53e3\u8bed\u4f1a\u8bdd", color: "#7c3aed", values: items.map(function(it) { return it.roleplay_sessions; }) },
      ]);
      drawChart("chart-calls", labels, [
        { name: "AI \u8c03\u7528", color: "#ea580c", values: items.map(function(it) { return it.ai_calls; }) },
      ]);
    }).catch(function() { fail("\u6570\u636e\u89e3\u6790\u5931\u8d25"); });
  }).catch(function() { fail("\u7f51\u7edc\u9519\u8bef"); });
}

// \u8f7b\u91cf SVG \u6298\u7ebf\u56fe\uff08\u65e0\u5916\u90e8\u4f9d\u8d56\uff0c\u79bb\u7ebf\u53ef\u7528\uff09
function drawChart(containerId, labels, series) {
  var el = getEl(containerId);
  if (!el) return;
  var W = 560, H = 200, padL = 44, padR = 10, padT = 14, padB = 26;
  var innerW = W - padL - padR, innerH = H - padT - padB;
  var maxVal = 0;
  series.forEach(function(s) {
    s.values.forEach(function(v) { if (v > maxVal) maxVal = v; });
  });
  if (maxVal <= 0) maxVal = 1;
  maxVal = maxVal * 1.15;
  var n = labels.length;
  function x(i) { return padL + (n <= 1 ? innerW / 2 : (i / (n - 1)) * innerW); }
  function y(v) { return padT + innerH - (v / maxVal) * innerH; }

  var svg = ['<svg viewBox="0 0 ' + W + " " + H + '" class="ts-chart" preserveAspectRatio="xMidYMid meet">'];
  // \u7f51\u683c\u4e0e Y \u8f74\u523b\u5ea6
  for (var gi = 0; gi <= 4; gi++) {
    var gv = (maxVal / 4) * gi;
    var gy = y(gv);
    svg.push('<line x1="' + padL + '" y1="' + gy + '" x2="' + (W - padR) + '" y2="' + gy + '" stroke="#e5e7eb" stroke-width="1"/>');
    svg.push('<text x="' + (padL - 6) + '" y="' + (gy + 4) + '" text-anchor="end" font-size="10" fill="#9ca3af">' + (gv >= 100 ? Math.round(gv) : Math.round(gv * 10) / 10) + "</text>");
  }
  // X \u8f74\u6807\u7b7e\uff08\u7a00\u758f\u5c55\u793a\uff09
  var step = Math.max(1, Math.ceil(n / 8));
  for (var li = 0; li < n; li += step) {
    svg.push('<text x="' + x(li) + '" y="' + (H - 8) + '" text-anchor="middle" font-size="10" fill="#9ca3af">' + esc(labels[li]) + "</text>");
  }
  // \u6570\u636e\u7ebf
  series.forEach(function(s) {
    var pts = s.values.map(function(v, i) { return x(i).toFixed(1) + "," + y(v).toFixed(1); }).join(" ");
    svg.push('<polyline points="' + pts + '" fill="none" stroke="' + s.color + '" stroke-width="2" stroke-linejoin="round"/>');
    s.values.forEach(function(v, i) {
      if (v > 0) svg.push('<circle cx="' + x(i).toFixed(1) + '" cy="' + y(v).toFixed(1) + '" r="2.4" fill="' + s.color + '"><title>' + esc(labels[i]) + " " + s.name + ": " + v + "</title></circle>");
    });
  });
  svg.push("</svg>");
  // \u56fe\u4f8b
  var legend = '<div class="chart-legend">' + series.map(function(s) {
    return '<span><i style="background:' + s.color + '"></i>' + esc(s.name) + "</span>";
  }).join("") + "</div>";
  el.innerHTML = svg.join("") + legend;
}

// ============================================================
// Users List Page
// ============================================================
function renderUsersPage() {
  return [
    '<div class="page-header"><h1>\u7528\u6237\u7ba1\u7406</h1></div>',
    '<div class="card">',
    '  <div class="search-bar">',
    '    <input type="text" id="user-search" placeholder="\u641c\u7d22\u7528\u6237ID\u3001\u6635\u79f0\u3001OpenID..." ' +
         'value="' + esc(state.userQuery) + '" onkeydown="if(event.key===\'Enter\')searchUsers()" />',
    '    <button class="btn btn-primary" onclick="searchUsers()">\u641c\u7d22</button>',
    '    <button class="btn btn-secondary" onclick="resetSearch()">\u91cd\u7f6e</button>',
    "  </div>",
    '  <div class="page-controls">',
    "    \u6bcf\u9875 ",
    '    <select id="user-limit" onchange="changeLimit()">',
    '      <option value="20"' + (state.userLimit === 20 ? " selected" : "") + ">20</option>",
    '      <option value="50"' + (state.userLimit === 50 ? " selected" : "") + ">50</option>",
    '      <option value="100"' + (state.userLimit === 100 ? " selected" : "") + ">100</option>",
    '      <option value="200"' + (state.userLimit === 200 ? " selected" : "") + ">200</option>",
    "    </select>",
    "    \u6761",
    "  </div>",
    '  <div id="user-list-container">' + loadingHTML() + "</div>",
    "</div>",
  ].join("");
}

function buildUsersURL() {
  var url = "/admin/api/users?limit=" + state.userLimit;
  if (state.userQuery) url += "&q=" + encodeURIComponent(state.userQuery);
  return url;
}

function loadUsers() {
  var container = getEl("user-list-container");
  if (!container) return;
  container.innerHTML = loadingHTML();

  apiGet(buildUsersURL()).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    r.json().then(function(d) {
      var items = d.items || [];
      if (!items.length) {
        container.innerHTML = emptyHTML("\u6682\u65e0\u7528\u6237");
        return;
      }
      var rows = items.map(function(u) {
        var uid = esc(u.id);
        var uidAttr = uid.replace(/'/g, "\\'");
        return [
          "<tr>",
          '<td><div class="user-cell"><div class="name">' + esc(u.display_name || "\u2014") + '</div><div class="uid">' + uid + "</div></div></td>",
          "<td>" + badge(u.plan) + "</td>",
          "<td>" + fmtYuan(u.balance_cents) + "</td>",
          "<td>" + (u.is_banned ? badge("banned") : badge("active")) + "</td>",
          "<td>" + fmtDate(u.created_at) + "</td>",
          "<td>" + fmtDate(u.last_seen_at) + "</td>",
          '<td class="table-actions">',
          '<button class="btn btn-primary btn-sm" onclick="openUserDetail(\'' + uidAttr + '\')">\u67e5\u770b</button> ',
          '<button class="btn btn-secondary btn-sm" onclick="openEditModal(\'' + uidAttr + '\')">\u7f16\u8f91</button>',
          "</td>",
          "</tr>",
        ].join("");
      }).join("");

      container.innerHTML = [
        '<div class="table-wrap">',
        '<table>',
        "<thead><tr>",
        "<th>\u7528\u6237</th><th>\u5957\u9910</th><th>\u4f59\u989d</th>",
        "<th>\u72b6\u6001</th><th>\u6ce8\u518c\u65f6\u95f4</th><th>\u6700\u8fd1\u6d3b\u8dc3</th><th>\u64cd\u4f5c</th>",
        "</tr></thead>",
        "<tbody>" + rows + "</tbody>",
        "</table>",
        "</div>",
        '<div class="pagination-info"><span>\u5171 ' + items.length + " \u6761</span></div>",
      ].join("");
    });
  }).catch(function() {
    var container = getEl("user-list-container");
    if (container) container.innerHTML = emptyHTML("\u52a0\u8f7d\u5931\u8d25");
  });
}

function searchUsers() {
  state.userQuery = (getEl("user-search") || { value: "" }).value.trim();
  state.userPage = 1;
  loadUsers();
}

function resetSearch() {
  var el = getEl("user-search");
  if (el) el.value = "";
  state.userQuery = "";
  state.userPage = 1;
  loadUsers();
}

function changeLimit() {
  var el = getEl("user-limit");
  state.userLimit = parseInt(el ? el.value : "100") || 100;
  state.userPage = 1;
  loadUsers();
}

// ============================================================
// User Detail Page
// ============================================================
function renderUserDetailPage() {
  return [
    '<a href="#" class="back-link" onclick="navigate(\'users\'); return false;">\u2190 \u8fd4\u56de\u7528\u6237\u5217\u8868</a>',
    '<div id="user-detail-container">' + loadingHTML() + "</div>",
  ].join("");
}

function openUserDetail(uid) {
  state.userDetailId = uid;
  state.currentTab = "user_detail";
  renderApp();
}

function loadUserDetail() {
  if (!state.userDetailId) return;
  var container = getEl("user-detail-container");
  if (container) container.innerHTML = loadingHTML();

  apiGet("/admin/api/users/" + encodeURIComponent(state.userDetailId)).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    r.json().then(function(d) { renderUserDetail(d); });
  }).catch(function() {
    var container = getEl("user-detail-container");
    if (container) container.innerHTML = emptyHTML("\u52a0\u8f7d\u5931\u8d25");
  });
}

function renderUserDetail(d) {
  var u = d.user;
  var usage = d.usage || {};
  var ledger = d.ledger || [];
  var orders = d.payment_orders || [];
  var uidEsc = esc(u.id).replace(/'/g, "\\'");

  var ledRows = ledger.map(function(item) {
    var amtClass = item.amount_cents >= 0 ? "plus" : "minus";
    var amtStr = item.amount_cents >= 0
      ? "+" + fmtYuan(item.amount_cents)
      : " -" + fmtYuan(-item.amount_cents);
    return [
      "<tr>",
      "<td>" + fmtDT(item.created_at) + "</td>",
      "<td>" + esc(item.title) + "</td>",
      '<td class="amount ' + amtClass + '">' + amtStr + "</td>",
      "<td>" + fmtYuan(item.balance_after_cents) + "</td>",
      "</tr>",
    ].join("");
  }).join("");

  var ordRows = orders.map(function(o) {
    return [
      "<tr>",
      "<td>" + fmtDT(o.created_at) + "</td>",
      "<td>" + esc(o.method) + "</td>",
      "<td>" + fmtYuan(o.amount_cents) + "</td>",
      "<td>" + badge(o.status) + "</td>",
      "<td>" + (o.paid_at ? fmtDT(o.paid_at) : "\u2014") + "</td>",
      "</tr>",
    ].join("");
  }).join("");

  var container = getEl("user-detail-container");
  if (!container) return;

  var banBtn = u.is_banned
    ? '<button class="btn btn-secondary" style="margin-left:8px" onclick="toggleBan(\'' + uidEsc + '\', false)">\u89e3\u9664\u5c01\u7981</button>'
    : '<button class="btn btn-danger" style="margin-left:8px" onclick="toggleBan(\'' + uidEsc + '\', true)">\u5c01\u7981\u7528\u6237</button>';

  container.innerHTML = [
    '<div class="detail-grid">',

    // Basic info
    '<div class="detail-section">',
    "  <h3>\u57fa\u672c\u4fe1\u606f</h3>",
    '  <div class="detail-row"><span class="lbl">\u7528\u6237ID</span><span class="val small mono">' + esc(u.id) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u767b\u5f55\u6807\u8bc6</span><span class="val small mono">' + esc(u.login_identifier) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u663e\u793a\u540d\u79f0</span><span class="val">' + esc(u.display_name || "\u2014") + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u5fae\u4fe1OpenID</span><span class="val small mono">' + esc(u.wechat_openid || "\u2014") + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u8ba2\u9605\u8ba1\u5212</span><span class="val">' + badge(u.plan) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u4f59\u989d</span><span class="val">' + fmtYuan(u.balance_cents) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u72b6\u6001</span><span class="val">' + (u.is_banned ? badge("banned") : badge("active")) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u6ce8\u518c\u65f6\u95f4</span><span class="val">' + fmtDT(u.created_at) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u6700\u8fd1\u6d3b\u8dc3</span><span class="val">' + fmtDT(u.last_seen_at) + "</span></div>",
    u.admin_notes
      ? '  <div class="detail-row"><span class="lbl">\u7ba1\u7406\u5907\u6ce8</span><span class="val small">' + esc(u.admin_notes) + "</span></div>"
      : "",
    "</div>",

    // Usage stats
    '<div class="detail-section">',
    "  <h3>\u4f7f\u7528\u7edf\u8ba1</h3>",
    '  <div class="detail-row"><span class="lbl">\u5bf9\u8bdd\u8bb0\u5f55</span><span class="val">' + (usage.transcript_count || 0) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u573a\u666f\u6570</span><span class="val">' + (usage.scenario_count || 0) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u89d2\u8272\u626e\u6f14\u4f1a\u8bdd</span><span class="val">' + (usage.roleplay_session_count || 0) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u7ec3\u4e60\u8bb0\u5f55</span><span class="val">' + (usage.practice_result_count || 0) + "</span></div>",
    '  <div class="detail-row"><span class="lbl">\u7d2f\u8ba1\u5145\u503c</span><span class="val">' + fmtYuan(usage.paid_recharge_cents) + "</span></div>",
    "</div>",

    "</div>", // end detail-grid

    // Ledger
    '<div class="section-title">\u4f59\u989d\u53d8\u52a8\u8bb0\u5f55\uff08\u6700\u8fd1100\u6761\uff09</div>',
    ledRows
      ? '<div class="table-wrap"><table class="ledger-table"><thead><tr><th>\u65f6\u95f4</th><th>\u63cf\u8ff0</th><th>\u91d1\u989d</th><th>\u53d8\u52a8\u540e\u4f59\u989d</th></tr></thead><tbody>' + ledRows + "</tbody></table></div>"
      : '<div class="empty-state"><div class="msg">\u6682\u65e0\u8bb0\u5f55</div></div>',

    // Orders
    '<div class="section-title">\u5145\u503c\u8ba2\u5355</div>',
    ordRows
      ? '<div class="table-wrap"><table><thead><tr><th>\u521b\u5efa\u65f6\u95f4</th><th>\u65b9\u5f0f</th><th>\u91d1\u989d</th><th>\u72b6\u6001</th><th>\u652f\u4ed8\u65f6\u95f4</th></tr></thead><tbody>' + ordRows + "</tbody></table></div>"
      : '<div class="empty-state"><div class="msg">\u6682\u65e0\u8ba2\u5355</div></div>',

    // Actions
    '<div style="margin-top:24px">',
    '<button class="btn btn-primary" onclick="openEditModal(\'' + uidEsc + '\')">\u7f16\u8f91\u7528\u6237</button>',
    banBtn,
    "</div>",
  ].join("");
}

function toggleBan(uid, ban) {
  var action = ban ? "\u5c01\u7981" : "\u89e3\u9664\u5c01\u7981";
  confirmDialog(action + "\u7528\u6237", "\u786e\u5b9a\u8981" + action + "\u6b64\u7528\u6237\u5417\uff1f", function() {
    apiPatch("/admin/api/users/" + encodeURIComponent(uid), { is_banned: ban }).then(function(r) {
      if (!r) return;
      if (!r.ok) { handleApiError(r); return; }
      toast(action + "\u6210\u529f", "success");
      loadUserDetail();
    });
  });
}

// ============================================================
// Orders Page
// ============================================================
function renderOrdersPage() {
  return [
    '<div class="page-header"><h1>充值订单</h1><div class="actions">',
    '<button class="btn btn-secondary" onclick="loadOrders()">刷新</button>',
    "</div></div>",
    '<div class="card">',
    '  <div class="search-bar">',
    '    <input type="text" id="order-search" placeholder="搜索订单号、用户ID..." onkeydown="if(event.key===\'Enter\')loadOrders()" />',
    '    <select id="order-status-filter" onchange="loadOrders()">',
    '      <option value="">全部状态</option>',
    '      <option value="pending">待支付</option>',
    '      <option value="paid">已支付</option>',
    "    </select>",
    '    <select id="order-method-filter" onchange="loadOrders()">',
    '      <option value="">全部方式</option>',
    '      <option value="wechat">微信</option>',
    '      <option value="alipay">支付宝</option>',
    "    </select>",
    '    <button class="btn btn-primary" onclick="loadOrders()">搜索</button>',
    "  </div>",
    '  <div id="order-list-container">' + loadingHTML() + "</div>",
    "</div>",
  ].join("");
}

function loadOrders() {
  var container = getEl("order-list-container");
  if (!container) return;
  container.innerHTML = loadingHTML();

  var q = (getEl("order-search") || { value: "" }).value.trim();
  var st = (getEl("order-status-filter") || { value: "" }).value;
  var method = (getEl("order-method-filter") || { value: "" }).value;
  var url = "/admin/api/orders?limit=100";
  if (q) url += "&q=" + encodeURIComponent(q);
  if (st) url += "&status=" + encodeURIComponent(st);
  if (method) url += "&method=" + encodeURIComponent(method);

  apiGet(url).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    r.json().then(function(d) {
      var items = d.items || [];
      if (!items.length) {
        container.innerHTML = emptyHTML("暂无订单");
        return;
      }
      var rows = items.map(function(o) {
        var oidAttr = String(o.order_id).replace(/'/g, "\\'");
        var userLabel = o.user_display_name || o.user_login_identifier || o.user_id;
        var markBtn = o.status === "pending"
          ? '<button class="btn btn-primary btn-sm" onclick="markOrderPaid(\'' + oidAttr + '\')">确认到账</button>'
          : "—";
        return [
          "<tr>",
          '<td class="mono" style="font-size:12px">' + esc(String(o.order_id).slice(0, 8)) + "…</td>",
          '<td><div class="user-cell"><div class="name">' + esc(userLabel) + "</div></div></td>",
          "<td>" + esc(o.method === "wechat" ? "微信" : o.method === "alipay" ? "支付宝" : o.method) + "</td>",
          "<td>" + fmtYuan(o.amount_cents) + "</td>",
          "<td>" + badge(o.status) + "</td>",
          "<td>" + fmtDT(o.created_at) + "</td>",
          "<td>" + (o.paid_at ? fmtDT(o.paid_at) : "—") + "</td>",
          '<td class="table-actions">' + markBtn + "</td>",
          "</tr>",
        ].join("");
      }).join("");
      container.innerHTML = [
        '<div class="table-wrap"><table>',
        "<thead><tr><th>订单号</th><th>用户</th><th>方式</th><th>金额</th><th>状态</th><th>创建时间</th><th>支付时间</th><th>操作</th></tr></thead>",
        "<tbody>" + rows + "</tbody></table></div>",
        '<div class="pagination-info"><span>共 ' + d.total + " 条</span></div>",
      ].join("");
    });
  }).catch(function() {
    if (container) container.innerHTML = emptyHTML("加载失败");
  });
}

function markOrderPaid(orderId) {
  confirmDialog("确认到账", "确认已收到该订单款项并为用户入账？此操作会立即增加用户余额。", function() {
    apiPost("/admin/api/orders/" + encodeURIComponent(orderId) + "/mark-paid").then(function(r) {
      if (!r) return;
      if (!r.ok) { handleApiError(r); return; }
      toast("已入账", "success");
      loadOrders();
    });
  });
}


// ============================================================
// Token Usage Page
// ============================================================
function ticketCatLabel(c) { return { refund: "退款", feedback: "反馈", bug: "问题", other: "其他" }[c] || c; }
function ticketStatusLabel(s) { return { open: "待处理", processing: "处理中", resolved: "已解决", closed: "已关闭" }[s] || s; }

function renderTicketsPage() {
  return [
    '<div class="page-header"><h1>客服工单</h1><div class="actions">',
    '  <select id="ticket-status-filter" onchange="loadTickets()">',
    '    <option value="">全部状态</option>',
    '    <option value="open">待处理</option>',
    '    <option value="processing">处理中</option>',
    '    <option value="resolved">已解决</option>',
    '    <option value="closed">已关闭</option>',
    "  </select>",
    '  <button class="btn btn-secondary" onclick="loadTickets()">刷新</button>',
    "</div></div>",
    '<div id="ticket-list-container">' + loadingHTML() + "</div>",
  ].join("");
}

function loadTickets() {
  var container = getEl("ticket-list-container");
  if (!container) return;
  container.innerHTML = loadingHTML();
  var st = (getEl("ticket-status-filter") || {}).value || "";
  apiGet("/admin/api/support/tickets" + (st ? "?status=" + encodeURIComponent(st) : "")).then(function(r) {
    if (!r || !r.ok) { container.innerHTML = '<div class="hint">加载失败</div>'; return; }
    r.json().then(function(d) {
      var items = d.items || [];
      if (!items.length) { container.innerHTML = '<div class="hint" style="padding:16px">暂无工单</div>'; return; }
      container.innerHTML = items.map(function(t) {
        var statusOpts = ["open", "processing", "resolved", "closed"].map(function(s) {
          return '<option value="' + s + '"' + (t.status === s ? " selected" : "") + ">" + ticketStatusLabel(s) + "</option>";
        }).join("");
        return [
          '<div class="card" style="margin-bottom:12px">',
          '  <div style="display:flex;justify-content:space-between;align-items:center;gap:8px">',
          "    <div><b>" + esc(t.subject) + '</b> <span class="hint">[' + ticketCatLabel(t.category) + "]</span></div>",
          '    <div class="hint">' + esc(t.user_display_name || "") + " · " + fmtDT(t.created_at) + "</div>",
          "  </div>",
          '  <div style="margin:8px 0;white-space:pre-wrap">' + esc(t.body) + "</div>",
          '  <div class="form-grid">',
          '    <div class="form-group"><label>状态</label><select id="tk-st-' + t.id + '">' + statusOpts + "</select></div>",
          '    <div class="form-group" style="grid-column:1/-1"><label>回复用户（退款等处理结果）</label><textarea id="tk-rp-' + t.id + '" rows="2">' + esc(t.admin_reply || "") + "</textarea></div>",
          "  </div>",
          '  <button class="btn btn-primary" onclick="saveTicket(\'' + t.id + "')\">保存处理</button>",
          "</div>",
        ].join("");
      }).join("");
    });
  });
}

function saveTicket(id) {
  var body = {
    status: (getEl("tk-st-" + id) || {}).value,
    admin_reply: (getEl("tk-rp-" + id) || {}).value,
  };
  apiPost("/admin/api/support/tickets/" + id, body).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    toast("工单已更新", "success");
    loadTickets();
  });
}

function renderUsagePage() {
  return [
    '<div class="page-header"><h1>Token 用量</h1><div class="actions">',
    '<select id="usage-days" onchange="loadUsage()">',
    '  <option value="7">近 7 天</option>',
    '  <option value="30" selected>近 30 天</option>',
    '  <option value="90">近 90 天</option>',
    "</select>",
    '<button class="btn btn-secondary" onclick="loadUsage()">刷新</button>',
    "</div></div>",
    '<div class="card">',
    '  <h2>用户用量排行 <span class="subtitle">按今日用量倒序；达到 80% 标黄，超限标红。模型 token 单价可在「系统设置」动态修改以保证费用统计准确</span></h2>',
    '  <div id="usage-list">' + loadingHTML() + "</div>",
    "</div>",
  ].join("");
}

function loadUsage() {
  var el = getEl("usage-list");
  if (!el) return;
  el.innerHTML = loadingHTML();
  var days = (getEl("usage-days") || { value: "30" }).value;
  apiGet("/admin/api/usage/users?days=" + days).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    r.json().then(function(d) {
      var items = d.items || [];
      if (!items.length) { el.innerHTML = emptyHTML("暂无用量记录"); return; }
      var rows = items.map(function(u) {
        var cls = u.over_limit ? ' style="background:#fef2f2"' : (u.near_limit ? ' style="background:#fffbeb"' : "");
        var flag = u.over_limit ? '<span class="badge badge-banned">已超限</span>'
                 : u.near_limit ? '<span class="badge" style="background:#fef3c7;color:#b07000">接近上限</span>'
                 : '<span class="badge badge-active">正常</span>';
        return [
          "<tr" + cls + ">",
          '<td><div class="user-cell"><div class="name">' + esc(u.display_name || "—") + '</div><div class="uid">' + esc(u.user_id) + "</div></div></td>",
          "<td>" + badge(u.plan_tier) + "</td>",
          "<td><b>" + u.today_tokens.toLocaleString() + "</b> / " + u.daily_limit.toLocaleString() + "</td>",
          "<td>" + Math.round(u.usage_ratio * 100) + "%</td>",
          "<td>" + flag + "</td>",
          "<td>" + fmtYuan(Math.round(u.today_cost_cents)) + "</td>",
          "<td>" + u.period_tokens.toLocaleString() + " / " + u.period_calls + " 次</td>",
          "<td>" + fmtYuan(Math.round(u.period_cost_cents)) + "</td>",
          "</tr>",
        ].join("");
      }).join("");
      el.innerHTML = [
        '<div class="table-wrap"><table>',
        "<thead><tr><th>用户</th><th>套餐</th><th>今日 tokens / 限额</th><th>占比</th><th>状态</th><th>今日成本</th><th>周期 tokens / 调用</th><th>周期成本</th></tr></thead>",
        "<tbody>" + rows + "</tbody></table></div>",
      ].join("");
    });
  }).catch(function() { el.innerHTML = emptyHTML("加载失败"); });
}

// ============================================================
// Plan / Quota / ASR Settings
// ============================================================
function renderPlanQuotaCards() {
  return [
    '<div class="card">',
    "  <h2>会员套餐价格 <span class=\"subtitle\">App 与 Web 端实时生效；单位为分</span></h2>",
    '  <div id="plan-editor">' + loadingHTML() + "</div>",
    "</div>",
    '<div class="card">',
    "  <h2>月度 Token 费用额度 <span class=\"subtitle\">现以「当月模型费用」为准：额度 = 购买会员时档位标准月费 × 下方比例；旧用户按购买时月费算，改价不影响</span></h2>",
    '  <div class="form-grid">',
    '    <div class="form-group"><label>额度比例（% of 会员月费）</label><input type="number" id="q-budget-ratio" min="0" max="100" step="1" /></div>',
    "  </div>",
    '  <div class="hint" style="margin:6px 0 10px">例：基础月费 ¥30、比例 50% → 该用户每月可用 ¥15 的文字+语音模型额度（另 ¥15 为利润）。实时生效。</div>',
    '  <button class="btn btn-primary" onclick="saveQuota()">保存额度比例</button>',
    "</div>",
    '<div class="card">',
    "  <h2>非会员（免费）每日限额 <span class=\"subtitle\">新用户默认非会员，无月度额度；按每日 token 限制；0 表示不限制；实时生效</span></h2>",
    '  <div class="form-grid">',
    '    <div class="form-group"><label>每日文字模型对话（token）</label><input type="number" id="q-nm-chat" min="0" /></div>',
    '    <div class="form-group"><label>每日采集文字输入（token≈字）</label><input type="number" id="q-nm-cap-tok" min="0" /></div>',
    '    <div class="form-group"><label>每日采集时长（秒）</label><input type="number" id="q-nm-cap-sec" min="0" /></div>',
    "  </div>",
    '  <button class="btn btn-primary" onclick="saveQuota()">保存非会员限额</button>',
    "</div>",
    '<div class="card">',
    "  <h2>每日 Token 限额（旧·参考） <span class=\"subtitle\">已改为按月度费用额度门禁，此处仅作展示与兼容；0 表示不限制</span></h2>",
    '  <div class="form-grid">',
    '    <div class="form-group"><label>免费用户</label><input type="number" id="q-free" min="0" /></div>',
    '    <div class="form-group"><label>基础会员</label><input type="number" id="q-basic" min="0" /></div>',
    '    <div class="form-group"><label>高级会员</label><input type="number" id="q-premium" min="0" /></div>',
    "  </div>",
    '  <button class="btn btn-primary" onclick="saveQuota()">保存限额</button>',
    "</div>",
    '<div class="card">',
    "  <h2>语音转写（ASR）<span class=\"subtitle\">高级会员上传录音转文字的方式</span></h2>",
    '  <div id="asr-mode-banner"></div>',
    '  <div id="asr-cloud-fields" class="form-grid">',
    '    <div class="form-group"><label>Base URL</label><input type="text" id="asr-base-url" placeholder="https://api.openai.com/v1" /></div>',
    '    <div class="form-group"><label>模型</label><input type="text" id="asr-model" placeholder="whisper-1" /></div>',
    '    <div class="form-group"><label>API Key <span class="hint" id="asr-key-status"></span></label>',
    '      <input type="password" id="asr-api-key" placeholder="留空保持不变" autocomplete="new-password" /></div>',
    "  </div>",
    '  <button class="btn btn-primary" id="asr-save-btn" style="margin-top:10px" onclick="saveAsr()">保存 ASR 配置</button>',
    "</div>",
  ].join("");
}

function loadPlanQuotaAsr() {
  apiGet("/admin/api/settings/plans").then(function(r) {
    if (!r || !r.ok) return;
    r.json().then(function(d) {
      var el = getEl("plan-editor");
      if (!el) return;
      var rows = (d.items || []).map(function(p, i) {
        return [
          "<tr>",
          '<td>' + esc(p.title) + ' <span class="hint">(' + esc(p.id) + ")</span></td>",
          "<td>" + (p.tier === "premium" ? "高级" : "基础") + "</td>",
          "<td>" + p.months + " 个月</td>",
          '<td><input type="number" id="plan-price-' + i + '" value="' + p.price_cents + '" min="0" style="width:110px" /></td>',
          "<td>" + fmtYuan(p.per_month_cents) + "/月</td>",
          "</tr>",
        ].join("");
      }).join("");
      el.innerHTML = [
        '<div class="table-wrap"><table>',
        "<thead><tr><th>套餐</th><th>档位</th><th>时长</th><th>总价（分）</th><th>当前折合</th></tr></thead>",
        "<tbody>" + rows + "</tbody></table></div>",
        '<button class="btn btn-primary" style="margin-top:10px" onclick="savePlans()">保存套餐价格</button>',
      ].join("");
      window._planItems = d.items;
    });
  });
  apiGet("/admin/api/settings/quota").then(function(r) {
    if (!r || !r.ok) return;
    r.json().then(function(d) {
      if (getEl("q-free")) getEl("q-free").value = d.daily_token_limit_free;
      if (getEl("q-basic")) getEl("q-basic").value = d.daily_token_limit_basic;
      if (getEl("q-premium")) getEl("q-premium").value = d.daily_token_limit_premium;
      if (getEl("q-budget-ratio")) getEl("q-budget-ratio").value = Math.round((d.budget_ratio != null ? d.budget_ratio : 0.5) * 100);
      if (getEl("q-nm-chat")) getEl("q-nm-chat").value = d.nonmember_daily_chat_tokens;
      if (getEl("q-nm-cap-tok")) getEl("q-nm-cap-tok").value = d.nonmember_daily_capture_tokens;
      if (getEl("q-nm-cap-sec")) getEl("q-nm-cap-sec").value = d.nonmember_daily_capture_seconds;
    });
  });
  apiGet("/admin/api/settings/asr").then(function(r) {
    if (!r || !r.ok) return;
    r.json().then(function(d) {
      var local = d.mode === "local";
      var banner = getEl("asr-mode-banner");
      var cloud = getEl("asr-cloud-fields");
      var saveBtn = getEl("asr-save-btn");
      if (local) {
        // 本地转写由部署时（setup.sh）安装并配置，管理台只读展示
        if (banner) banner.innerHTML =
          '<div class="hint" style="padding:10px;background:var(--warning-bg,#fff8e6);border-radius:8px">' +
          '当前为<b>服务器本地转写</b>模式，由部署脚本（setup.sh）自动安装 whisper 并配置，' +
          '无需在此设置。如需改用云端模型，请在服务器重新运行 setup.sh 并选择云端方式。</div>';
        if (cloud) cloud.style.display = "none";
        if (saveBtn) saveBtn.style.display = "none";
      } else {
        if (banner) banner.innerHTML = "";
        if (cloud) cloud.style.display = "";
        if (saveBtn) saveBtn.style.display = "";
        if (getEl("asr-base-url")) getEl("asr-base-url").value = d.base_url || "";
        if (getEl("asr-model")) getEl("asr-model").value = d.model || "";
        var ks = getEl("asr-key-status");
        if (ks) ks.textContent = d.api_key_configured ? "（已配置：" + d.api_key_masked + "）" : (d.dev_mode ? "（开发模式：未配置时使用示例转写）" : "（未配置）");
      }
    });
  });
}

function savePlans() {
  var items = (window._planItems || []).map(function(p, i) {
    var price = parseInt((getEl("plan-price-" + i) || { value: p.price_cents }).value) || p.price_cents;
    return {
      id: p.id, tier: p.tier, months: p.months, title: p.title,
      price_cents: price,
      per_month_cents: Math.round(price / p.months),
    };
  });
  apiPost("/admin/api/settings/plans", items).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    toast("套餐价格已保存", "success");
    loadPlanQuotaAsr();
  });
}

function saveQuota() {
  var body = {
    daily_token_limit_free: parseInt((getEl("q-free") || {}).value) || 0,
    daily_token_limit_basic: parseInt((getEl("q-basic") || {}).value) || 0,
    daily_token_limit_premium: parseInt((getEl("q-premium") || {}).value) || 0,
  };
  var pct = parseFloat((getEl("q-budget-ratio") || {}).value);
  if (!isNaN(pct)) body.budget_ratio = Math.max(0, Math.min(1, pct / 100));
  var nmChat = parseInt((getEl("q-nm-chat") || {}).value);
  if (!isNaN(nmChat)) body.nonmember_daily_chat_tokens = nmChat;
  var nmCapTok = parseInt((getEl("q-nm-cap-tok") || {}).value);
  if (!isNaN(nmCapTok)) body.nonmember_daily_capture_tokens = nmCapTok;
  var nmCapSec = parseInt((getEl("q-nm-cap-sec") || {}).value);
  if (!isNaN(nmCapSec)) body.nonmember_daily_capture_seconds = nmCapSec;
  apiPost("/admin/api/settings/quota", body).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    toast("限额已保存", "success");
  });
}

function saveAsr() {
  // 管理台只管理云端方式；本地方式由部署脚本配置
  var body = {
    mode: "cloud",
    base_url: (getEl("asr-base-url") || { value: "" }).value.trim(),
    model: (getEl("asr-model") || { value: "" }).value.trim(),
  };
  var key = (getEl("asr-api-key") || { value: "" }).value.trim();
  if (key) body.api_key = key;
  apiPost("/admin/api/settings/asr", body).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    if (getEl("asr-api-key")) getEl("asr-api-key").value = "";
    toast("ASR 配置已保存", "success");
    loadPlanQuotaAsr();
  });
}

// ============================================================
// Edit Modal
// ============================================================
function openEditModal(uid) {
  getEl("edit-user-id").value = uid;
  getEl("edit-display-name").value = "";
  getEl("edit-plan").value = "";
  getEl("edit-balance").value = "";
  getEl("edit-balance-delta").value = "";
  getEl("edit-banned").value = "";
  getEl("edit-notes").value = "";
  getEl("modal-title").textContent = "\u7f16\u8f91\u7528\u6237";
  getEl("edit-modal").classList.add("show");

  apiGet("/admin/api/users/" + encodeURIComponent(uid)).then(function(r) {
    if (!r || !r.ok) return;
    r.json().then(function(d) {
      var u = d.user;
      if (u.display_name) getEl("edit-display-name").value = u.display_name;
      getEl("edit-plan").value = u.plan;
      getEl("edit-balance").value = u.balance_cents;
      if (u.is_banned) getEl("edit-banned").value = "true";
      if (u.admin_notes) getEl("edit-notes").value = u.admin_notes;
    });
  });
}

function closeEditModal() {
  getEl("edit-modal").classList.remove("show");
}

function submitEdit() {
  var uid = getEl("edit-user-id").value;
  var body = {};
  var dn = (getEl("edit-display-name") || { value: "" }).value.trim();
  var plan = (getEl("edit-plan") || { value: "" }).value;
  var bal = (getEl("edit-balance") || { value: "" }).value;
  var balDelta = (getEl("edit-balance-delta") || { value: "" }).value.trim();
  var banned = (getEl("edit-banned") || { value: "" }).value;
  var notes = (getEl("edit-notes") || { value: "" }).value;

  if (dn) body.display_name = dn;
  if (plan) body.plan = plan;
  if (bal !== "") body.balance_cents = parseInt(bal);
  if (balDelta !== "") body.balance_delta_cents = parseInt(balDelta);
  if (banned) body.is_banned = banned === "true";
  body.admin_notes = notes || null;

  apiPatch("/admin/api/users/" + encodeURIComponent(uid), body).then(function(r) {
    if (!r) return;
    if (!r.ok) {
      r.json().then(function(d) { toast(d && d.detail ? d.detail : "\u4fdd\u5b58\u5931\u8d25", "error"); }).catch(function() { toast("\u4fdd\u5b58\u5931\u8d25", "error"); });
      return;
    }
    closeEditModal();
    toast("\u4fdd\u5b58\u6210\u529f", "success");
    if (state.currentTab === "user_detail" && state.userDetailId === uid) {
      loadUserDetail();
    } else {
      loadUsers();
    }
  });
}

// ============================================================
// Settings Page
// ============================================================
var MODEL_PRESETS = {
  ark: { label: "\u706b\u5c71\u65b9\u821f\uff08\u8c46\u5305\uff09", base_url: "https://ark.cn-beijing.volces.com/api/v3", model: "doubao-seed-1-6-251015" },
  deepseek: { label: "DeepSeek", base_url: "https://api.deepseek.com/v1", model: "deepseek-chat" },
  qwen: { label: "\u901a\u4e49\u5343\u95ee\uff08\u963f\u91cc\uff09", base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus" },
  moonshot: { label: "Kimi\uff08\u6708\u4e4b\u6697\u9762\uff09", base_url: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k" },
  zhipu: { label: "\u667a\u8c31 GLM", base_url: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash" },
  custom: { label: "\u81ea\u5b9a\u4e49\uff08OpenAI \u517c\u5bb9\uff09", base_url: "", model: "" },
};

function renderSettingsPage() {
  var presetOptions = Object.keys(MODEL_PRESETS).map(function(key) {
    return '<option value="' + key + '">' + esc(MODEL_PRESETS[key].label) + "</option>";
  }).join("");
  return [
    '<div class="page-header"><h1>\u7cfb\u7edf\u8bbe\u7f6e</h1></div>',

    '<div class="card">',
    "  <h2>AI \u6a21\u578b\u5bf9\u63a5 <span class=\"subtitle\">\u652f\u6301\u4efb\u610f OpenAI \u517c\u5bb9\u670d\u52a1\uff0c\u4fdd\u5b58\u540e\u7acb\u5373\u751f\u6548\uff0c\u65e0\u9700\u91cd\u542f</span></h2>",
    '  <div class="form-grid">',
    '    <div class="form-group"><label>\u670d\u52a1\u5546</label><select id="ms-provider" onchange="applyModelPreset()">' + presetOptions + "</select></div>",
    '    <div class="form-group"><label>Base URL</label><input type="text" id="ms-base-url" placeholder="https://..." /></div>',
    '    <div class="form-group"><label>\u6a21\u578b\u540d\u79f0</label><input type="text" id="ms-model" placeholder="\u5982 deepseek-chat" /></div>',
    '    <div class="form-group"><label>API Key <span class="hint" id="ms-key-status"></span></label>',
    '      <input type="password" id="ms-api-key" placeholder="\u7559\u7a7a\u4fdd\u6301\u4e0d\u53d8" autocomplete="new-password" /></div>',
    '    <div class="form-group"><label>Bot/\u667a\u80fd\u4f53 ID\uff08\u4ec5\u65b9\u821f\u5e94\u7528\u9700\u8981\uff09</label><input type="text" id="ms-bot-id" placeholder="\u9009\u586b" /></div>',
    '    <div class="form-group"><label>\u8d85\u65f6\uff08\u79d2\uff09</label><input type="number" id="ms-timeout" min="5" max="300" step="1" /></div>',
    '    <div class="form-group"><label>\u8f93\u5165\u4ef7\u683c\uff08\u5206/\u767e\u4e07 tokens\uff09</label><input type="number" id="ms-in-price" min="0" step="0.01" /></div>',
    '    <div class="form-group"><label>\u8f93\u51fa\u4ef7\u683c\uff08\u5206/\u767e\u4e07 tokens\uff09</label><input type="number" id="ms-out-price" min="0" step="0.01" /></div>',
    "  </div>",
    '  <div class="hint" style="margin:6px 0 12px">\u4ef7\u683c\u4ec5\u7528\u4e8e\u300c\u6570\u636e\u6982\u89c8\u300d\u4e2d\u7684\u652f\u51fa\u4f30\u7b97\uff0c\u8bf7\u6309\u6240\u9009\u6a21\u578b\u7684\u5b98\u65b9\u62a5\u4ef7\u586b\u5199\u3002</div>',
    '  <div class="btn-row" style="justify-content:flex-start">',
    '    <button class="btn btn-primary" onclick="saveModelSettings()">\u4fdd\u5b58\u6a21\u578b\u914d\u7f6e</button>',
    '    <button class="btn btn-secondary" onclick="testModelSettings()">\u6d4b\u8bd5\u8fde\u63a5</button>',
    '    <span id="ms-test-result" class="hint"></span>',
    "  </div>",
    "</div>",

    '<div class="card">',
    '  <h2>高级会员实时语音大模型 <span class="subtitle">OpenAI 兼容 Realtime API（WebSocket）；后端只转发音频并注入场景/护栏，结束评分</span></h2>',
    '  <div class="form-grid">',
    '    <div class="form-group"><label>Base URL（wss://）</label><input type="text" id="rt-base-url" placeholder="wss://api.openai.com/v1/realtime" /></div>',
    '    <div class="form-group"><label>模型</label><input type="text" id="rt-model" placeholder="gpt-4o-realtime-preview" /></div>',
    '    <div class="form-group"><label>音色</label><input type="text" id="rt-voice" placeholder="alloy" /></div>',
    '    <div class="form-group"><label>API Key <span class="hint" id="rt-key-status"></span></label>',
    '      <input type="password" id="rt-api-key" placeholder="留空保持不变" autocomplete="new-password" /></div>',
    '    <div class="form-group"><label>输入·文本（分/百万token）</label><input type="number" id="rt-price-in-text" min="0" step="0.01" /></div>',
    '    <div class="form-group"><label>输入·音频（分/百万token）</label><input type="number" id="rt-price-in-audio" min="0" step="0.01" /></div>',
    '    <div class="form-group"><label>输出·文本（分/百万token）</label><input type="number" id="rt-price-out-text" min="0" step="0.01" /></div>',
    '    <div class="form-group"><label>输出·音频（分/百万token）</label><input type="number" id="rt-price-out-audio" min="0" step="0.01" /></div>',
    "  </div>",
    '  <div class="hint" style="margin:6px 0 12px">仅高级会员、且选择「沉浸式 + 语音大模型」时使用；未配置时该功能不可用。音频 token 远贵于文本，按你的语音模型官方报价分别填写；用量计入用户当月费用额度（会员月费的 50%）。</div>',
    '  <div class="btn-row" style="justify-content:flex-start">',
    '    <button class="btn btn-primary" onclick="saveRealtimeSettings()">保存语音模型配置</button>',
    '    <button class="btn btn-secondary" onclick="testRealtimeSettings()">测试连接</button>',
    '    <span id="rt-test-result" class="hint"></span>',
    "  </div>",
    "</div>",

    renderPlanQuotaCards(),
  ].join("");
}

function loadRealtimeSettings() {
  apiGet("/admin/api/settings/realtime").then(function(r) {
    if (!r || !r.ok) return;
    r.json().then(function(d) {
      if (getEl("rt-base-url")) getEl("rt-base-url").value = d.base_url || "";
      if (getEl("rt-model")) getEl("rt-model").value = d.model || "";
      if (getEl("rt-voice")) getEl("rt-voice").value = d.voice || "";
      if (getEl("rt-price-in-text")) getEl("rt-price-in-text").value = d.input_text_price_per_1m_cents;
      if (getEl("rt-price-in-audio")) getEl("rt-price-in-audio").value = d.input_audio_price_per_1m_cents;
      if (getEl("rt-price-out-text")) getEl("rt-price-out-text").value = d.output_text_price_per_1m_cents;
      if (getEl("rt-price-out-audio")) getEl("rt-price-out-audio").value = d.output_audio_price_per_1m_cents;
      var ks = getEl("rt-key-status");
      if (ks) ks.textContent = d.api_key_configured ? "（已配置：" + d.api_key_masked + "）" : "（未配置）";
    });
  });
}

function saveRealtimeSettings() {
  var body = {
    base_url: (getEl("rt-base-url") || { value: "" }).value.trim(),
    model: (getEl("rt-model") || { value: "" }).value.trim(),
    voice: (getEl("rt-voice") || { value: "" }).value.trim(),
  };
  var apiKey = (getEl("rt-api-key") || { value: "" }).value.trim();
  if (apiKey) body.api_key = apiKey;
  var priceFields = [
    ["rt-price-in-text", "input_text_price_per_1m_cents"],
    ["rt-price-in-audio", "input_audio_price_per_1m_cents"],
    ["rt-price-out-text", "output_text_price_per_1m_cents"],
    ["rt-price-out-audio", "output_audio_price_per_1m_cents"],
  ];
  priceFields.forEach(function(pair) {
    var v = parseFloat((getEl(pair[0]) || { value: "" }).value);
    if (!isNaN(v)) body[pair[1]] = v;
  });
  apiPost("/admin/api/settings/realtime", body).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    getEl("rt-api-key").value = "";
    toast("语音模型配置已保存", "success");
    loadRealtimeSettings();
  });
}

function testRealtimeSettings() {
  var resultEl = getEl("rt-test-result");
  if (resultEl) { resultEl.textContent = "握手测试中…"; resultEl.style.color = ""; }
  // 测试的是已保存的配置；如刚改过请先点「保存语音模型配置」
  apiPost("/admin/api/settings/realtime/test").then(function(r) {
    if (!r) return;
    r.json().then(function(d) {
      if (resultEl) {
        resultEl.textContent = d.message || (d.ok ? "连接成功" : "连接失败");
        resultEl.style.color = d.ok ? "var(--success, #16a34a)" : "var(--danger, #dc2626)";
      }
      toast(d.message || "测试完成", d.ok ? "success" : "error");
    });
  }).catch(function() {
    if (resultEl) resultEl.textContent = "网络错误";
  });
}

function applyModelPreset() {
  var key = (getEl("ms-provider") || { value: "custom" }).value;
  var preset = MODEL_PRESETS[key];
  if (!preset) return;
  if (preset.base_url) getEl("ms-base-url").value = preset.base_url;
  if (preset.model) getEl("ms-model").value = preset.model;
}

function loadModelSettings() {
  apiGet("/admin/api/settings/model").then(function(r) {
    if (!r || !r.ok) return;
    r.json().then(function(d) {
      var providerEl = getEl("ms-provider");
      if (providerEl) providerEl.value = MODEL_PRESETS[d.provider] ? d.provider : "custom";
      if (getEl("ms-base-url")) getEl("ms-base-url").value = d.base_url || "";
      if (getEl("ms-model")) getEl("ms-model").value = d.model || "";
      if (getEl("ms-bot-id")) getEl("ms-bot-id").value = d.bot_id || "";
      if (getEl("ms-timeout")) getEl("ms-timeout").value = d.timeout_seconds || 40;
      if (getEl("ms-in-price")) getEl("ms-in-price").value = d.input_price_per_1m_cents;
      if (getEl("ms-out-price")) getEl("ms-out-price").value = d.output_price_per_1m_cents;
      var keyStatus = getEl("ms-key-status");
      if (keyStatus) {
        keyStatus.textContent = d.api_key_configured
          ? "\uff08\u5df2\u914d\u7f6e\uff1a" + d.api_key_masked + "\uff09"
          : "\uff08\u672a\u914d\u7f6e\uff0cAI \u529f\u80fd\u5c06\u4f7f\u7528\u5185\u7f6e\u6a21\u677f\u515c\u5e95\uff09";
      }
    });
  });
}

function saveModelSettings() {
  var body = {
    provider: (getEl("ms-provider") || { value: "custom" }).value,
    base_url: (getEl("ms-base-url") || { value: "" }).value.trim(),
    model: (getEl("ms-model") || { value: "" }).value.trim(),
    bot_id: (getEl("ms-bot-id") || { value: "" }).value.trim(),
  };
  var apiKey = (getEl("ms-api-key") || { value: "" }).value.trim();
  if (apiKey) body.api_key = apiKey;
  var timeout = parseFloat((getEl("ms-timeout") || { value: "" }).value);
  if (!isNaN(timeout)) body.timeout_seconds = timeout;
  var inPrice = parseFloat((getEl("ms-in-price") || { value: "" }).value);
  if (!isNaN(inPrice)) body.input_price_per_1m_cents = inPrice;
  var outPrice = parseFloat((getEl("ms-out-price") || { value: "" }).value);
  if (!isNaN(outPrice)) body.output_price_per_1m_cents = outPrice;

  if (!body.base_url) { toast("\u8bf7\u586b\u5199 Base URL", "error"); return; }
  if (!body.model && !body.bot_id) { toast("\u8bf7\u586b\u5199\u6a21\u578b\u540d\u79f0\u6216 Bot ID", "error"); return; }

  apiPost("/admin/api/settings/model", body).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    getEl("ms-api-key").value = "";
    toast("\u6a21\u578b\u914d\u7f6e\u5df2\u4fdd\u5b58", "success");
    loadModelSettings();
  });
}

function testModelSettings() {
  var resultEl = getEl("ms-test-result");
  if (resultEl) resultEl.textContent = "\u6d4b\u8bd5\u4e2d\u2026";
  apiPost("/admin/api/settings/model/test").then(function(r) {
    if (!r) return;
    r.json().then(function(d) {
      if (resultEl) {
        resultEl.textContent = d.message || (d.ok ? "\u8fde\u63a5\u6210\u529f" : "\u8fde\u63a5\u5931\u8d25");
        resultEl.style.color = d.ok ? "var(--success, #16a34a)" : "var(--danger, #dc2626)";
      }
      toast(d.message || "\u6d4b\u8bd5\u5b8c\u6210", d.ok ? "success" : "error");
    });
  }).catch(function() {
    if (resultEl) resultEl.textContent = "\u7f51\u7edc\u9519\u8bef";
  });
}

function loadSettings() {
  loadModelSettings();
  loadRealtimeSettings();
  loadPlanQuotaAsr();
}

// ============================================================
// Admin Management Page
// ============================================================
function renderAdminMgmtPage() {
  return [
    '<div class="page-header"><h1>\u7ba1\u7406\u5458\u7ba1\u7406</h1><div class="actions">',
    '<button class="btn btn-primary" onclick="openAdminCreateModal()">+ \u65b0\u5efa\u7ba1\u7406\u5458</button>',
    '<button class="btn btn-secondary" onclick="loadAdminList()">\u5237\u65b0</button>',
    "</div></div>",
    '<div class="card">',
    '  <div class="search-bar">',
    '    <input type="text" id="admin-search" placeholder="\u641c\u7d22\u7528\u6237\u540d\u3001\u59d3\u540d..." onkeydown="if(event.key===\'Enter\')loadAdminList()" />',
    '    <select id="admin-role-filter" onchange="loadAdminList()">',
    '      <option value="">\u5168\u90e8\u89d2\u8272</option>',
    '      <option value="superadmin">\u8d85\u7ea7\u7ba1\u7406\u5458</option>',
    '      <option value="admin">\u7ba1\u7406\u5458</option>',
    '      <option value="operator">\u8fd0\u7ef4</option>',
    "    </select>",
    '    <button class="btn btn-secondary" onclick="resetAdminSearch()">\u91cd\u7f6e</button>',
    "  </div>",
    '  <div id="admin-list-container">' + loadingHTML() + '</div>',
    "</div>",
  ].join("");
}

function loadAdminList() {
  var container = getEl('admin-list-container');
  if (!container) return;
  container.innerHTML = loadingHTML();

  var q = (getEl('admin-search') || { value: '' }).value.trim();
  var role = (getEl('admin-role-filter') || { value: '' }).value;

  var url = '/admin/api/admins?limit=50';
  if (q) url += '&q=' + encodeURIComponent(q);
  if (role) url += '&role=' + encodeURIComponent(role);

  apiGet(url).then(function(r) {
    if (!r) return;
    if (r.status === 401 || r.status === 403) { handleApiError(r); return; }
    r.json().then(function(d) {
      var items = d.items || [];
      if (!items.length) {
        container.innerHTML = emptyHTML('\u6682\u65e0\u7ba1\u7406\u5458');
        return;
      }
      var rows = items.map(function(a) {
        var isSelf = String(a.id) === String(state.currentAdminId);
        var roleLabel = roleName(a.role);
        return [
          '<tr>',
          '<td>' + esc(a.username) + (isSelf ? ' <span class="badge badge-pro">\u5f53\u524d</span>' : '') + '</td>',
          '<td>' + esc(a.display_name || '\u2014') + '</td>',
          '<td>' + esc(a.email || '\u2014') + '</td>',
          '<td><span class="badge badge-' + (a.role === 'superadmin' ? 'pro' : 'free') + '">' + roleLabel + '</span></td>',
          '<td>' + (a.is_active ? badge('active') : badge('banned')) + '</td>',
          '<td>' + fmtDT(a.last_login_at) + '</td>',
          '<td>' + fmtDT(a.created_at) + '</td>',
          '<td class="table-actions">',
          '<button class="btn btn-primary btn-sm" onclick="openAdminEditModal(\'' + String(a.id).replace(/'/g, "\\'") + '\')">\u7f16\u8f91</button>',
          isSelf ? '' : '<button class="btn btn-danger btn-sm" onclick="deleteAdmin(\'' + String(a.id).replace(/'/g, "\\'") + '\', \'' + esc(a.username).replace(/'/g, "\\'") + '\')">\u5220\u9664</button>',
          '</td>',
          '</tr>',
        ].join('');
      }).join('');

      container.innerHTML = [
        '<div class="table-wrap">',
        '<table><thead><tr><th>\u7528\u6237\u540d</th><th>\u59d3\u540d</th><th>\u90ae\u7bb1</th><th>\u89d2\u8272</th><th>\u72b6\u6001</th><th>\u6700\u8fd1\u767b\u5f55</th><th>\u521b\u5efa\u65f6\u95f4</th><th>\u64cd\u4f5c</th></tr></thead>',
        '<tbody>' + rows + '</tbody></table></div>',
        '<div class="pagination-info"><span>\u5171 ' + d.total + ' \u6761</span></div>',
      ].join('');
    });
  }).catch(function() {
    var container = getEl('admin-list-container');
    if (container) container.innerHTML = emptyHTML('\u52a0\u8f7d\u5931\u8d25');
  });
}

function resetAdminSearch() {
  var el = getEl('admin-search');
  var roleEl = getEl('admin-role-filter');
  if (el) el.value = '';
  if (roleEl) roleEl.value = '';
  loadAdminList();
}

function openAdminCreateModal() {
  getEl("ac-form").reset();
  getEl("admin-create-modal").classList.add("show");
}

function closeAdminCreateModal() {
  getEl("admin-create-modal").classList.remove("show");
}

function submitAdminCreate() {
  var username = (getEl("ac-username") || { value: '' }).value.trim();
  var password = (getEl("ac-password") || { value: '' }).value;
  var role = (getEl("ac-role") || { value: 'admin' }).value;
  var displayName = (getEl("ac-display-name") || { value: '' }).value.trim();
  var email = (getEl("ac-email") || { value: '' }).value.trim();

  if (!username || username.length < 3) { toast('\u7528\u6237\u540d\u81f3\u5c111\u4e2a\u5b57\u7b26', 'error'); return; }
  if (!/^[a-zA-Z0-9_]+$/.test(username)) { toast('\u7528\u6237\u540d\u53ea\u80fd\u5305\u542b\u5b57\u6bcd\u3001\u6570\u5b57\u548c\u4e0b\u5212\u7ebf', 'error'); return; }
  if (!password || password.length < 8) { toast('\u5bc6\u7801\u81f3\u5c118\u4e2a\u5b57\u7b26', 'error'); return; }

  apiPost('/admin/api/admins', {
    username: username,
    password: password,
    role: role,
    display_name: displayName || undefined,
    email: email || undefined,
  }).then(function(r) {
    if (!r) return;
    if (!r.ok) {
      r.json().catch(function() { return {}; }).then(function(d) { toast(d.detail || '\u521b\u5efa\u5931\u8d25', 'error'); });
      return;
    }
    closeAdminCreateModal();
    toast('\u7ba1\u7406\u5458\u5df2\u521b\u5efa', 'success');
    loadAdminList();
  });
}

function openAdminEditModal(adminId) {
  apiGet('/admin/api/admins?limit=50').then(function(r) {
    if (!r) return;
    r.json().then(function(d) {
      var admin = (d.items || []).find(function(a) { return String(a.id) === String(adminId); });
      if (!admin) { toast('\u7ba1\u7406\u5458\u4e0d\u5b58\u5728', 'error'); return; }
      getEl("ae-id").value = adminId;
      getEl("ae-username-display").textContent = admin.username;
      getEl("ae-password").value = '';
      getEl("ae-role").value = admin.role;
      getEl("ae-display-name").value = admin.display_name || '';
      getEl("ae-email").value = admin.email || '';
      getEl("ae-is-active").checked = admin.is_active;
      getEl("ae-is-active").disabled = (String(adminId) === String(state.currentAdminId));
      getEl("admin-edit-modal").classList.add("show");
    });
  });
}

function closeAdminEditModal() {
  getEl("admin-edit-modal").classList.remove("show");
}

function submitAdminEdit() {
  var adminId = getEl("ae-id").value;
  var password = (getEl("ae-password") || { value: '' }).value;
  var role = (getEl("ae-role") || { value: '' }).value;
  var displayName = (getEl("ae-display-name") || { value: '' }).value.trim();
  var email = (getEl("ae-email") || { value: '' }).value.trim();
  var isActive = getEl("ae-is-active").checked;

  var body = { is_active: isActive };
  if (password) body.password = password;
  if (role) body.role = role;
  body.display_name = displayName || null;
  body.email = email || null;

  apiPatch('/admin/api/admins/' + adminId, body).then(function(r) {
    if (!r) return;
    if (!r.ok) {
      r.json().catch(function() { return {}; }).then(function(d) { toast(d.detail || '\u4fdd\u5b58\u5931\u8d25', 'error'); });
      return;
    }
    closeAdminEditModal();
    toast('\u4fdd\u5b58\u6210\u529f', 'success');
    loadAdminList();
    if (String(adminId) === String(state.currentAdminId)) {
      r.json().then(function(d) {
        if (d && d.role) {
          state.currentAdminRole = d.role;
          state.currentAdminRoleName = roleName(d.role);
          updateSidebarAdmin();
        }
      });
    }
  });
}

function deleteAdmin(adminId, username) {
  confirmDialog('\u5220\u9664\u7ba1\u7406\u5458', '\u786e\u5b9a\u8981\u5220\u9664\u7ba1\u7406\u5458 ' + username + ' \u5417\uff1f\u6b64\u64cd\u4f5c\u4e0d\u53ef\u6062\u590d\u3002', function() {
    apiFetch('/admin/api/admins/' + adminId, { method: 'DELETE' }).then(function(r) {
      if (!r) return;
      if (r.status === 204 || r.ok) {
        toast('\u7ba1\u7406\u5458\u5df2\u5220\u9664', 'success');
        loadAdminList();
      } else {
        r.json().catch(function() { return {}; }).then(function(d) { toast(d.detail || '\u5220\u9664\u5931\u8d25', 'error'); });
      }
    });
  });
}

// ============================================================
// Change Own Password
// ============================================================
function openChangePasswordModal() {
  getEl("cp-form").reset();
  getEl("change-password-modal").classList.add("show");
}

function closeChangePasswordModal() {
  getEl("change-password-modal").classList.remove("show");
}

function submitChangePassword() {
  var oldPw = (getEl("cp-old") || { value: '' }).value;
  var newPw = (getEl("cp-new") || { value: '' }).value;
  var confirmPw = (getEl("cp-confirm") || { value: '' }).value;

  if (!oldPw || oldPw.length < 6) { toast('\u8bf7\u8f93\u5165\u5f53\u524d\u5bc6\u7801', 'error'); return; }
  if (!newPw || newPw.length < 8) { toast('\u65b0\u5bc6\u7801\u81f3\u5c118\u4f4d', 'error'); return; }
  if (newPw !== confirmPw) { toast('\u4e24\u6b21\u5bc6\u7801\u4e0d\u4e00\u81f4', 'error'); return; }
  if (newPw === oldPw) { toast('\u65b0\u5bc6\u7801\u4e0d\u80fd\u4e0e\u5f53\u524d\u5bc6\u7801\u76f8\u540c', 'error'); return; }

  apiPost('/admin/api/password/change', {
    old_password: oldPw,
    new_password: newPw,
  }).then(function(r) {
    if (!r) return;
    if (!r.ok) {
      r.json().catch(function() { return {}; }).then(function(d) { toast(d.detail || '\u4fee\u6539\u5931\u8d25', 'error'); });
      return;
    }
    closeChangePasswordModal();
    toast('\u5bc6\u7801\u4fee\u6539\u6210\u529f\uff0c\u8bf7\u7528\u65b0\u5bc6\u7801\u91cd\u65b0\u767b\u5f55', 'success');
    // \u670d\u52a1\u7aef\u5df2\u9500\u6bc1\u5168\u90e8\u4f1a\u8bdd\uff0c\u56de\u5230\u767b\u5f55\u9875
    resetAdminState();
    renderApp();
  });
}

// ============================================================
// Update Sidebar Admin Info
// ============================================================
function updateSidebarAdmin() {
  var nameEl = getEl('sidebar-admin-name');
  var roleEl = getEl('sidebar-admin-role');
  if (nameEl) nameEl.textContent = state.currentAdminUsername || 'Admin';
  if (roleEl) roleEl.textContent = state.currentAdminRoleName || '';
}

// ============================================================
// 通用场景目录（主/子场景，只存标题；用户没有录音时直接选场景与 AI 练口语）
// ============================================================
function renderPresetsPage() {
  return [
    '<div class="page-header"><h1>通用场景</h1>',
    '  <p class="subtitle">运维预置的全局场景（所有用户可见可练）。每个场景保存完整中英文对话，格式与用户自采集场景一致；可点「用 AI 生成草稿」自动生成后再修改保存，随时可改。</p>',
    "</div>",
    '<div id="presets-root"><div class="card">加载中…</div></div>',
  ].join("");
}

var PRESET_DEFAULT_ROLES = [
  { id: "self", name: "我", description: "用户可扮演的角色", is_user_candidate: true },
  { id: "counterpart", name: "对方", description: "另一位对话角色", is_user_candidate: true },
];

function loadPresets() {
  window._presetEditing = null;
  apiGet("/admin/api/presets").then(function(r) {
    if (!r || !r.ok) { handleApiError(r); return; }
    r.json().then(function(d) {
      window._presetScenes = d.items || [];
      renderPresetsRoot();
    });
  });
}

function renderPresetsRoot() {
  var root = getEl("presets-root");
  if (!root) return;
  if (window._presetEditing) { root.innerHTML = presetEditorHtml(); return; }
  var scenes = window._presetScenes || [];
  var groups = {}; var order = [];
  scenes.forEach(function(s) {
    var g = s.group || "通用场景";
    if (!groups[g]) { groups[g] = []; order.push(g); }
    groups[g].push(s);
  });
  var body = order.map(function(g) {
    var rows = groups[g].map(function(s) {
      return [
        '<div style="display:flex;gap:10px;align-items:center;padding:8px 0;border-top:1px solid var(--border,#eee)">',
        '  <div style="flex:1"><b>' + esc(s.title) + "</b> <span class=\"hint\">· " + s.line_count + " 句</span></div>",
        '  <button class="btn btn-sm" onclick="presetEditScene(\'' + s.scene_id + "')\">编辑</button>",
        '  <button class="btn btn-sm btn-danger" onclick="presetDeleteScene(\'' + s.scene_id + "','" + esc(s.title) + "')\">删除</button>",
        "</div>",
      ].join("");
    }).join("");
    return '<div class="card" style="margin-bottom:14px"><h2 style="margin:0 0 4px">' + esc(g) + "</h2>" + rows + "</div>";
  }).join("");
  if (!scenes.length) body = '<div class="card"><p class="hint">还没有预置场景。点「新增场景」创建第一个。</p></div>';
  root.innerHTML = body +
    '<div style="margin-top:6px"><button class="btn btn-primary" onclick="presetNewScene()">+ 新增场景</button></div>';
}

function presetNewScene() {
  window._presetEditing = { scene_id: null, group: "", title: "", summary: "",
    roles: PRESET_DEFAULT_ROLES.map(function(r){return Object.assign({}, r);}), lines: [], sort: 0 };
  renderPresetsRoot();
}

function presetEditScene(sceneId) {
  var s = (window._presetScenes || []).filter(function(x){return x.scene_id === sceneId;})[0];
  if (!s) return;
  window._presetEditing = JSON.parse(JSON.stringify(s));
  if (!window._presetEditing.roles || !window._presetEditing.roles.length) {
    window._presetEditing.roles = PRESET_DEFAULT_ROLES.map(function(r){return Object.assign({}, r);});
  }
  renderPresetsRoot();
}

function presetCancelEdit() { window._presetEditing = null; renderPresetsRoot(); }

function presetEditorHtml() {
  var e = window._presetEditing;
  var roleOpts = function(sel) {
    return (e.roles || []).map(function(r) {
      return '<option value="' + esc(r.id) + '"' + (r.id === sel ? " selected" : "") + ">" + esc(r.name) + "</option>";
    }).join("");
  };
  var lineRows = (e.lines || []).map(function(l, i) {
    return [
      '<tr>',
      '<td>' + (i + 1) + "</td>",
      '<td><select onchange="presetSetLine(' + i + ",'target_role',this.value)\">" + roleOpts(l.target_role) + "</select></td>",
      '<td><input type="text" value="' + esc(l.source_text || "") + '" placeholder="中文" style="width:100%" oninput="presetSetLine(' + i + ",'source_text',this.value)\" /></td>",
      '<td><input type="text" value="' + esc(l.english || "") + '" placeholder="English" style="width:100%" oninput="presetSetLine(' + i + ",'english',this.value)\" /></td>",
      '<td><button class="btn btn-sm btn-danger" onclick="presetDeleteLine(' + i + ')">删</button></td>',
      "</tr>",
    ].join("");
  }).join("");
  return [
    '<div class="card">',
    '  <h2 style="margin-top:0">' + (e.scene_id ? "编辑场景" : "新增场景") + "</h2>",
    '  <div class="form-grid">',
    '    <div class="form-group"><label>主场景（分组）</label><input type="text" id="pe-group" value="' + esc(e.group || "") + '" placeholder="如 日常生活场景" oninput="presetEditField(\'group\',this.value)" /></div>',
    '    <div class="form-group"><label>子场景标题</label><input type="text" id="pe-title" value="' + esc(e.title || "") + '" placeholder="如 外出就餐" oninput="presetEditField(\'title\',this.value)" /></div>',
    "  </div>",
    '  <div class="form-group"><label>场景简介</label><input type="text" value="' + esc(e.summary || "") + '" placeholder="一句话描述这个场景" oninput="presetEditField(\'summary\',this.value)" /></div>',
    '  <div style="display:flex;gap:10px;align-items:center;margin:8px 0">',
    '    <button class="btn" id="pe-gen" onclick="presetGenerateDraft()">✨ 用 AI 生成草稿</button>',
    '    <span class="hint">按上面的主场景/子场景标题生成约 40 句中英对话，填入下表后可自由修改。内容须健康、无政治/敏感。</span>',
    "  </div>",
    '  <div id="pe-gen-status" style="margin:4px 0 8px;font-size:13px;min-height:18px;white-space:pre-wrap"></div>',
    '  <div class="table-wrap"><table><thead><tr><th>#</th><th>角色</th><th>中文</th><th>English</th><th></th></tr></thead>',
    '  <tbody id="pe-lines">' + lineRows + "</tbody></table></div>",
    '  <button class="btn btn-sm" style="margin-top:6px" onclick="presetAddLine()">+ 添加一句</button>',
    '  <div style="margin-top:14px;display:flex;gap:10px">',
    '    <button class="btn btn-primary" onclick="presetSaveScene()">保存</button>',
    '    <button class="btn" onclick="presetCancelEdit()">取消</button>',
    "  </div>",
    "</div>",
  ].join("");
}

function presetEditField(field, val) { if (window._presetEditing) window._presetEditing[field] = val; }
function presetSetLine(i, field, val) {
  var e = window._presetEditing;
  if (e && e.lines && e.lines[i]) e.lines[i][field] = val;
}
function presetAddLine() {
  var e = window._presetEditing; if (!e) return;
  if (!e.lines) e.lines = [];
  var rid = (e.lines.length % 2 === 0) ? "self" : "counterpart";
  e.lines.push({ index: e.lines.length, speaker: "", target_role: rid, source_text: "", english: "", intent: "" });
  renderPresetsRoot();
}
function presetDeleteLine(i) {
  var e = window._presetEditing; if (!e || !e.lines) return;
  e.lines.splice(i, 1);
  renderPresetsRoot();
}

function presetSetGenStatus(msg, color) {
  var el = getEl("pe-gen-status");
  if (el) { el.textContent = msg || ""; el.style.color = color || "var(--text-2,#888)"; }
}

function presetResetGenBtn() {
  var btn = getEl("pe-gen");
  if (btn) { btn.disabled = false; btn.textContent = "✨ 用 AI 生成草稿"; }
}

function presetGenerateDraft() {
  var e = window._presetEditing; if (!e) return;
  var group = (e.group || "").trim(); var title = (e.title || "").trim();
  if (!title) { toast("请先填写子场景标题", "error"); presetSetGenStatus("请先填写子场景标题", "#d33"); return; }
  var btn = getEl("pe-gen"); if (btn) { btn.disabled = true; btn.textContent = "正在生成…（最长约 1 分钟）"; }
  presetSetGenStatus("正在调用 AI 生成对话，请稍候…（大模型生成约 40 句可能需要数十秒）", "var(--text-2,#888)");
  apiPost("/admin/api/presets/generate", { group: group, title: title }).then(function(r) {
    presetResetGenBtn();
    if (!r) { presetSetGenStatus("请求未发出：请确认仍处于登录状态、网络正常。", "#d33"); return; }
    if (!r.ok) {
      r.json().catch(function() { return {}; }).then(function(d) {
        var msg = (d && d.detail) ? d.detail : ("生成失败：HTTP " + r.status);
        presetSetGenStatus("❌ " + msg, "#d33");
        toast(msg, "error");
      });
      return;
    }
    r.json().then(function(d) {
      e.roles = (d.roles && d.roles.length) ? d.roles : e.roles;
      e.lines = (d.lines || []).map(function(l) {
        return { index: l.index, speaker: l.speaker || "", target_role: l.target_role, source_text: l.source_text, english: l.english, intent: l.intent || "" };
      });
      if (!e.summary) e.summary = d.summary || "";
      renderPresetsRoot();
      toast("已生成草稿，请检查/修改后保存", "success");
    });
  }).catch(function(err) {
    presetResetGenBtn();
    presetSetGenStatus("❌ 网络错误：" + ((err && err.message) ? err.message : "请求失败，请重试"), "#d33");
  });
}

function presetSaveScene() {
  var e = window._presetEditing; if (!e) return;
  var title = (e.title || "").trim();
  if (!title) { toast("子场景标题不能为空", "error"); return; }
  var lines = (e.lines || []).filter(function(l){ return (l.source_text||"").trim() || (l.english||"").trim(); });
  if (!lines.length) { toast("至少要有一句对话", "error"); return; }
  for (var i = 0; i < lines.length; i++) {
    if (!(lines[i].source_text||"").trim() || !(lines[i].english||"").trim()) {
      toast("第 " + (i + 1) + " 句的中文和英文都要填写", "error"); return;
    }
  }
  var payload = {
    scene_id: e.scene_id || null,
    group: (e.group || "").trim(),
    title: title,
    summary: (e.summary || "").trim(),
    roles: e.roles || PRESET_DEFAULT_ROLES,
    lines: lines.map(function(l, idx) {
      return { index: idx, speaker: l.speaker || "", target_role: l.target_role || "self",
               source_text: (l.source_text||"").trim(), english: (l.english||"").trim(), intent: l.intent || "" };
    }),
    expressions: [],
    sort: e.sort || 0,
  };
  apiPost("/admin/api/presets", payload).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    toast("场景已保存", "success");
    loadPresets();
  });
}

function presetDeleteScene(sceneId, title) {
  if (!confirm("确定删除场景「" + title + "」？删除后用户将无法再练习它。")) return;
  apiFetch("/admin/api/presets/" + encodeURIComponent(sceneId), { method: "DELETE" }).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    toast("已删除", "success");
    loadPresets();
  });
}

// ============================================================
// Main render
// ============================================================
function renderApp(loginOpts) {
  var app = getEl("app");
  if (!app) return;

  // Not logged in
  if (!state.loggedIn) {
    app.innerHTML = renderLogin(loginOpts && loginOpts.loginError);
    var form = getEl("login-form");
    if (form) form.onsubmit = handleLogin;
    return;
  }

  // Build page content
  var pageContent = "";
  if (state.currentTab === "overview") pageContent = renderOverviewPage();
  else if (state.currentTab === "users") pageContent = renderUsersPage();
  else if (state.currentTab === "user_detail") pageContent = renderUserDetailPage();
  else if (state.currentTab === "orders") pageContent = renderOrdersPage();
  else if (state.currentTab === "tickets") pageContent = renderTicketsPage();
  else if (state.currentTab === "presets") pageContent = renderPresetsPage();
  else if (state.currentTab === "usage") pageContent = renderUsagePage();
  else if (state.currentTab === "admins") pageContent = renderAdminMgmtPage();
  else if (state.currentTab === "settings") pageContent = renderSettingsPage();

  // Build layout
  app.innerHTML = [
    renderSidebar(),
    '<main class="main-content">' + pageContent + "</main>",

    // User edit modal
    '<div id="edit-modal" class="modal-overlay" onclick="if(event.target===this)closeEditModal()">',
    '<div class="modal" onclick="event.stopPropagation()">',
    '  <h3 id="modal-title">\u7f16\u8f91\u7528\u6237</h3>',
    '  <input type="hidden" id="edit-user-id" />',
    '  <div class="form-group"><label>\u663e\u793a\u540d\u79f0</label><input type="text" id="edit-display-name" placeholder="\u7559\u7a7a\u4fdd\u6301\u4e0d\u53d8" /></div>',
    '  <div class="form-group"><label>\u8ba2\u9605\u8ba1\u5212</label>',
    '    <select id="edit-plan"><option value="">\u4fdd\u6301\u4e0d\u53d8</option><option value="free">Free</option><option value="pro">Pro</option></select>',
    "  </div>",
    '  <div class="form-group"><label>\u76f4\u63a5\u8bbe\u7f6e\u4f59\u989d\uff08\u5206\uff09</label>',
    '    <input type="number" id="edit-balance" placeholder="\u7559\u7a7a\u4fdd\u6301\u4e0d\u53d8" min="0" max="100000000" />',
    '    <div class="hint">\u76f4\u63a5\u8986\u76d6\u5f53\u524d\u4f59\u989d</div>',
    "  </div>",
    '  <div class="form-group"><label>\u4f59\u989d\u589e\u91cf\u8c03\u6574\uff08\u5206\uff09</label>',
    '    <div class="form-row"><input type="number" id="edit-balance-delta" placeholder="\u5982 +1000 \u6216 -500" />',
    '    <span class="hint">\u6b63\u6570\u589e\u52a0\uff0c\u8d1f\u6570\u51cf\u5c11</span></div>',
    "  </div>",
    '  <div class="form-group"><label>\u5c01\u7981\u72b6\u6001</label>',
    '    <select id="edit-banned"><option value="">\u4fdd\u6301\u4e0d\u53d8</option><option value="false">\u6b63\u5e38</option><option value="true">\u5c01\u7981</option></select>',
    "  </div>",
    '  <div class="form-group"><label>\u7ba1\u7406\u5907\u6ce8</label><textarea id="edit-notes" placeholder="\u8bb0\u5f55\u7ba1\u7406\u5907\u6ce8\uff08\u9009\u586b\uff09"></textarea></div>',
    '  <div class="btn-row">',
    '    <button class="btn btn-secondary" onclick="closeEditModal()">\u53d6\u6d88</button>',
    '    <button class="btn btn-primary" onclick="submitEdit()">\u4fdd\u5b58</button>',
    "  </div>",
    "</div></div>",

    // Admin create modal
    '<div id="admin-create-modal" class="modal-overlay" onclick="if(event.target===this)closeAdminCreateModal()">',
    '<div class="modal" onclick="event.stopPropagation()">',
    '  <h3>\u65b0\u5efa\u7ba1\u7406\u5458</h3>',
    '  <form id="ac-form" onsubmit="event.preventDefault();submitAdminCreate()">',
    '    <div class="form-group"><label>\u7528\u6237\u540d <span style="color:var(--danger)">*</span></label>',
    '      <input type="text" id="ac-username" placeholder="\u5b57\u6bcd\u3001\u6570\u5b57\u3001\u4e0b\u5212\u7ebf\uff0c\u81f3\u5c113\u4e2a\u5b57\u7b26" required pattern="[a-zA-Z0-9_]+" minlength="3" maxlength="32" /></div>',
    '    <div class="form-group"><label>\u5bc6\u7801 <span style="color:var(--danger)">*</span></label>',
    '      <input type="password" id="ac-password" placeholder="\u81f3\u5c118\u4e2a\u5b57\u7b26" required minlength="8" maxlength="128" /></div>',
    '    <div class="form-group"><label>\u89d2\u8272</label>',
    '      <select id="ac-role"><option value="admin">\u7ba1\u7406\u5458</option><option value="operator">\u8fd0\u7ef4</option></select></div>',
    '    <div class="form-group"><label>\u59d3\u540d</label><input type="text" id="ac-display-name" placeholder="\u9009\u586b" maxlength="80" /></div>',
    '    <div class="form-group"><label>\u90ae\u7bb1</label><input type="email" id="ac-email" placeholder="\u9009\u586b" maxlength="120" /></div>',
    '    <div class="btn-row">',
    '      <button type="button" class="btn btn-secondary" onclick="closeAdminCreateModal()">\u53d6\u6d88</button>',
    '      <button type="submit" class="btn btn-primary">\u521b\u5efa</button>',
    "    </div>",
    "  </form>",
    "</div></div>",

    // Admin edit modal
    '<div id="admin-edit-modal" class="modal-overlay" onclick="if(event.target===this)closeAdminEditModal()">',
    '<div class="modal" onclick="event.stopPropagation()">',
    '  <h3>\u7f16\u8f91\u7ba1\u7406\u5458</h3>',
    '  <input type="hidden" id="ae-id" />',
    '  <div class="form-group"><label>\u7528\u6237\u540d</label><span id="ae-username-display" style="font-weight:600;padding:9px 0;display:block"></span></div>',
    '  <div class="form-group"><label>\u65b0\u5bc6\u7801</label>',
    '    <input type="password" id="ae-password" placeholder="\u7559\u7a7a\u4e0d\u66f4\u6539" minlength="8" maxlength="128" /></div>',
    '  <div class="form-group"><label>\u89d2\u8272</label>',
    '    <select id="ae-role"><option value="superadmin">\u8d85\u7ea7\u7ba1\u7406\u5458</option><option value="admin">\u7ba1\u7406\u5458</option><option value="operator">\u8fd0\u7ef4</option></select></div>',
    '  <div class="form-group"><label>\u59d3\u540d</label><input type="text" id="ae-display-name" placeholder="\u9009\u586b" maxlength="80" /></div>',
    '  <div class="form-group"><label>\u90ae\u7bb1</label><input type="email" id="ae-email" placeholder="\u9009\u586b" maxlength="120" /></div>',
    '  <div class="form-group"><label><input type="checkbox" id="ae-is-active" style="width:auto;margin-right:6px" />\u542f\u7528\u72b6\u6001</label></div>',
    '  <div class="btn-row">',
    '    <button class="btn btn-secondary" onclick="closeAdminEditModal()">\u53d6\u6d88</button>',
    '    <button class="btn btn-primary" onclick="submitAdminEdit()">\u4fdd\u5b58</button>',
    "  </div>",
    "</div></div>",

    // Change password modal
    '<div id="change-password-modal" class="modal-overlay" onclick="if(event.target===this)closeChangePasswordModal()">',
    '<div class="modal" onclick="event.stopPropagation()">',
    '  <h3>\u4fee\u6539\u5bc6\u7801</h3>',
    '  <form id="cp-form" onsubmit="event.preventDefault();submitChangePassword()">',
    '    <div class="form-group"><label>\u5f53\u524d\u5bc6\u7801 <span style="color:var(--danger)">*</span></label>',
    '      <input type="password" id="cp-old" required minlength="6" maxlength="128" /></div>',
    '    <div class="form-group"><label>\u65b0\u5bc6\u7801 <span style="color:var(--danger)">*</span></label>',
    '      <input type="password" id="cp-new" placeholder="\u81f3\u5c116\u4f4d" required minlength="6" maxlength="128" /></div>',
    '    <div class="form-group"><label>\u786e\u8ba4\u65b0\u5bc6\u7801 <span style="color:var(--danger)">*</span></label>',
    '      <input type="password" id="cp-confirm" placeholder="\u518d\u8f93\u5165\u4e00\u6b21" required minlength="6" maxlength="128" /></div>',
    '    <div class="btn-row">',
    '      <button type="button" class="btn btn-secondary" onclick="closeChangePasswordModal()">\u53d6\u6d88</button>',
    '      <button type="submit" class="btn btn-primary">\u786e\u8ba4\u4fee\u6539</button>',
    "    </div>",
    "  </form>",
    "</div></div>",
  ].join("");

  // Update sidebar admin info
  updateSidebarAdmin();

  // Load data for current tab
  if (state.currentTab === "overview") loadOverview();
  else if (state.currentTab === "users") loadUsers();
  else if (state.currentTab === "user_detail") loadUserDetail();
  else if (state.currentTab === "orders") loadOrders();
  else if (state.currentTab === "tickets") loadTickets();
  else if (state.currentTab === "presets") loadPresets();
  else if (state.currentTab === "usage") loadUsage();
  else if (state.currentTab === "admins") loadAdminList();
  else if (state.currentTab === "settings") loadSettings();
}

// ============================================================
// Global exports for onclick handlers
// ============================================================
window.navigate = navigate;
window.logout = logout;
window.handleLogin = handleLogin;
window.searchUsers = searchUsers;
window.resetSearch = resetSearch;
window.changeLimit = changeLimit;
window.openUserDetail = openUserDetail;
window.openEditModal = openEditModal;
window.closeEditModal = closeEditModal;
window.submitEdit = submitEdit;
window.toggleBan = toggleBan;
window.loadAdminList = loadAdminList;
window.resetAdminSearch = resetAdminSearch;
window.openAdminCreateModal = openAdminCreateModal;
window.closeAdminCreateModal = closeAdminCreateModal;
window.submitAdminCreate = submitAdminCreate;
window.openAdminEditModal = openAdminEditModal;
window.closeAdminEditModal = closeAdminEditModal;
window.submitAdminEdit = submitAdminEdit;
window.deleteAdmin = deleteAdmin;
window.openChangePasswordModal = openChangePasswordModal;
window.closeChangePasswordModal = closeChangePasswordModal;
window.submitChangePassword = submitChangePassword;
window.loadOrders = loadOrders;
window.loadUsage = loadUsage;
window.savePlans = savePlans;
window.loadPresets = loadPresets;
window.presetNewScene = presetNewScene;
window.presetEditScene = presetEditScene;
window.presetCancelEdit = presetCancelEdit;
window.presetEditField = presetEditField;
window.presetSetLine = presetSetLine;
window.presetAddLine = presetAddLine;
window.presetDeleteLine = presetDeleteLine;
window.presetGenerateDraft = presetGenerateDraft;
window.presetSaveScene = presetSaveScene;
window.presetDeleteScene = presetDeleteScene;
window.saveQuota = saveQuota;
window.saveAsr = saveAsr;
window.markOrderPaid = markOrderPaid;
window.loadOverviewCharts = loadOverviewCharts;
window.applyModelPreset = applyModelPreset;
window.saveModelSettings = saveModelSettings;
window.testModelSettings = testModelSettings;
window.toast = toast;

// ============================================================
// Init
// ============================================================
document.addEventListener("DOMContentLoaded", function() {
  // 先尝试用 Cookie 恢复会话；失败再显示登录页
  restoreSession().then(function() {
    state.sessionChecked = true;
    renderApp();
  });
});
