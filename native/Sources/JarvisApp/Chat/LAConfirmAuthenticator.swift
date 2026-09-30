import Foundation
import JarvisChat
import LocalAuthentication
import Synchronization

/// The typed channel's owner check (plan: M02-M04 §3.4): Touch ID, or the login password. Each
/// confirmation gets a fresh `LAContext` with no Touch ID reuse, and a sheet still up after
/// 60 s is invalidated and counts as a no. The sheet runs out of process, so neither
/// `type_text` nor AppleScript can answer it. Tests never use this type: it would put the
/// system sheet on the screen. They use a fake `TextConfirmAuthenticator`.
struct LAConfirmAuthenticator: TextConfirmAuthenticator {
    func canAuthenticate() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// `reason` is the confirmation's description; the sheet says "confirm: <reason>".
    func authenticate(reason: String) async -> Bool {
        let prompt = OwnerCheck()
        var error: NSError?
        guard prompt.context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await prompt.run(reason: TextConfirmation.localizedReason(reason))
    }
}

/// One system sheet. Its continuation is resumed exactly once: by the sheet's reply, or by the
/// 60 s timer, which invalidates the context first.
private final class OwnerCheck: @unchecked Sendable {
    // Unchecked: `context` is touched from two threads, the sheet's reply and the timer's
    // `invalidate()`, which is LocalAuthentication's call for cancelling a sheet that is up.
    let context: LAContext
    private let state = Mutex<(continuation: CheckedContinuation<Bool, Never>?, timer: Task<Void, Never>?)>((nil, nil))

    init() {
        context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = TextConfirmation.fallbackTitle
    }

    func run(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let timer = Task { [self] in
                try? await Task.sleep(for: TextConfirmation.promptTimeout)
                guard !Task.isCancelled else { return }
                context.invalidate()
                finish(false)
            }
            state.withLock { $0 = (continuation, timer) }
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [self] approved, _ in
                finish(approved)
            }
        }
    }

    private func finish(_ approved: Bool) {
        let (continuation, timer) = state.withLock { state in
            defer { state = (nil, nil) }
            return state
        }
        timer?.cancel()
        continuation?.resume(returning: approved)
    }
}
