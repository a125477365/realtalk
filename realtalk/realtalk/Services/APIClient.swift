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

    func wechatLogin(code: String, nickname: String?, avatarUrl: String?) async throws -> AuthResponse {
        try await post(
            "/auth/wechat/login",
            body: WeChatLoginRequest(code: code, nickname: nickname, avatarUrl: avatarUrl),
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

    func uploadTranscripts(_ segments: [TranscriptSegment], token: String) async throws -> TranscriptUploadResponse {
        let items = segments.map { TranscriptUploadItem(id: $0.id, timestamp: $0.timestamp, text: $0.text) }
        return try await post("/transcript/upload", body: TranscriptUploadRequest(items: items), token: token)
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

    func submitRoleplayMessage(sessionId: String, message: String, token: String) async throws -> RoleplayStateResponse {
        try await post(
            "/roleplay/message",
            body: RoleplayMessageRequest(sessionId: sessionId, message: message),
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

    func createRecharge(amountCents: Int, method: String, token: String) async throws -> RechargeOrderResponse {
        try await post(
            "/billing/recharge",
            body: RechargeCreateRequest(amountCents: amountCents, method: method),
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
