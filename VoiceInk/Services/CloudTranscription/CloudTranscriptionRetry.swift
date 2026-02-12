import Foundation
import os

enum CloudTranscriptionRetry {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CloudTranscriptionRetry")

    static func withRetry<T>(
        maxRetries: Int = 2,
        initialDelay: TimeInterval = 1.0,
        operation: () async throws -> T
    ) async throws -> T {
        var retries = 0
        var currentDelay = initialDelay

        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as CloudTranscriptionError {
                guard shouldRetry(error: error), retries < maxRetries else {
                    throw error
                }
                retries += 1
                logger.warning("Request failed, retrying in \(currentDelay)s... (Attempt \(retries)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                currentDelay *= 2
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSURLErrorDomain &&
                      [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(nsError.code),
                      retries < maxRetries else {
                    throw error
                }
                retries += 1
                logger.warning("Network error, retrying in \(currentDelay)s... (Attempt \(retries)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                currentDelay *= 2
            }
        }
    }

    private static func shouldRetry(error: CloudTranscriptionError) -> Bool {
        switch error {
        case .networkError:
            return true
        case .apiRequestFailed(let statusCode, _):
            return statusCode == 429 || (500...599).contains(statusCode)
        default:
            return false
        }
    }
}
