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
  currentTab: "overview",
  userDetailId: null,
  userPage: 1,
  userQuery: "",
  userLimit: 100,
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

function logout() {
  state.loggedIn = false;
  state.currentAdminId = null;
  state.currentAdminUsername = null;
  state.currentAdminRole = null;
  state.currentAdminRoleName = null;
  state.currentTab = "overview";
  var guard = ++_renderGuard;
  fetch(API_BASE + "/admin/logout", {
    method: "POST",
    credentials: "include",
  }).then(function(r) {
    if (guard !== _renderGuard) return;
    renderApp();
  }).catch(function() {
    if (guard !== _renderGuard) return;
    renderApp();
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
    '    <div class="hint">\u9ed8\u8ba4\u8d26\u53f7\uff1aadmin / admin123456</div>',
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
    nav("admins", "\u7ba1\u7406\u5458\u7ba1\u7406", "\ud83d\udc64"),
    nav("settings", "\u4ef7\u683c\u8bbe\u7f6e", "\u2699\ufe0f"),
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
    '<div class="page-header"><h1>\u6570\u636e\u6982\u89c8</h1></div>',
    '<div class="card">',
    '  <div class="stat-grid" id="overview-stats">' + loadingHTML() + "</div>",
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
      function g(v, l) {
        return '<div class="stat-card"><div class="val">' + esc(v) + '</div><div class="lbl">' + esc(l) + "</div></div>";
      }
      var el = getEl("overview-stats");
      if (!el) return;
      el.innerHTML =
        g(d.total_users, "\u603b\u7528\u6237") +
        g(d.banned_users, "\u5df2\u5c01\u7981") +
        g(d.online_users + "/" + d.online_window_minutes + "min", "\u5728\u7ebf\u7528\u6237") +
        g(fmtYuan(d.total_balance_cents), "\u7528\u6237\u4f59\u989d\u603b\u8ba1") +
        g(fmtYuan(d.paid_recharge_cents), "\u5df2\u5145\u503c\u603b\u989d") +
        g(fmtYuan(d.pending_recharge_cents), "\u5f85\u786e\u8ba4\u5145\u503c") +
        g(d.paid_orders, "\u5df2\u652f\u4ed8\u8ba2\u5355") +
        g(d.roleplay_session_count, "\u89d2\u8272\u626e\u6f14\u4f1a\u8bdd") +
        g(d.practice_result_count, "\u7ec3\u4e60\u8bb0\u5f55") +
        g(d.transcript_count, "\u5bf9\u8bdd\u8bb0\u5f55") +
        g(fmtYuan(d.monthly_price_cents), "\u5f53\u524d\u6708\u8d39");
    });
  }).catch(function() {
    var el = getEl("overview-stats");
    if (el) el.innerHTML = emptyHTML("\u52a0\u8f7d\u5931\u8d25\uff0c\u8bf7\u68c0\u67e5\u767b\u5f55\u72b6\u6001");
  });
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
function renderSettingsPage() {
  return [
    '<div class="page-header"><h1>\u4ef7\u683c\u8bbe\u7f6e</h1></div>',
    '<div class="card">',
    "  <h2>\u6708\u8d39\u8ba2\u9605\u4ef7\u683c <span class=\"subtitle\">\u8bbe\u7f6e\u540e\u7528\u6237\u7aef\u8ba2\u9605\u4ef7\u683c\u5c06\u7acb\u5373\u66f4\u65b0</span></h2>",
    '  <div class="price-form">',
    '    <input type="number" id="price-cents" placeholder="\u5982 3000" min="100" max="1000000" step="1" />',
    '    <span class="unit">\u5206 (= \u00a5<span id="price-yuan">30.00</span>)</span>',
    '    <button class="btn btn-primary" onclick="updatePrice()">\u4fdd\u5b58</button>',
    "  </div>",
    '  <div class="hint" style="margin-top:6px">\u5355\u4f4d\u4e3a\u300c\u5206\u300d\uff0c\u5982 3000 = 30.00 \u5143</div>',
    "</div>",
    '<div class="card">',
    "  <h2>\u5f53\u524d\u8ba2\u9605\u4ef7\u683c</h2>",
    '  <div id="current-price-display">' + loadingHTML() + "</div>",
    "</div>",
  ].join("");
}

function loadSettings() {
  var display = getEl("current-price-display");
  if (!display) return;
  display.innerHTML = loadingHTML();

  apiGet("/billing/prices").then(function(r) {
    if (!r) return;
    if (!r.ok) { display.innerHTML = emptyHTML("\u52a0\u8f7d\u5931\u8d25"); return; }
    r.json().then(function(d) {
      display.innerHTML = [
        '<div class="current-price-display">',
        '  <div class="amount">' + fmtYuan(d.monthly_price_cents) + '</div>',
        "  <div>",
        '    <div style="font-size:12px;color:var(--text-muted)">\u5f53\u524d\u6708\u8d39</div>',
        '    <div class="product-id">' + esc(d.product_id) + "</div>",
        "  </div>",
        "</div>",
      ].join("");

      var input = getEl("price-cents");
      var yuanEl = getEl("price-yuan");
      if (input) input.value = d.monthly_price_cents;
      if (yuanEl) yuanEl.textContent = d.monthly_price_yuan.toFixed(2);
    });
  }).catch(function() {
    if (display) display.innerHTML = emptyHTML("\u52a0\u8f7d\u5931\u8d25");
  });
}

function updatePrice() {
  var cents = parseInt((getEl("price-cents") || { value: "" }).value);
  if (isNaN(cents) || cents < 100 || cents > 1000000) {
    toast("\u4ef7\u683c\u5fc5\u987b\u5728 100 ~ 1000000 \u5206\u4e4b\u95f4", "error");
    return;
  }
  apiPost("/admin/api/settings/price", { monthly_price_cents: cents }).then(function(r) {
    if (!r) return;
    if (!r.ok) { handleApiError(r); return; }
    r.json().then(function(d) {
      toast("\u4ef7\u683c\u5df2\u66f4\u65b0\u4e3a " + fmtYuan(d.monthly_price_cents), "success");
      loadSettings();
      var overviewStats = getEl("overview-stats");
      if (overviewStats && overviewStats.innerHTML.indexOf("loading") === -1) {
        loadOverview();
      }
    });
  });
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
  if (!newPw || newPw.length < 6) { toast('\u65b0\u5bc6\u7801\u81f3\u5c116\u4f4d', 'error'); return; }
  if (newPw !== confirmPw) { toast('\u4e24\u6b21\u5bc6\u7801\u4e0d\u4e00\u81f4', 'error'); return; }
  if (newPw === oldPw) { toast('\u65b0\u5bc6\u7801\u4e0d\u80fd\u4e0e\u5f53\u524d\u5bc6\u7801\u76f8\u540c', 'error'); return; }

  apiPost('/auth/password/change', {
    old_password: oldPw,
    new_password: newPw,
  }).then(function(r) {
    if (!r) return;
    if (r.status === 401 || r.status === 400) {
      r.json().catch(function() { return {}; }).then(function(d) { toast(d.detail || '\u4fee\u6539\u5931\u8d25', 'error'); });
      return;
    }
    closeChangePasswordModal();
    toast('\u5bc6\u7801\u4fee\u6539\u6210\u529f', 'success');
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
    // Try to restore session — guarded so it can't overwrite the login page
    var guard = ++_renderGuard;
    apiGet("/admin/api/overview").then(function(r) {
      if (guard !== _renderGuard) return;
      if (r && r.ok) {
        state.loggedIn = true;
        renderApp();
      }
    }).catch(function() {});
    return;
  }

  // Build page content
  var pageContent = "";
  if (state.currentTab === "overview") pageContent = renderOverviewPage();
  else if (state.currentTab === "users") pageContent = renderUsersPage();
  else if (state.currentTab === "user_detail") pageContent = renderUserDetailPage();
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
  else if (state.currentTab === "admins") loadAdminList();
  else if (state.currentTab === "settings") loadSettings();

  // Price input live update
  var priceInput = getEl("price-cents");
  if (priceInput) {
    priceInput.oninput = function() {
      var yuanEl = getEl("price-yuan");
      if (yuanEl) yuanEl.textContent = ((parseInt(priceInput.value) || 0) / 100).toFixed(2);
    };
  }
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
window.updatePrice = updatePrice;
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
window.toast = toast;

// ============================================================
// Init
// ============================================================
document.addEventListener("DOMContentLoaded", function() {
  renderApp();
});
