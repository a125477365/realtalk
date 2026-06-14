"use strict";

/* RealTalk 用户端 SPA：同源访问后端 API（由 API 服务 /web 挂载或 nginx 代理）。*/

var API = "";
var state = {
  token: localStorage.getItem("rt_token") || "",
  user: null,
  usage: null,
  ledger: [],
  tab: "overview",
  authTab: "login",
  plans: [],
  order: null,
  scenes: [],
  jobs: [],
  devCode: "",
};
var jobPoller = null;

/* ---------- 基础工具 ---------- */
function $(id) { return document.getElementById(id); }
function esc(s) {
  if (s == null) return "—";
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function yuan(c) { return "¥" + ((c || 0) / 100).toFixed(2); }
function fmtDT(v) { return v ? String(v).slice(0, 16).replace("T", " ") : "—"; }
function fmtTokens(n) {
  n = n || 0;
  if (n >= 1000000) return (n / 1000000).toFixed(1) + "M";
  if (n >= 1000) return (n / 1000).toFixed(1) + "K";
  return String(n);
}
function toast(msg, type) {
  var el = $("toast");
  el.textContent = msg;
  el.className = "toast show " + (type || "");
  clearTimeout(el._t);
  el._t = setTimeout(function () { el.className = "toast"; }, 3200);
}

function api(path, options) {
  options = options || {};
  var headers = options.headers || {};
  if (state.token) headers["Authorization"] = "Bearer " + state.token;
  if (options.body && !(options.body instanceof FormData)) {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(options.body);
  }
  return fetch(API + path, { method: options.method || "GET", headers: headers, body: options.body })
    .then(function (r) {
      if (r.status === 401) { doLogout(true); throw new Error("登录已失效，请重新登录"); }
      return r.json().catch(function () { return {}; }).then(function (d) {
        if (!r.ok) throw new Error(d.detail || "请求失败 (" + r.status + ")");
        return d;
      });
    });
}

/* ---------- 认证 ---------- */
function doLogout(silent) {
  state.token = "";
  state.user = null;
  localStorage.removeItem("rt_token");
  if (jobPoller) { clearInterval(jobPoller); jobPoller = null; }
  render();
  if (!silent) toast("已退出登录", "success");
}

function loginWithWeChat() {
  api("/auth/wechat/web-config?redirect=" + encodeURIComponent(location.origin + location.pathname))
    .then(function (cfg) {
      if (cfg.dev_mode) {
        // 开发模式：与 App 相同的模拟微信授权（设备种子稳定对应同一账号）
        var seed = localStorage.getItem("rt_dev_wechat") || ("web-dev-" + Math.random().toString(36).slice(2) + Date.now());
        localStorage.setItem("rt_dev_wechat", seed);
        return api("/auth/wechat/login", { method: "POST", body: { code: seed, nickname: "微信用户", client: "web" } })
          .then(function (d) { onAuthed(d.token); toast("登录成功，新用户自动获得首月基础会员试用 🎉", "success"); });
      }
      // 生产：跳转微信开放平台扫码授权，回调携带 ?code=
      location.href = cfg.auth_url;
    })
    .catch(function (e) { toast(e.message, "error"); });
}

function handleWeChatCallback() {
  var params = new URLSearchParams(location.search);
  var code = params.get("code");
  if (!code) return false;
  history.replaceState(null, "", location.pathname); // 清掉 ?code，避免刷新重复使用
  api("/auth/wechat/login", { method: "POST", body: { code: code, client: "web" } })
    .then(function (d) { onAuthed(d.token); toast("微信登录成功", "success"); })
    .catch(function (e) { toast(e.message, "error"); render(); });
  return true;
}

function onAuthed(token) {
  state.token = token;
  localStorage.setItem("rt_token", token);
  state.tab = "overview";
  loadAccount().then(render);
}

function loadAccount() {
  return api("/billing/account").then(function (d) {
    state.user = d.user;
    state.usage = d.usage;
    state.ledger = d.ledger || [];
  });
}

/* ---------- 页面渲染 ---------- */
function render() {
  var app = $("app");
  if (!state.token || !state.user) { app.innerHTML = renderAuth(); bindAuth(); return; }
  app.innerHTML = [
    '<div class="shell">',
    renderNav(),
    state.tab === "overview" ? renderOverview() : "",
    state.tab === "plans" ? renderPlans() : "",
    state.tab === "scenes" ? renderScenes() : "",
    state.tab === "upload" ? renderUpload() : "",
    "</div>",
  ].join("");
  bindPage();
}

function renderAuth() {
  return [
    '<div class="auth-page">',
    '  <div class="auth-hero">',
    "    <h1>RealTalk</h1>",
    '    <p class="tag">把你一天的真实对话，变成今天的英语口语课</p>',
    "    <ul>",
    "      <li>自动把真实生活对话还原成英语练习场景</li>",
    "      <li>AI 逐句陪练：纠错、提示、双语字幕</li>",
    "      <li>高级会员支持上传录音文件（最长 6 小时）生成场景</li>",
    "      <li>新用户注册即送 1 个月基础会员免费试用</li>",
    "    </ul>",
    "  </div>",
    '  <div class="auth-panel"><div class="auth-card">',
    "    <h2>欢迎使用 RealTalk</h2>",
    '    <p class="sub">与 App 同一账号体系，微信扫码即可登录</p>',
    '    <button class="btn btn-primary btn-block" style="background:#0DAE4D;box-shadow:0 4px 14px rgba(13,174,77,.35)" onclick="loginWithWeChat()">💬 微信登录</button>',
    '    <p class="hint">新用户首次登录自动注册，并获得 1 个月基础会员免费试用。</p>',
    "  </div></div>",
    "</div>",
  ].join("");
}

function bindAuth() {}

function renderNav() {
  function item(id, label) {
    return '<a href="#" class="' + (state.tab === id ? "active" : "") + '" onclick="go(\'' + id + "');return false\">" + label + "</a>";
  }
  var name = state.user.display_name || state.user.login_identifier || "我";
  return [
    '<header class="topnav">',
    '  <div class="logo">RealTalk</div>',
    "  <nav>",
    item("overview", "账户概览"),
    item("plans", "会员套餐"),
    item("scenes", "我的场景"),
    item("upload", "上传录音"),
    "  </nav>",
    '  <button class="user-chip" onclick="doLogout()" title="退出登录">',
    '    <span class="avatar">' + esc(String(name).slice(0, 1).toUpperCase()) + "</span>",
    '    <span style="font-size:13.5px">退出</span>',
    "  </button>",
    "</header>",
  ].join("");
}

function go(tab) {
  state.tab = tab;
  render();
  if (tab === "overview") loadAccount().then(render);
  if (tab === "plans") loadPlans();
  if (tab === "scenes") loadScenes();
  if (tab === "upload") loadJobs(true);
}

/* ---------- 概览 ---------- */
function tierName(t) { return t === "premium" ? "高级会员" : t === "basic" ? "基础会员" : "免费用户"; }

function renderOverview() {
  var u = state.user, usage = state.usage || {};
  var ratio = usage.daily_limit ? Math.min(100, Math.round(usage.today_tokens / usage.daily_limit * 100)) : 0;
  var rows = (state.ledger || []).slice(0, 8).map(function (l) {
    return "<tr><td>" + fmtDT(l.created_at) + "</td><td>" + esc(l.title) + '</td><td style="font-weight:600;color:' +
      (l.amount_cents >= 0 ? "var(--good)" : "var(--bad)") + '">' + (l.amount_cents >= 0 ? "+" : "") + yuan(l.amount_cents) + "</td></tr>";
  }).join("");
  return [
    '<div class="hero-card">',
    "  <div>",
    '    <div class="name">' + esc(u.display_name || u.login_identifier) +
    '      <span class="tier-badge ' + (u.plan_tier === "premium" ? "tier-premium" : "") + '">' + tierName(u.plan_tier) + "</span></div>",
    '    <div class="meta">' + (u.plan_expires_at ? "会员有效期至 " + String(u.plan_expires_at).slice(0, 10) : "试用已结束，订阅后继续使用 AI 功能") + "</div>",
    '    <div class="meta">今日 AI 用量 ' + fmtTokens(usage.today_tokens) + " / " + fmtTokens(usage.daily_limit) + " tokens" +
    (usage.over_limit ? "（已达上限，明天恢复）" : "") + "</div>",
    '    <div class="progress ' + (ratio >= 80 ? "warn" : "") + '" style="max-width:340px"><i style="width:' + ratio + '%"></i></div>',
    "  </div>",
    '  <div class="balance"><div class="num">' + yuan(u.balance_cents) + '</div><div class="lbl">账户余额</div>',
    '    <div style="margin-top:10px"><button class="btn btn-sm" style="background:rgba(255,255,255,.2);color:#fff" onclick="go(\'recharge\')">去充值</button></div></div>',
    "</div>",
    '<div class="stat-row">',
    '  <div class="mini-stat"><div class="v">' + fmtTokens(usage.remaining_tokens) + '</div><div class="k">今日剩余 tokens</div></div>',
    '  <div class="mini-stat"><div class="v">' + tierName(u.plan_tier) + '</div><div class="k">当前套餐 · 会员有 token 限额</div></div>',
    '  <div class="mini-stat"><div class="v">' + (u.plan_tier === "premium" ? "已开通" : "未开通") + '</div><div class="k">录音文件上传（高级会员）</div></div>',
    "</div>",
    '<div class="card" style="margin-top:18px"><h3>最近账单</h3>',
    rows ? '<table class="list"><thead><tr><th>时间</th><th>项目</th><th>金额</th></tr></thead><tbody>' + rows + "</tbody></table>"
         : '<div class="empty">暂无账单记录</div>',
    "</div>",
  ].join("");
}

/* ---------- 套餐 ---------- */
function loadPlans() {
  api("/billing/plans").then(function (d) { state.plans = d.items || []; render(); })
    .catch(function (e) { toast(e.message, "error"); });
}

function renderPlans() {
  if (!state.plans.length) return '<div class="card"><div class="empty">套餐加载中…</div></div>';
  var benefit = {
    basic: ["App 实时录音转写生成场景", "AI 逐句陪练与纠错", "今日场景自动生成", "口语训练与表达卡片"],
    premium: ["包含基础会员全部功能", "App / 网页上传录音文件（≤6 小时 / 300MB）", "音频自动转写并生成场景", "更高每日 token 限额"],
  };
  var cards = state.plans.map(function (p) {
    var monthly = p.months > 1;
    var save = monthly ? Math.round((1 - p.per_month_cents / (p.tier === "premium" ? 5000 : 3000)) * 100) : 0;
    return [
      '<div class="plan-card ' + (p.tier === "premium" ? "premium" : "") + '">',
      save > 0 ? '<span class="save-tag">省 ' + save + "%</span>" : "",
      '  <div class="tier">' + esc(p.title) + "</div>",
      '  <div class="price">' + yuan(p.per_month_cents) + "<small> /月</small></div>",
      '  <div class="total">' + (monthly ? "一次支付 " + yuan(p.price_cents) + "（" + p.months + " 个月）" : "按月订阅") + "</div>",
      "  <ul>" + benefit[p.tier].map(function (b) { return "<li>" + b + "</li>"; }).join("") + "</ul>",
      '  <button class="btn btn-primary btn-block" onclick="subscribe(\'' + p.id + "','" + esc(p.title) + "'," + p.price_cents + ')">立即开通</button>',
      "</div>",
    ].join("");
  }).join("");
  var method = state.payMethod || "wechat";
  var order = state.order;
  return [
    '<div class="card"><h3>会员套餐 <span class="sub">直接付款开通；会员每日有 token 用量限额，超出后当天暂停 AI 功能</span></h3>',
    '<div class="pay-methods">',
    '  <button class="' + (method === "wechat" ? "sel" : "") + '" onclick="setMethod(\'wechat\')">💚 微信支付</button>',
    '  <button class="' + (method === "alipay" ? "sel" : "") + '" onclick="setMethod(\'alipay\')">💙 支付宝</button>',
    "</div>",
    '<div class="plan-grid">' + cards + "</div>",
    order ? [
      '<div class="order-panel">',
      "  <div><b>" + esc(order.message) + "</b></div>",
      order.qr_code_url ? '<div class="qr-box"><img src="' + esc(order.qr_code_url) + '" alt="付款二维码" /></div>' : "",
      order.receiver_account ? '<div style="margin-top:6px">收款账号：<b>' + esc(order.receiver_account) + "</b></div>" : "",
      '  <div class="mono" style="margin-top:6px">订单号 ' + esc(order.order_id) + "</div>",
      '  <div style="margin-top:12px;display:flex;gap:10px">',
      '    <button class="btn btn-primary btn-sm" onclick="confirmOrder()">我已完成付款</button>',
      '    <button class="btn btn-ghost btn-sm" onclick="state.order=null;render()">取消</button>',
      "  </div>",
      "</div>",
    ].join("") : "",
    "</div>",
  ].join("");
}

function setMethod(m) { state.payMethod = m; render(); }

function subscribe(planId, title, price) {
  // 直接生成套餐支付订单，支付成功后激活会员
  api("/billing/recharge", { method: "POST", body: { plan_id: planId, method: state.payMethod || "wechat" } })
    .then(function (d) { state.order = d; render(); })
    .catch(function (e) { toast(e.message, "error"); });
}

function confirmOrder() {
  if (!state.order) return;
  api("/billing/recharge/confirm", { method: "POST", body: { order_id: state.order.order_id } })
    .then(function (d) {
      state.user = d.user; state.usage = d.usage; state.ledger = d.ledger || []; state.order = null;
      toast("支付成功，会员已开通！", "success"); go("overview");
    })
    .catch(function (e) { toast(e.message, "error"); });
}

/* ---------- 场景 ---------- */
function loadScenes() {
  api("/scenario/list").then(function (d) { state.scenes = d.items || []; render(); })
    .catch(function (e) { toast(e.message, "error"); });
}

function renderScenes() {
  var items = state.scenes.map(function (s, i) {
    return [
      '<div class="scene-item" onclick="openScene(' + i + ')">',
      '  <div class="ic">🎬</div>',
      '  <div><div class="t">' + esc(s.title) + '</div><div class="s">' + esc(s.summary) + "</div></div>",
      '  <div class="meta">' + s.line_count + " 句<br>" + fmtDT(s.created_at) + "</div>",
      "</div>",
    ].join("");
  }).join("");
  return [
    '<div class="card"><h3>我的场景 <span class="sub">来自 App 实时采集与上传的录音文件</span></h3>',
    items || '<div class="empty">还没有场景。打开 RealTalk App 采集真实对话，或上传录音文件生成。</div>',
    "</div>",
  ].join("");
}

function openScene(index) {
  var s = state.scenes[index];
  if (!s) return;
  api("/scenario/" + encodeURIComponent(s.scene_id)).then(function (d) {
    var roleNames = {};
    (d.roles || []).forEach(function (r) { roleNames[r.id] = r.name; });
    var lines = (d.lines || []).map(function (l) {
      return '<div class="line-row"><div class="who">' + esc(roleNames[l.target_role] || l.speaker) +
        '</div><div class="en">' + esc(l.english) + '</div><div class="zh">' + esc(l.source_text) + "</div></div>";
    }).join("");
    var mask = document.createElement("div");
    mask.className = "modal-mask";
    mask.innerHTML = '<div class="modal"><h3>' + esc(d.title) + '</h3><p style="font-size:13.5px;color:var(--text-2);margin-bottom:12px">' +
      esc(d.summary) + "</p>" + lines + '<div style="margin-top:16px;text-align:right"><button class="btn btn-ghost btn-sm" id="m-close">关闭</button></div></div>';
    document.body.appendChild(mask);
    mask.onclick = function (e) { if (e.target === mask) mask.remove(); };
    mask.querySelector("#m-close").onclick = function () { mask.remove(); };
  }).catch(function (e) { toast(e.message, "error"); });
}

/* ---------- 上传录音（高级会员）---------- */
function loadJobs(startPolling) {
  api("/audio/jobs").then(function (d) {
    state.jobs = d.items || [];
    render();
    var active = state.jobs.some(function (j) { return j.status === "pending" || j.status === "transcribing" || j.status === "generating"; });
    if (startPolling || active) {
      if (jobPoller) clearInterval(jobPoller);
      if (active) jobPoller = setInterval(function () { if (state.tab === "upload") loadJobs(false); else clearInterval(jobPoller); }, 4000);
    }
  }).catch(function () {});
}

function statusBadge(s) {
  if (s === "completed") return '<span class="badge ok">已完成</span>';
  if (s === "failed") return '<span class="badge fail">失败</span>';
  if (s === "pending") return '<span class="badge pend">排队中</span>';
  return '<span class="badge run">' + (s === "transcribing" ? "转写中" : "生成场景中") + "</span>";
}

function renderUpload() {
  var isPremium = state.user.plan_tier === "premium";
  var rows = state.jobs.map(function (j) {
    return "<tr><td>" + esc(j.filename) + "</td><td>" + (j.size_bytes / 1024 / 1024).toFixed(1) + " MB</td><td>" +
      statusBadge(j.status) + "</td><td>" + fmtDT(j.created_at) + "</td><td>" +
      (j.status === "failed" ? '<span style="color:var(--bad);font-size:12px">' + esc(j.error) + "</span>"
        : j.scene_id ? '<button class="btn btn-ghost btn-sm" onclick="go(\'scenes\')">查看场景</button>' : "—") + "</td></tr>";
  }).join("");
  return [
    '<div class="card"><h3>上传录音生成场景 <span class="sub">支持 mp3 / wav / m4a，最长 6 小时、最大 300MB；转写完成后自动删除音频文件</span></h3>',
    isPremium
      ? [
          '<div class="dropzone" id="dropzone"><div class="big">🎙️</div>',
          "  <div><b>点击选择</b> 或拖拽录音文件到这里</div>",
          '  <div class="hint">上传后服务器自动转写为文字 → 内容清洗过滤 → AI 生成英语练习场景</div>',
          '  <input type="file" id="file-input" accept=".mp3,.wav,.m4a,audio/*" style="display:none" />',
          "</div>",
          '<div id="up-progress" style="display:none;margin-top:14px"><div class="progress"><i id="up-bar" style="width:0%"></i></div>',
          '<div class="hint" id="up-text">上传中…</div></div>',
        ].join("")
      : '<div class="lock-note">🔒 上传录音文件是<b>高级会员</b>功能。开通后可上传最长 6 小时的录音，自动转写并生成专属练习场景。' +
        '<button class="btn btn-primary btn-sm" style="margin-left:auto" onclick="go(\'plans\')">升级高级会员</button></div>',
    "</div>",
    '<div class="card"><h3>处理记录</h3>',
    rows ? '<table class="list"><thead><tr><th>文件</th><th>大小</th><th>状态</th><th>时间</th><th></th></tr></thead><tbody>' + rows + "</tbody></table>"
         : '<div class="empty">暂无上传记录</div>',
    "</div>",
  ].join("");
}

function bindPage() {
  var zone = $("dropzone");
  if (zone) {
    var input = $("file-input");
    zone.onclick = function () { input.click(); };
    input.onchange = function () { if (input.files[0]) uploadAudio(input.files[0]); };
    zone.ondragover = function (e) { e.preventDefault(); zone.classList.add("drag"); };
    zone.ondragleave = function () { zone.classList.remove("drag"); };
    zone.ondrop = function (e) {
      e.preventDefault(); zone.classList.remove("drag");
      if (e.dataTransfer.files[0]) uploadAudio(e.dataTransfer.files[0]);
    };
  }
}

// 断点续传：init → 分块 PUT（失败自动重试/续传）→ complete
var CHUNK_SIZE = 4 * 1024 * 1024; // 4MB/块

function setUpProgress(loaded, total, label) {
  var pct = total ? Math.round(loaded / total * 100) : 0;
  $("up-progress").style.display = "block";
  $("up-bar").style.width = pct + "%";
  $("up-text").textContent = (label || "上传中 ") + pct + "%（" + (loaded / 1048576).toFixed(1) + " / " + (total / 1048576).toFixed(1) + " MB）";
}

function authHeaders(extra) {
  var h = { Authorization: "Bearer " + state.token };
  if (extra) for (var k in extra) h[k] = extra[k];
  return h;
}

async function uploadAudio(file) {
  if (file.size > 300 * 1024 * 1024) { toast("文件超过 300MB 上限", "error"); return; }
  try {
    setUpProgress(0, file.size, "准备上传 ");
    // 1) init
    var init = await fetch(API + "/audio/upload/init", {
      method: "POST", headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ filename: file.name, size_bytes: file.size }),
    });
    if (!init.ok) { toast((await init.json().catch(function () { return {}; })).detail || "上传初始化失败", "error"); $("up-progress").style.display = "none"; return; }
    var uploadId = (await init.json()).upload_id;

    // 2) 分块上传，失败重试并按服务端已收字节续传
    var offset = 0;
    while (offset < file.size) {
      var end = Math.min(offset + CHUNK_SIZE, file.size);
      var blob = file.slice(offset, end);
      var ok = false, attempt = 0;
      while (!ok) {
        attempt++;
        try {
          var put = await fetch(API + "/audio/upload/chunk?upload_id=" + encodeURIComponent(uploadId) + "&offset=" + offset, {
            method: "PUT", headers: authHeaders(), body: blob,
          });
          if (put.ok) { ok = true; break; }
          if (put.status === 409) {
            // 偏移不连续：以服务端为准重新对齐
            var st = await fetch(API + "/audio/upload/status?upload_id=" + encodeURIComponent(uploadId) + "&size_bytes=" + file.size, { headers: authHeaders() });
            offset = (await st.json()).received_bytes; ok = true; break;
          }
          throw new Error("HTTP " + put.status);
        } catch (e) {
          if (attempt >= 5) { throw e; }
          $("up-text").textContent = "网络波动，重试中（" + attempt + "/5）…";
          await new Promise(function (r) { setTimeout(r, 1500 * attempt); });
          // 续传前查实际进度
          try {
            var st2 = await fetch(API + "/audio/upload/status?upload_id=" + encodeURIComponent(uploadId) + "&size_bytes=" + file.size, { headers: authHeaders() });
            if (st2.ok) offset = (await st2.json()).received_bytes;
          } catch (_) {}
        }
      }
      if (offset < end) offset = end;
      setUpProgress(offset, file.size);
    }

    // 3) complete
    var done = await fetch(API + "/audio/upload/complete?upload_id=" + encodeURIComponent(uploadId) + "&filename=" + encodeURIComponent(file.name), {
      method: "POST", headers: authHeaders(),
    });
    $("up-progress").style.display = "none";
    if (done.ok) { toast("上传成功，正在转写生成场景…", "success"); loadJobs(true); }
    else toast((await done.json().catch(function () { return {}; })).detail || "完成上传失败", "error");
  } catch (e) {
    $("up-progress").style.display = "none";
    toast("上传失败：" + (e.message || "网络错误") + "（可重新选择同一文件自动续传）", "error");
  }
}

/* ---------- 全局导出 & 启动 ---------- */
window.go = go;
window.loginWithWeChat = loginWithWeChat;
window.doLogout = doLogout;
window.setMethod = setMethod;
window.confirmOrder = confirmOrder;
window.subscribe = subscribe;
window.openScene = openScene;
window.state = state;
window.render = render;

document.addEventListener("DOMContentLoaded", function () {
  if (handleWeChatCallback()) return;
  if (state.token) {
    loadAccount().then(render).catch(function () { doLogout(true); });
  } else {
    render();
  }
});
