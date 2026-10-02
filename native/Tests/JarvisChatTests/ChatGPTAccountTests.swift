import Foundation
import JarvisBrain
@testable import JarvisChat
import Synchronization
import Testing

/// B2 part 6: the menus' ChatGPT sign-in item, over a fake `ChatGPTSignInRunning`.
@MainActor
@Suite("B2 ChatGPT sign-in item")
struct ChatGPTAccountTests {
    /// Answers `status` from `statuses` in turn (the last one repeats), and `signIn` with
    /// `result` once `release` is opened (immediately when it is nil).
    final class FakeRunner: ChatGPTSignInRunning, Sendable {
        private let statuses: Mutex<[CodexLoginStatus]>
        private let result: CodexSignInResult
        private let gate: Gate?
        private let counts = Mutex((status: 0, signIn: 0))

        init(_ statuses: [CodexLoginStatus], result: CodexSignInResult = .signedIn, gate: Gate? = nil) {
            self.statuses = Mutex(statuses)
            self.result = result
            self.gate = gate
        }

        var statusCalls: Int { counts.withLock { $0.status } }
        var signInCalls: Int { counts.withLock { $0.signIn } }

        func status() async -> CodexLoginStatus {
            counts.withLock { $0.status += 1 }
            return statuses.withLock { s in s.count > 1 ? s.removeFirst() : s[0] }
        }

        func signIn() async -> CodexSignInResult {
            counts.withLock { $0.signIn += 1 }
            if let gate {
                let opened = await gate.wait()
                if !opened { return .cancelled }
            }
            return result
        }
    }

    /// Opens once; a cancelled waiter returns false.
    actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Bool, Never>] = []

        func wait() async -> Bool {
            if opened { return true }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: {
                Task { await self.cancelAll() }
            }
        }

        func open() {
            opened = true
            waiters.forEach { $0.resume(returning: true) }
            waiters = []
        }

        private func cancelAll() {
            waiters.forEach { $0.resume(returning: false) }
            waiters = []
        }
    }

    @Test func statusDecidesTheItem() async {
        let account = ChatGPTAccount(runner: FakeRunner([.signedIn]))
        #expect(account.state == .checking && !account.actionable)
        #expect(account.title == "Checking the ChatGPT sign-in…")
        await account.refresh()
        #expect(account.state == .signedIn)
        #expect(account.title == "Signed in to ChatGPT" && !account.actionable)

        let out = ChatGPTAccount(runner: FakeRunner([.signedOut]))
        await out.refresh()
        #expect(out.state == .signedOut && out.actionable && out.title == "Sign in to ChatGPT…")

        let none = ChatGPTAccount(runner: FakeRunner([.unavailable("Codex CLI not found")]))
        await none.refresh()
        #expect(none.state == .unavailable("Codex CLI not found") && !none.actionable)
        #expect(none.title == "Sign in to ChatGPT… (needs the ChatGPT app)")
        #expect(none.help.hasPrefix("Codex CLI not found. "))
    }

    @Test func signingInThenSignedIn() async {
        let gate = Gate()
        let runner = FakeRunner([.signedOut], result: .signedIn, gate: gate)
        let account = ChatGPTAccount(runner: runner)
        await account.refresh()
        account.act()
        #expect(account.state == .signingIn && account.title == "Cancel ChatGPT Sign-in" && account.actionable)
        // A status read while the browser flow runs does not change the item.
        await account.refresh()
        #expect(account.state == .signingIn)
        await gate.open()
        await account.waitForSignIn()
        #expect(account.state == .signedIn && account.title == "Signed in to ChatGPT")
        #expect(runner.signInCalls == 1)
    }

    @Test func cancellingFromTheItem() async {
        let gate = Gate()
        let account = ChatGPTAccount(runner: FakeRunner([.signedOut], gate: gate))
        await account.refresh()
        account.act()
        #expect(account.state == .signingIn)
        account.act()   // "Cancel ChatGPT Sign-in"
        await account.waitForSignIn()
        #expect(account.state == .signedOut && account.title == "Sign in to ChatGPT…")
    }

    @Test func aFailedSignInSaysSoUntilTheNextTry() async {
        let runner = FakeRunner([.signedOut], result: .failed("codex login exited 1"))
        let account = ChatGPTAccount(runner: runner)
        await account.refresh()
        account.signIn()
        await account.waitForSignIn()
        #expect(account.state == .failed("codex login exited 1"))
        #expect(account.title == "Sign in to ChatGPT… (the last try didn't finish)" && account.actionable)
        #expect(account.help.hasPrefix("The last sign-in didn't finish: codex login exited 1. "))
        await account.refresh()   // still signed out: the failure stays shown
        #expect(account.state == .failed("codex login exited 1"))
    }
}
