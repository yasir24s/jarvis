import Darwin
import Foundation
import JarvisCore
import WebKit

/// W1 part 2: JARVIS reads the web with Safari's engine, never the Safari app. Each read opens
/// an offscreen `WKWebView` on its own non-persistent `WKWebsiteDataStore` (no cookies, cache or
/// logins survive it, and none of the user's are seen), refuses downloads and anything that is
/// not http(s), waits for the page to settle (at most `WebReading.settleLimit` from the start),
/// runs `ReadabilityScript`, and tears the tab down. At most `WebReading.maxTabs` are open at
/// once; a read past that waits its turn. Logs carry the host, sizes and times, never text.
@MainActor
final class WebReader: NSObject, PageReading {
    /// What one read cost, for the log and the live checks.
    struct Stats: Sendable, Equatable {
        var elapsed: Duration
        /// The tab's WebContent process footprint when the page settled, nil when unknown.
        var tabFootprint: Int?
        /// JARVIS's own footprint change across the read.
        var ownFootprintDelta: Int
    }

    private let settleLimit: Duration
    private let poll: Duration
    private let log: @Sendable (String) -> Void
    nonisolated private let gate = TabGate(limit: WebReading.maxTabs)
    private(set) var openTabs = 0
    private(set) var peakTabs = 0
    private(set) var lastStats: Stats?

    init(settleLimit: Duration = WebReading.settleLimit, poll: Duration = .milliseconds(500),
         log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .tools) }) {
        self.settleLimit = settleLimit
        self.poll = poll
        self.log = log
    }

    nonisolated func read(_ url: String) async throws -> ReadPage {
        try await readWithStats(url).page
    }

    /// `read`, with what it cost.
    nonisolated func readWithStats(_ url: String) async throws -> (page: ReadPage, stats: Stats) {
        guard WebReading.isWebURL(url), let target = URL(string: url) else { throw PageReadError.notWeb }
        await gate.enter()
        do {
            let result = try await self.load(target, requested: url)
            await gate.leave()
            return result
        } catch {
            await gate.leave()
            throw error
        }
    }

    /// The private configuration every tab gets: nothing persists, nothing opens windows,
    /// nothing plays.
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15 JARVIS/1.0"
        return configuration
    }

    private func load(_ target: URL, requested: String) async throws -> (page: ReadPage, stats: Stats) {
        let clock = ContinuousClock()
        let start = clock.now
        let ownBefore = Self.ownFootprint()
        let tab = Tab(configuration: Self.configuration())
        openTabs += 1
        peakTabs = max(peakTabs, openTabs)
        defer {
            tab.close()
            openTabs -= 1
        }
        let deadline = start.advanced(by: settleLimit)
        try await tab.load(target, until: deadline)
        try await settle(tab.view, until: deadline)
        try Task.checkCancellation()    // V11: a read the user preempted stops here
        let footprint = tab.webContentFootprint()
        let raw = try await tab.view.evaluateJavaScript(ReadabilityScript.source) as? String ?? ""
        guard case .object(let o)? = try? PyJSON.loads(Data(raw.utf8)) else { throw PageReadError.nothingReadable }
        let finalURL = o["url"]?.stringValue ?? tab.view.url?.absoluteString ?? requested
        let page = ReadPage.from(requested: requested, finalURL: WebReading.isWebURL(finalURL) ? finalURL : requested,
                                 title: o["title"]?.stringValue ?? "", canonical: o["canonical"]?.stringValue ?? "",
                                 text: o["text"]?.stringValue ?? "")
        guard !page.text.isEmpty else { throw PageReadError.nothingReadable }
        let stats = Stats(elapsed: clock.now - start, tabFootprint: footprint,
                          ownFootprintDelta: Self.ownFootprint() - ownBefore)
        lastStats = stats
        log("web: read a page from \(target.host ?? "?") (\(Py.len(page.text)) characters\(page.truncated ? ", cut" : "")) "
            + "in \(Self.seconds(stats.elapsed)), tab \(footprint.map(Self.megabytes) ?? "?")")
        return (page, stats)
    }

    /// Waits until the document is complete and its text has stopped growing for two polls
    /// in a row, or the deadline passes (then the page is read as it is).
    private func settle(_ view: WKWebView, until deadline: ContinuousClock.Instant) async throws {
        var last = -1, steady = 0
        while ContinuousClock.now < deadline {
            let probe = try? await view.evaluateJavaScript(
                "document.readyState + '|' + (document.body ? document.body.innerText.length : 0)") as? String
            let parts = (probe ?? "").split(separator: "|")
            let complete = parts.first == "complete"
            let length = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            if complete, length == last { steady += 1 } else { steady = 0 }
            if steady >= 2 { return }
            last = length
            try await Task.sleep(for: poll)
        }
    }

    /// JARVIS's own physical footprint, in bytes.
    nonisolated static func ownFootprint() -> Int {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return ok == 0 ? Int(info.ri_phys_footprint) : 0
    }

    /// Another process's physical footprint (a WebContent process of ours), nil when unknown.
    nonisolated static func footprint(of pid: pid_t) -> Int? {
        guard pid > 0 else { return nil }
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        return ok == 0 ? Int(info.ri_phys_footprint) : nil
    }

    nonisolated static func megabytes(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

    nonisolated static func seconds(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.2f s", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }
}

/// One offscreen tab and its navigation: http(s) and about:blank only, no downloads, no new
/// windows. `load` returns once the main frame has finished (or failed, which throws).
@MainActor
private final class Tab: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var waiter: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    init(configuration: WKWebViewConfiguration) {
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 2000), configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func load(_ url: URL, until deadline: ContinuousClock.Instant) async throws {
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: max(1, Double((deadline - ContinuousClock.now).components.seconds))))
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self?.finish(.failure(PageReadError.timedOut))
        }
        defer { timer.cancel() }
        // V11 part 3: cancelling the read stops the load at once, not when the page settles.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if let outcome { c.resume(with: outcome) } else { waiter = c }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.view.stopLoading()
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiter?.resume(with: result)
        waiter = nil
    }

    /// The WebContent process's footprint (WebKit's private `_webProcessIdentifier`; nil if gone).
    func webContentFootprint() -> Int? {
        let pid = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        return WebReader.footprint(of: pid)
    }

    func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        finish(.failure(PageReadError.failed("closed")))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .cancel }
        guard navigationAction.targetFrame != nil else { return .cancel }            // a new window
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        return ["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.canShowMIMEType else {
            if navigationResponse.isForMainFrame { finish(.failure(PageReadError.refused)) }
            return .cancel
        }
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            finish(.failure(PageReadError.failed("HTTP \(http.statusCode)")))   // an error page is not the page
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(PageReadError.failed((error as NSError).localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(PageReadError.failed((error as NSError).localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(PageReadError.failed("the page's process ended")))
    }
}

/// At most `limit` reads at once; the rest wait in order.
actor TabGate {
    private let limit: Int
    private var open = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if open < limit {
            open += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            open = max(0, open - 1)
        } else {
            waiting.removeFirst().resume()          // the slot passes straight on
        }
    }
}
