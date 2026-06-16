import Foundation
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "network-retry")

/// 网络请求重试工具。
///
/// 对瞬时故障（网络中断、5xx 服务端错误、408 超时、429 限流）做指数退避重试。
/// 业务错误（4xx 鉴权/参数错误等）不重试，直接抛出。
enum NetworkRetry {
    /// 默认重试策略：最多重试 2 次（共 3 次请求），初始退避 1s，指数 2 倍。
    static let defaultMaxRetries = 2
    static let defaultInitialDelay: UInt64 = 1_000_000_000 // 1 秒（纳秒）

    /// 执行一个可能因网络瞬时故障失败的异步操作，按需重试。
    ///
    /// - Parameters:
    ///   - maxRetries: 失败后的最大重试次数（不含首次请求）。
    ///   - initialDelayNanos: 首次重试前等待的纳秒数，每次重试翻倍。
    ///   - isRetryable: 判定抛出的错误是否值得重试（如网络错误、5xx、408、429）。
    ///   - operation: 实际的异步操作，返回值即为最终结果（放最后，便于尾随闭包语法）。
    static func perform<T>(
        maxRetries: Int = defaultMaxRetries,
        initialDelayNanos: UInt64 = defaultInitialDelay,
        isRetryable: (Error) -> Bool,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var delay = initialDelayNanos
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxRetries, isRetryable(error) else {
                    throw error
                }
                attempt += 1
                logger.warning("Retryable failure (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription). Retrying in \(delay / 1_000_000)s.")
                try? await Task.sleep(nanoseconds: delay)
                delay &*= 2
            }
        }
    }

    /// 判定一个错误是否为可重试的网络/服务端瞬时故障。
    ///
    /// 命中条件（满足任一）：
    /// - `URLError` 且非用户取消类（如超时、断网、连接重置、DNS 失败等）；
    /// - 包装在错误描述中的 HTTP 5xx / 408 / 429 状态码（由调用方在包装错误时带上 "HTTP <code>" 前缀）。
    ///
    /// 调用方应针对自己的错误类型提供更精确的 `isRetryable`，本函数作为通用兜底。
    static func isRetryableError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // URLError 域：网络层瞬时故障
        if nsError.domain == NSURLErrorDomain {
            let code = nsError.code
            switch code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorSecureConnectionFailed:
                return true
            // 用户主动取消不重试
            case NSURLErrorCancelled:
                return false
            default:
                return true
            }
        }
        return false
    }

    /// 从错误描述中检测可重试的 HTTP 状态码（5xx / 408 / 429）。
    /// 调用方在包装 HTTP 错误时已用 "HTTP <statusCode>: ..." 格式，便于此处正则匹配。
    static func isRetryableHTTPStatus(in description: String) -> Bool {
        // 匹配 "HTTP 5xx" / "HTTP 408" / "HTTP 429"
        guard let range = description.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else {
            return false
        }
        let matched = description[range]
        // 提取数字部分
        let digits = matched.filter { $0.isNumber }
        guard let code = Int(digits) else { return false }
        return code == 408 || code == 429 || (500..<600).contains(code)
    }
}
