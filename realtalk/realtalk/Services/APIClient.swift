import Foundation
import CryptoKit

enum APIClientError: LocalizedError {
    case invalidResponse
    case server(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回格式不正确"
        case .server(let message):
            return message
        case .unauthorized:
            return "请先登录"
        }
    }
}

final class APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// 已登录请求收到 401（如账号被其它设备顶掉）时回调，用于自动退出登录。
    var onUnauthorized: (@MainActor () -> Void)?
    /// access 过期时回调：用 refresh 令牌续期，返回新的 access；返回 nil 表示续期失败。
    var onNeedsRefresh: (@MainActor () async -> String?)?

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(baseURL: URL = AppConfig.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(APIClient.iso8601Formatter.string(from: date))
        }
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = APIClient.iso8601Formatter.date(from: value) ?? APIClient.iso8601FractionalFormatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        self.decoder = decoder
    }

    func sendEmailCode(email: String) async throws -> EmailCodeResponse {
        try await post("/auth/email/code", body: EmailCodeRequest(email: email), token: nil)
    }

    func register(email: String, password: String, code: String) async throws -> AuthResponse {
        try await post("/auth/register", body: EmailRegisterRequest(email: email, password: password, code: code), token: nil)
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await post("/auth/login", body: AuthRequest(email: email, password: password), token: nil)
    }

    func wechatLogin(code: String, nickname: String?, avatarUrl: String?, deviceId: String?) async throws -> AuthResponse {
        try await post(
            "/auth/wechat/login",
            body: WeChatLoginRequest(code: code, nickname: nickname, avatarUrl: avatarUrl, deviceId: deviceId),
            token: nil
        )
    }

    func currentUser(token: String) async throws -> AppUser {
        try await get("/auth/me", token: token, queryItems: [])
    }

    func refreshToken(refreshToken: String) async throws -> AuthTokenResponse {
        try await post("/auth/token/refresh", body: TokenRefreshRequest(refreshToken: refreshToken), token: nil)
    }

    /// 服务端登出（注销全部设备 / 吊销令牌）。尽力而为，失败不影响本地清理。
    func serverLogout(token: String) async {
        _ = try? await post("/auth/logout", body: EmptyBody(), token: token) as OKResponse
    }

    func aiChat(
        message: String,
        history: [AIChatWireMessage],
        sceneId: String?,
        sessionId: String?,
        token: String
    ) async throws -> AIChatResponse {
        try await post(
            "/ai/chat",
            body: AIChatRequest(message: message, messages: history, sceneId: sceneId, sessionId: sessionId),
            token: token
        )
    }

    func uploadCaptureSegments(
        _ segments: [TranscriptSegment],
        token: String,
        chunkSize: Int = 80
    ) async throws -> CaptureUploadCompleteResponse {
        let sorted = segments.sorted { $0.timestamp < $1.timestamp }
        let start = sorted.first?.timestamp
        let end = sorted.last?.timestamp
        let initResponse: CaptureUploadInitResponse = try await post(
            "/capture/upload/init",
            body: CaptureUploadInitRequest(start: start, end: end, estimatedItems: sorted.count),
            token: token
        )
        let serverChunkSize = max(1, min(chunkSize, initResponse.maxItemsPerChunk))
        for (index, slice) in sorted.chunked(into: serverChunkSize).enumerated() {
            let items = slice.map { TranscriptUploadItem(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
            let _: CaptureUploadChunkResponse = try await post(
                "/capture/upload/chunk",
                body: CaptureUploadChunkRequest(uploadId: initResponse.uploadId, chunkIndex: index, items: items),
                token: token
            )
        }
        return try await post(
            "/capture/upload/complete",
            body: CaptureUploadCompleteRequest(uploadId: initResponse.uploadId, start: start, end: end),
            token: token
        )
    }

    func generateLearning(
        start: Date,
        end: Date,
        segments: [TranscriptSegment],
        token: String
    ) async throws -> LearningResponse {
        let items = segments.map { TranscriptUploadItem(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
        return try await post(
            "/learning/generate",
            body: LearningGenerateRequest(start: start, end: end, items: items),
            token: token
        )
    }

    func startTraining(
        start: Date,
        end: Date,
        segments: [TranscriptSegment],
        token: String
    ) async throws -> TrainingStateResponse {
        let items = segments.map { TranscriptUploadItem(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
        return try await post(
            "/training/start",
            body: TrainingStartRequest(start: start, end: end, items: items),
            token: token
        )
    }

    func generateScenario(
        start: Date,
        end: Date,
        segments: [TranscriptSegment],
        token: String
    ) async throws -> ScenarioResponse {
        let items = segments.map { TranscriptUploadItem(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
        return try await post(
            "/scenario/generate",
            body: ScenarioGenerateRequest(start: start, end: end, items: items),
            token: token
        )
    }

    func captureQuota(token: String) async throws -> CaptureQuotaResponse {
        try await get("/capture/quota", token: token, queryItems: [])
    }

    func todayScenarios(token: String) async throws -> ScenarioListResponse {
        try await get("/scenario/today", token: token, queryItems: [])
    }

    func scenarioList(token: String) async throws -> ScenarioListResponse {
        try await get("/scenario/list", token: token, queryItems: [])
    }

    func scenarioDetail(sceneId: String, token: String) async throws -> ScenarioResponse {
        try await get("/scenario/\(sceneId)", token: token, queryItems: [])
    }

    /// 删除用户自己的场景（预置通用场景不可删）。
    func deleteScenario(sceneId: String, token: String) async throws {
        var request = URLRequest(url: url(for: "/scenario/\(sceneId)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60
        addDefaultHeaders(to: &request, token: token)
        let _: OKResponse = try await send(request)
    }

    /// 通用场景目录：运维预置的全局场景（按主场景分组，含完整对话，可直接对练）。
    func presetScenarioCatalog(token: String) async throws -> PresetScenarioCatalogResponse {
        try await get("/scenario/presets/catalog", token: token, queryItems: [])
    }

    func startRoleplay(
        start: Date,
        end: Date,
        selectedRole: String,
        sceneId: String?,
        segments: [TranscriptSegment],
        resume: Bool = false,
        token: String
    ) async throws -> RoleplayStateResponse {
        let items = segments.map { TranscriptUploadItem(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
        return try await post(
            "/roleplay/start",
            body: RoleplayStartRequest(
                start: start,
                end: end,
                selectedRole: selectedRole,
                sceneId: sceneId,
                items: items,
                resume: resume
            ),
            token: token
        )
    }

    /// 语境润色（详细指导浮层）：一句话 → 地道美式/商务正式/地道英式 三风格。
    /// 本地 CPU 大模型生成慢，超时给足（后端普通档可配到 120s）。
    func refine(text: String, token: String) async throws -> RefineResponse {
        var request = URLRequest(url: url(for: "/practice/refine"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        addDefaultHeaders(to: &request, token: token)
        request.httpBody = try encoder.encode(RefineRequest(text: text))
        return try await send(request)
    }

    /// 设置页「清除聊天记录」：删除服务端私教/自由对话历史。
    func clearFreetalkHistory(token: String) async throws -> String {
        var request = URLRequest(url: url(for: "/freetalk/history"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60
        addDefaultHeaders(to: &request, token: token)
        let response: MessageResponse = try await send(request)
        return response.message
    }

    /// 字幕卡内「译」按钮的按需翻译：该条消息没带翻译时调用一次，结果缓存在字幕条上。
    func translate(text: String, token: String) async throws -> String {
        var request = URLRequest(url: url(for: "/practice/translate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        addDefaultHeaders(to: &request, token: token)
        request.httpBody = try encoder.encode(TranslateRequest(text: text))
        let response: TranslateResponse = try await send(request)
        return response.text
    }

    func submitRoleplayMessage(
        sessionId: String,
        message: String,
        guidanceMode: String,
        token: String
    ) async throws -> RoleplayStateResponse {
        try await post(
            "/roleplay/message",
            body: RoleplayMessageRequest(sessionId: sessionId, message: message, guidanceMode: guidanceMode),
            token: token
        )
    }

    /// 方式1/2 后端语音：上传一句录音，后端识别+评分+发音纠正，返回对练状态。
    func roleplayMessageAudio(sessionId: String, guidanceMode: String, fileURL: URL, token: String) async throws -> RoleplayStateResponse {
        let boundary = "rt-\(UUID().uuidString)"
        var comps = URLComponents(url: url(for: "/roleplay/message/audio"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "session_id", value: sessionId),
                             URLQueryItem(name: "guidance_mode", value: guidanceMode)]
        guard let u = comps?.url else { throw APIClientError.invalidResponse }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return try await send(request)
    }

    /// 后端 TTS 朗读一段文本（用用户选定音色），返回音频数据供播放。
    func ttsSpeak(text: String, cache: Bool = true, token: String) async throws -> Data {
        var comps = URLComponents(url: url(for: "/tts/speak"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "cache", value: cache ? "true" : "false"),
        ]
        guard let u = comps?.url else { throw APIClientError.invalidResponse }
        var request = URLRequest(url: u)
        request.httpMethod = "GET"
        request.timeoutInterval = 300   // 本地 CPU 合成一句 60~110s，60s 会掐死所有重播/朗读
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw APIClientError.server(detail ?? "语音合成失败")
        }
        return data
    }

    /// 解码 WebSocket 推来的整轮对练状态（用与 HTTP 同一套解码器，保证日期/字段一致）。
    func decodeRoleplayState(_ data: Data) -> RoleplayStateResponse? {
        try? decoder.decode(RoleplayStateResponse.self, from: data)
    }

    func ttsVoices(token: String) async throws -> TtsVoices {
        try await get("/tts/voices", token: token, queryItems: [])
    }

    func setTtsVoice(_ voice: String, token: String) async throws -> TtsVoices {
        try await post("/tts/voice", body: TtsVoiceBody(voice: voice), token: token)
    }

    /// 试听某音色的 URL（音色选择界面用）。
    func ttsPreviewURL(voice: String) -> URL? {
        var comps = URLComponents(url: url(for: "/tts/preview"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "voice", value: voice)]
        return comps?.url
    }

    /// 沉浸式后端语音流的 WebSocket 地址（http→ws / https→wss）。
    /// 注意：URLQueryItem 不会转义 '+'（老令牌是标准 base64 可能含 '+'，服务端会把它解析成空格→鉴权失败），
    /// 必须强制把查询串中的 '+' 编码为 %2B。
    func roleplayStreamURL(sessionId: String, token: String) -> URL? {
        var comps = URLComponents(url: url(for: "/roleplay/stream"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "token", value: token),
                             URLQueryItem(name: "session_id", value: sessionId)]
        if let encoded = comps?.percentEncodedQuery {
            comps?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let s = comps?.url?.absoluteString else { return nil }
        if s.hasPrefix("https") { return URL(string: "wss" + s.dropFirst(5)) }
        if s.hasPrefix("http") { return URL(string: "ws" + s.dropFirst(4)) }
        return URL(string: s)
    }

    /// 自由对话（一对一语音老师）流地址；协议同沉浸式流。'+' 强制编码为 %2B（原因见 roleplayStreamURL）。
    /// mode: chat=对话（默认）/ translate=实时翻译；sceneId 非空 = 带场景剧本进场（自由发挥式场景对话）；
    /// live=true = GPT-Live 式全双工（轮次判定在服务端，客户端持续上行）。
    func freeTalkStreamURL(token: String, mode: String = "chat", sceneId: String = "", live: Bool = false) -> URL? {
        var comps = URLComponents(url: url(for: "/freetalk/stream"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "token", value: token),
                     URLQueryItem(name: "mode", value: mode)]
        if sceneId.isEmpty == false { items.append(URLQueryItem(name: "scene_id", value: sceneId)) }
        if live { items.append(URLQueryItem(name: "live", value: "1")) }
        comps?.queryItems = items
        if let encoded = comps?.percentEncodedQuery {
            comps?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let s = comps?.url?.absoluteString else { return nil }
        if s.hasPrefix("https") { return URL(string: "wss" + s.dropFirst(5)) }
        if s.hasPrefix("http") { return URL(string: "ws" + s.dropFirst(4)) }
        return URL(string: s)
    }

    // ---- 学习提醒（智能电话）：App 定时触发并上报信号，后端综合裁决（后端无任何主动动作）----

    struct ReminderCheckRequest: Codable {
        let localDayStart: Date
        let localHour: Int
        let weekday: Int
        let inUserWindow: Bool?
        let motion: String?
        let ambientLevel: Double?
        let heartRate: Double?

        enum CodingKeys: String, CodingKey {
            case localDayStart = "local_day_start"
            case localHour = "local_hour"
            case weekday
            case inUserWindow = "in_user_window"
            case motion
            case ambientLevel = "ambient_level"
            case heartRate = "heart_rate"
        }
    }

    struct ReminderCheckResponse: Codable {
        let decision: String          // call / none / busy
        let reason: String?
        let scenario: ScenarioSummary?
    }

    func reminderCheck(_ request: ReminderCheckRequest, token: String) async throws -> ReminderCheckResponse {
        try await post("/reminder/check", body: request, token: token)
    }

    func reminderDismiss(sceneId: String, token: String) async throws {
        struct Req: Codable { let sceneId: String }
        struct Resp: Codable { let ok: Bool }
        let _: Resp = try await post("/reminder/dismiss", body: Req(sceneId: sceneId), token: token)
    }

    func evaluateRoleplay(sessionId: String, token: String) async throws -> RoleplayStateResponse {
        try await post(
            "/roleplay/evaluate",
            body: RoleplayEvaluateRequest(sessionId: sessionId),
            token: token
        )
    }

    func practiceHistory(token: String) async throws -> PracticeHistoryResponse {
        try await get("/practice/history", token: token, queryItems: [])
    }

    func submitTrainingAnswer(sessionId: String, answer: String, token: String) async throws -> TrainingStateResponse {
        try await post(
            "/training/answer",
            body: TrainingAnswerRequest(sessionId: sessionId, answer: answer),
            token: token
        )
    }

    func verifyApplePurchase(_ request: ApplePurchaseVerifyRequest, token: String) async throws -> BillingResponse {
        try await post("/billing/apple/verify", body: request, token: token)
    }

    func billingAccount(token: String) async throws -> BillingAccountResponse {
        try await get("/billing/account", token: token, queryItems: [])
    }

    func createRecharge(amountCents: Int, method: String, planId: String? = nil, token: String) async throws -> RechargeOrderResponse {
        try await post(
            "/billing/recharge",
            body: RechargeCreateRequest(amountCents: amountCents, method: method, planId: planId),
            token: token
        )
    }

    func confirmRecharge(orderId: String, token: String) async throws -> BillingAccountResponse {
        try await post(
            "/billing/recharge/confirm",
            body: RechargeConfirmRequest(orderId: orderId),
            token: token
        )
    }

    func planCatalog() async throws -> PlanCatalogResponse {
        try await get("/billing/plans", token: nil, queryItems: [])
    }

    func createSupportTicket(category: String, subject: String, body: String, images: [String], token: String) async throws -> SupportTicket {
        try await post("/support/tickets", body: SupportTicketCreateRequest(category: category, subject: subject, body: body, images: images), token: token)
    }

    func mySupportTickets(token: String) async throws -> SupportTicketListResponse {
        try await get("/support/tickets", token: token, queryItems: [])
    }

    func subscribe(planId: String, token: String) async throws -> BillingAccountResponse {
        try await post("/billing/subscribe", body: SubscribeRequest(planId: planId), token: token)
    }

    func audioJobs(token: String) async throws -> AudioJobListResponse {
        try await get("/audio/jobs", token: token, queryItems: [])
    }

    /// 断点续传上传：init → 分块 PUT（失败按服务端已收字节续传）→ complete。
    /// 每个报文都带整文件 MD5，服务端据此把文件路由到对应语音服务器。
    /// 返回值：true 表示服务端已有同文件（秒回成功，无需重传）。progress 回调返回 0...1。
    func uploadAudioResumable(
        fileURL: URL,
        token: String,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> Bool {
        let filename = fileURL.lastPathComponent
        let total = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard total > 0 else { throw APIClientError.server("文件为空") }
        let md5 = try Self.fileMD5(fileURL)

        // 1) init（带 md5）。done=true 说明服务端已有同文件，直接成功。
        struct InitReq: Encodable { let filename: String; let size_bytes: Int; let md5: String }
        struct InitResp: Decodable { let upload_id: String; let received_bytes: Int; let done: Bool }
        struct StatusResp: Decodable { let received_bytes: Int }
        let initResp: InitResp = try await post(
            "/audio/upload/init",
            body: InitReq(filename: filename, size_bytes: total, md5: md5),
            token: token
        )
        if initResp.done {
            progress(1.0)
            return true
        }

        // 2) 分块上传（从服务端已收字节处续传）
        let chunkSize = 4 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset = max(0, min(initResp.received_bytes, total))
        progress(Double(offset) / Double(total))
        while offset < total {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            var attempt = 0
            while true {
                attempt += 1
                do {
                    try await putChunk(md5: md5, offset: offset, body: chunk, token: token)
                    offset += chunk.count
                    progress(Double(offset) / Double(total))
                    break
                } catch {
                    if attempt >= 5 { throw error }
                    // 断点续传：查服务端已收字节后重试
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    if let st: StatusResp = try? await get(
                        "/audio/upload/status",
                        token: token,
                        queryItems: [URLQueryItem(name: "md5", value: md5),
                                     URLQueryItem(name: "size_bytes", value: String(total))]
                    ) {
                        offset = st.received_bytes
                    }
                }
            }
        }

        // 3) complete（带 md5 + size_bytes 让服务端校验完整性并打 .ready 标记）
        var comps = URLComponents(url: url(for: "/audio/upload/complete"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "md5", value: md5),
                             URLQueryItem(name: "filename", value: filename),
                             URLQueryItem(name: "size_bytes", value: String(total))]
        guard let completeURL = comps?.url else { throw APIClientError.invalidResponse }
        var request = URLRequest(url: completeURL)
        request.httpMethod = "POST"
        addDefaultHeaders(to: &request, token: token)
        let _: AudioUploadAck = try await send(request)
        return false
    }

    private func putChunk(md5: String, offset: Int, body: Data, token: String) async throws {
        var comps = URLComponents(url: url(for: "/audio/upload/chunk"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "md5", value: md5),
                             URLQueryItem(name: "offset", value: String(offset))]
        guard let u = comps?.url else { throw APIClientError.invalidResponse }
        var request = URLRequest(url: u)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        let (_, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIClientError.server("分块上传失败")
        }
    }

    /// 流式计算文件 MD5（与服务端命名/路由一致）。
    private static func fileMD5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1024 * 1024), chunk.isEmpty == false {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func get<Response: Decodable>(
        _ path: String,
        token: String?,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        var components = URLComponents(url: url(for: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw APIClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60   // 与后端普通档(30s)对齐并留余量
        addDefaultHeaders(to: &request, token: token)
        return try await send(request)
    }

    private func post<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        // 与后端两档超时对齐：普通对话后端 30s 上限，App 留 60s 余量即可；长任务(上传/生成)各自单独设更长
        request.timeoutInterval = 60
        addDefaultHeaders(to: &request, token: token)
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    private func addDefaultHeaders(to request: inout URLRequest, token: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func url(for path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private struct EmptyBody: Encodable {}
    private struct OKResponse: Decodable {}

    private func send<Response: Decodable>(_ request: URLRequest, allowRefresh: Bool = true) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            // 仅对「已带登录凭证」的请求处理（登录/刷新请求本身的 401 不算）
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                // access 多半是过期：先用 refresh 续期并原样重试一次
                if allowRefresh, let newToken = await onNeedsRefresh?() {
                    var retried = request
                    retried.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    return try await send(retried, allowRefresh: false)
                }
                // 续期失败（refresh 也失效/被吊销/换设备）→ 强制退出
                onUnauthorized?()
            }
            throw APIClientError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIClientError.server(error.detail)
            }
            throw APIClientError.server("请求没有完成，请稍后重试")
        }

        return try decoder.decode(Response.self, from: data)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<next]))
            index = next
        }
        return chunks
    }
}
