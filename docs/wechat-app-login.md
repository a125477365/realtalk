# 微信 App 一键登录接入指南

App 端「微信一键登录」用的是微信开放平台 **移动应用** + 微信 OpenSDK。后端已支持
（`/auth/wechat/login` 带 `client:"app"` 时用移动应用凭据换 openid），客户端代码也已接好，
**只差你的微信资质与配置**。未配置时两端 App 自动回退到开发模拟登录，不影响使用。

## 一、微信开放平台（必须，企业资质）

1. 登录 [open.weixin.qq.com](https://open.weixin.qq.com)，企业实名认证（个人主体无法申请）。
2. 「管理中心 → 移动应用 → 创建移动应用」，分别填写 iOS 与 Android 的信息，提交审核：
   - **iOS**：Bundle ID（与 Xcode 工程一致）、Universal Link（如 `https://realtalk.app/app/`）。
   - **Android**：应用包名 `com.example.realtalkad`、应用签名（用微信提供的「签名生成工具」对你的签名证书算出的 MD5）。
3. 审核通过后得到 **AppID**（`wx` 开头）和 **AppSecret**。iOS/Android 同属一个移动应用、共用这对凭据。

## 二、后端配置

`.env`（或重跑 `setup.sh` 在「微信登录」步骤填写）：

```env
WECHAT_AUTH_DEV_MODE=false
WECHAT_APP_ID=wx你的移动应用AppID
WECHAT_APP_SECRET=你的AppSecret
```

改完 `docker compose up -d` 重启 api。

## 三、Android

1. `WeChatAuth.APP_ID`（`app/src/main/java/com/example/realtalkad/wechat/WeChatAuth.kt`）填入 AppID。
2. 依赖、`WXEntryActivity`、manifest 已就绪（`com.tencent.mm.opensdk:wechat-sdk-android`）。
3. 用与开放平台登记一致的签名证书打包。装了微信的真机上点「微信登录」即可拉起微信授权。

## 四、iOS

1. **添加微信 SDK**：Xcode → File → Add Package Dependencies，加入微信 OpenSDK
   （社区 SPM 镜像 `https://github.com/wechat-open/WechatOpenSDK-XCFramework`，或用 CocoaPods
   `pod 'WechatOpenSDK-XCFramework'`）。加入后 `import WechatOpenSDK` 可用，登录代码自动激活
   （`WeChatAuthManager` 用 `#if canImport(WechatOpenSDK)` 守卫，未加包时回退开发登录）。
2. `AppConfig.swift` 填 `wechatAppID` 和 `wechatUniversalLink`。
3. `Info.plist`：把 `CFBundleURLSchemes` 里的 `wxYOURAPPID` 改成真实 AppID。
4. Signing & Capabilities 开启 **Associated Domains**，加 `applinks:realtalk.app`（与 Universal Link 域名一致），
   并在该域名部署 `apple-app-site-association` 文件。
5. 真机运行，点「微信登录」拉起微信。

## 五、验证

- App 点「微信登录」→ 跳转微信 → 确认授权 → 回到 App 自动登录成功。
- 后端日志可见 `/auth/wechat/login` 200。
- 失败常见原因：AppID/包名/签名/Bundle ID/Universal Link 与开放平台登记不一致；移动应用未过审；
  手机未装微信（此时回退开发登录）。
