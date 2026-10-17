import Foundation

/// Runs `work` on its own thread and resumes with its result.
///
/// Blocking inside an async test holds a cooperative-pool thread, and the pool
/// is only as wide as the machine has cores. On a small CI runner, blocked
/// tests starve the tasks they wait for (a relay's connect, a main-actor
/// reply), so blocking calls in async tests go through here.
func runOnThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: work()) }
    }
}

/// Like `runOnThread(_:)`, for work that throws.
func runOnThread<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await runOnThread { Result { try work() } }.get()
}
