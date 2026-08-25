# 邮箱注册 / 登录接入指南（推荐先上这个）

后端从 v1 起就内置了完整的「邮箱 + 验证码注册 / 邮箱 + 密码登录」能力
（`/auth/email/code` + `/auth/password/register` + `/auth/password/login`），
只是默认被开关挡住，让位给微信一键登录。本指南说明如何**不依赖微信企业号**直接放开注册。

## 流程速览

1. 用户输入邮箱（QQ 邮箱即可）→ App 调用 `/auth/email/code` 触发发信
2. 后端生成 6 位验证码、按 TTL（默认 10 分钟）入库、通过 SMTP 发出
3. 用户填验证码 + 设置密码 → 调 `/auth/password/register`，后端校验验证码并直接下发 access + refresh 令牌
4. 下次回来直接 `/auth/password/login`（邮箱 + 密码），无需再收验证码

## 必配：SMTP（发信用）

打开 `realtalkwork/.env`（新建库时可让 `setup.sh` 引导生成），改下面几行：

```env
EMAIL_AUTH_ENABLED=true     # 必须 true，否则邮箱注册接口直接 403
EMAIL_DEV_MODE=false        # 必须 false，才会真正发邮件

SMTP_HOST=smtp.qq.com
SMTP_PORT=587
SMTP_USERNAME=你的QQ邮箱@qq.com
SMTP_PASSWORD=你的QQ邮箱授权码   # 注意：不是 QQ 登录密码，而是邮箱设置里生成的授权码
SMTP_FROM=RealTalk <你的QQ邮箱@qq.com>
```

**怎么拿到 QQ 邮箱授权码**：
1. 网页登录 mail.qq.com → 顶部「设置」→「账户」
2. 找到「POP3/IMAP/SMTP/Exchange/CardDAV/CalDAV 服务」一段
3. 开启「POP3/SMTP 服务」或「IMAP/SMTP 服务」（开一个即可）
4. 按提示发短信验证 → 系统会给你一串 16 位「授权码」，复制到 `SMTP_PASSWORD`

> QQ 邮箱 SMTP 走 STARTTLS，端口 587。RealTalk 后端固定使用 STARTTLS，所以
> 一定别再配 465（SSL），对不上。

改完重启：
```bash
docker compose down && docker compose up -d
# 或本地 venv：直接重新 uvicorn
```

## 联调期：没配 SMTP 也能跑通

把 `EMAIL_DEV_MODE` 保持 `true`，那么：
- `/auth/email/code` 不再真发邮件，而是把验证码直接以 `dev_code` 字段返回给 App
- iOS / Android 均已内置：拿到 `dev_code` 就自动填进验证码输入框，立刻可以走完注册流程
- 注意：上线前**必须**把 `EMAIL_DEV_MODE` 设为 `false`，否则任何人可看验证码注册任意邮箱

## 客户端（iOS / Android）

无需改动——本仓库两端已经接好邮箱认证：
- iOS：`Services/AuthStore.swift` 的 `sendEmailCode / register / login` + `Views/AuthViews.swift` 邮箱登录/注册页
- Android：`data/ApiClient.kt` 的 `sendEmailCode / registerPassword / loginPassword` + `ui/AppUi.kt LoginScreen`

把后端打开开关、配好 SMTP，装上 App 就能用。

## 后续：换回微信一键登录

如果你想之后叠加微信一键登录（仍需要企业号），保留 `WECHAT_APP_ID/WECHAT_APP_SECRET` 配置，
见 [`docs/wechat-app-login.md`](./wechat-app-login.md)。邮箱路径不会受影响，
两套认证可以并存：同一邮箱若先注册再绑微信，登录任一方式都进同一账户。
