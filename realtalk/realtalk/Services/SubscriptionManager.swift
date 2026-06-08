import Combine
import Foundation
import StoreKit

@MainActor
final class SubscriptionManager: ObservableObject {
    enum SubscriptionError: LocalizedError {
        case failedVerification

        var errorDescription: String? {
            "交易签名校验失败"
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var statusMessage = ""

    private let api: APIClient
    private var updatesTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        updatesTask = listenForTransactions()
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            products = try await Product.products(for: [AppConfig.subscriptionProductID])
            await refreshEntitlements()
            if products.isEmpty {
                statusMessage = "未找到内购商品，请在 App Store Connect 或 StoreKit 配置中创建 \(AppConfig.subscriptionProductID)"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product, auth: AuthStore) async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                let billing = try await api.verifyApplePurchase(
                    ApplePurchaseVerifyRequest(
                        productId: transaction.productID,
                        transactionId: String(transaction.id),
                        originalTransactionId: String(transaction.originalID),
                        jwsRepresentation: nil
                    ),
                    token: token
                )
                auth.applyBillingUser(billing.user)
                purchasedProductIDs.insert(transaction.productID)
                await transaction.finish()
                statusMessage = billing.message
            case .pending:
                statusMessage = "购买等待确认"
            case .userCancelled:
                statusMessage = "已取消购买"
            @unknown default:
                statusMessage = "购买状态未知"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var active: Set<String> = []
        for await verification in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(verification) {
                active.insert(transaction.productID)
            }
        }
        purchasedProductIDs = active
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task {
            for await verification in Transaction.updates {
                guard let transaction = try? checkVerified(verification) else { continue }
                purchasedProductIDs.insert(transaction.productID)
                await transaction.finish()
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SubscriptionError.failedVerification
        case .verified(let signedType):
            return signedType
        }
    }
}
