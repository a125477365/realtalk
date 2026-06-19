import Foundation

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

    func todayScenarios(token: String) async throws -> ScenarioListResponse {
        try await get("/scenario/today", token: token, queryItems: [])
    }

    func scenarioList(token: String) async throws -> ScenarioListResponse {
        try await get("/scenario/list", token: token, queryItems: [])
    }

    func scenarioDetail(sceneId: String, token: String) async throws -> ScenarioResponse {
        try await get("/scenario/\(sceneId)", token: token, queryItems: [])
    }

    func startRoleplay(
        start: Date,
        end: Date,
        selectedRole: String,
        sceneId: String?,
        segments: [TranscriptSegment],
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
                items: items
            ),
            token: token
        )
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

    func subscribe(planId: String, token: String) async throws -> BillingAccountResponse {
        try await post("/billing/subscribe", body: SubscribeRequest(planId: planId), token: token)
    }

    func audioJobs(token: String) async throws -> AudioJobListResponse {
        try await get("/audio/jobs", token: token, queryItems: [])
    }

    /// 大音频文件上传：multipart 先拼到临时文件再流式上传，避免 300MB 进内存
    func uploadAudio(fileURL: URL, token: String) async throws -> AudioJob {
        let boundary = "rt-\(UUID().uuidString)"
        let filename = fileURL.lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let prelude = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/mpeg\r\n\r\n"
        let epilogue = "\r\n--\(boundary)--\r\n"
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try handle.write(contentsOf: Data(prelude.utf8))
        let input = try FileHandle(forReadingFrom: fileURL)
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), chunk.isEmpty == false {
            try handle.write(contentsOf: chunk)
        }
        try input.close()
        try handle.write(contentsOf: Data(epilogue.utf8))
        try handle.close()

        var request = URLRequest(url: url(for: "/audio/upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 1800

        let (data, response) = try await session.upload(for: request, fromFile: tempURL)
        guard let httpResponse = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIClientError.server(error.detail)
            }
            throw APIClientError.server("上传失败：HTTP \(httpResponse.statusCode)")
        }
        return try decoder.decode(AudioJob.self, from: data)
    }

    /// 断点续传上传：init → 分块 PUT（失败按服务端已收字节续传）→ complete。
    /// progress 回调返回 0...1，便于 UI 显示进度。
    func uploadAudioResumable(
        fileURL: URL,
        token: String,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> AudioJob {
        let filename = fileURL.lastPathComponent
        let total = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard total > 0 else { throw APIClientError.server("文件为空") }

        // 1) init
        struct InitReq: Encodable { let filename: String; let size_bytes: Int }
        struct InitResp: Decodable { let upload_id: String; let received_bytes: Int }
        struct StatusResp: Decodable { let received_bytes: Int }
        let initResp: InitResp = try await post("/audio/upload/init", body: InitReq(filename: filename, size_bytes: total), token: token)
        let uploadId = initResp.upload_id

        // 2) 分块上传
        let chunkSize = 4 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset = 0
        while offset < total {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            var attempt = 0
            while true {
                attempt += 1
                do {
                    try await putChunk(uploadId: uploadId, offset: offset, body: chunk, token: token)
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
                        queryItems: [URLQueryItem(name: "upload_id", value: uploadId),
                                     URLQueryItem(name: "size_bytes", value: String(total))]
                    ) {
                        offset = st.received_bytes
                    }
                }
            }
        }

        // 3) complete
        var comps = URLComponents(url: url(for: "/audio/upload/complete"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "upload_id", value: uploadId),
                             URLQueryItem(name: "filename", value: filename)]
        guard let completeURL = comps?.url else { throw APIClientError.invalidResponse }
        var request = URLRequest(url: completeURL)
        request.httpMethod = "POST"
        addDefaultHeaders(to: &request, token: token)
        return try await send(request)
    }

    private func putChunk(uploadId: String, offset: Int, body: Data, token: String) async throws {
        var comps = URLComponents(url: url(for: "/audio/upload/chunk"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "upload_id", value: uploadId),
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

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            // 仅对「已带登录凭证」的请求触发自动退出（登录请求本身的 401 不算）
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                onUnauthorized?()
            }
            throw APIClientError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIClientError.server(error.detail)
            }
            throw APIClientError.server("请求失败：HTTP \(httpResponse.statusCode)")
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
