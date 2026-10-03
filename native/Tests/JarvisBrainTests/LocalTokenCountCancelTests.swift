import Foundation
import Synchronization
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// Live fix 2: Stop during an on-device turn logged "token count failed … CancellationError()"
/// seven times, once per count of the selection's bisection. A cancelled turn now asks the
/// tokenizer nothing more and logs no failure.
@Suite("Token counting stops when the turn is cancelled (live fix 2)")
struct LocalTokenCountCancelTests {
    /// Counts each call; `cancelling` throws CancellationError as the tokenizer does once its
    /// task is cancelled.
    final class CountingCounter: LocalTokenCounting {
        let calls = Mutex(0)
        let cancelling: Bool
        init(cancelling: Bool) { self.cancelling = cancelling }
        var contextSize: Int { 1000 }       // the catalog does not fit: CORE-21, trimmed
        var estimates: Bool { false }
        func tokenCount(tools: [DynamicTool]) async throws -> Int {
            calls.withLock { $0 += 1 }
            if cancelling { throw CancellationError() }
            return tools.count * 100
        }
        func tokenCount(instructions: String) async throws -> Int {
            calls.withLock { $0 += 1 }
            if cancelling { throw CancellationError() }
            return 10
        }
    }

    @Test func aCancelledTurnAsksTheTokenizerNothing() async throws {
        let counter = CountingCounter(cancelling: false)
        let logged = Mutex<[String]>([])
        let all = LocalToolsetTests.catalogTools()
        let selection = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LocalToolset.select(from: all, instructions: "x", counter: counter,
                                             log: { line in logged.withLock { $0.append(line) } })
        }
        _ = await selection.value
        #expect(counter.calls.withLock { $0 } == 0)
        #expect(!logged.withLock { $0 }.contains { $0.contains("token count failed") })
    }

    @Test func aCancellationErrorIsNotLoggedAsAFailure() async throws {
        let counter = CountingCounter(cancelling: true)
        let logged = Mutex<[String]>([])
        let selection = await LocalToolset.select(from: LocalToolsetTests.catalogTools(), instructions: "x",
                                                  counter: counter,
                                                  log: { line in logged.withLock { $0.append(line) } })
        #expect(!logged.withLock { $0 }.contains { $0.contains("token count failed") })
        #expect(!selection.tools.isEmpty)                 // the estimate stood in
    }

    @Test func anOrdinaryFailureIsStillLogged() async throws {
        let logged = Mutex<[String]>([])
        _ = await LocalToolset.select(from: LocalToolsetTests.catalogTools(), instructions: "x",
                                      counter: FakeCounter(contextSize: 1000, failing: true),
                                      log: { line in logged.withLock { $0.append(line) } })
        #expect(logged.withLock { $0 }.contains { $0.contains("token count failed") })
    }
}
