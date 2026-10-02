import Foundation
import JarvisCore
import Synchronization

/// W1 parts 3 and 4: the pages waiting for a summary in the web memory are summarised in the
/// background, at background priority, one at a time and never while a turn runs (the same
/// `TurnActivity` wait the file scan uses). `kick()` starts a run when none is going; it ends
/// when no page is left (or none could be summarised). `stop()` cancels it, before the lease goes.
public final class WebSummaryQueue: Sendable {
    /// Pages summarised per batch, between checks for more.
    public static let batch = 5

    private let memory: WebMemory
    private let summarizer: any PageSummarizing
    private let turns: TurnActivity
    private let sleep: TurnActivity.Sleep
    private let running = Mutex<Task<Void, Never>?>(nil)

    public init(memory: WebMemory, summarizer: any PageSummarizing, turns: TurnActivity,
                sleep: @escaping TurnActivity.Sleep = { try await Task.sleep(for: $0, clock: .suspending) }) {
        self.memory = memory
        self.summarizer = summarizer
        self.turns = turns
        self.sleep = sleep
    }

    /// Starts summarising the pending pages, unless a run is already going.
    public func kick() {
        running.withLock { task in
            guard task == nil else { return }
            task = Task.detached(priority: .background) { [self] in
                await self.drain()
                self.running.withLock { $0 = nil }
            }
        }
    }

    /// The run: batches until none is left or a batch summarises none.
    func drain() async {
        let turns = turns, sleep = sleep
        while !Task.isCancelled {
            let done = await memory.summarizePending(limit: Self.batch, with: summarizer,
                                                     beforeEach: { try await turns.waitUntilIdle(sleep: sleep) })
            if done == 0 { return }
        }
    }

    /// Whether a run is going.
    public var isRunning: Bool { running.withLock { $0 != nil } }

    public func stop() {
        running.withLock { task in
            task?.cancel()
            task = nil
        }
    }
}
