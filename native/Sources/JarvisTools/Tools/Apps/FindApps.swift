import CoreServices
import Foundation
import JarvisCore

/// The app index (plan: M05-M06 §3.4 AppIndex): `build_app_index`'s mdfind listing, then
/// `_enrich_app_index` over each bundle's Info.plist. Python builds it once at startup and
/// enriches in a thread; native builds it on the first `find_apps` and enriches before
/// answering, which is Python's steady state (A-APP-1 compares against exactly that). A failed
/// listing (mdfind missing, a timeout, undecodable output) answers that call from an empty
/// index, as Python does, and is retried on the next call.
actor AppIndex {
    static let query = ["/usr/bin/mdfind", "kMDItemContentType == 'com.apple.application-bundle'"]
    /// `build_app_index`'s mdfind timeout.
    static let timeout = 20.0

    private let runner: any CommandRunning
    private let loadPlist: @Sendable (String) -> PlistValue?
    private var built: AppCatalog?
    private var building: Task<AppCatalog?, Never>?

    init(runner: any CommandRunning, loadPlist: @escaping @Sendable (String) -> PlistValue? = PlistValue.load) {
        self.runner = runner
        self.loadPlist = loadPlist
    }

    func catalog() async -> AppCatalog {
        if let built { return built }
        let task = building ?? Task { [runner, loadPlist] in
            guard let output = await runner.run(Self.query, timeout: Self.timeout), !output.timedOut,
                  let stdout = PyText.decode(output.stdout) else { return nil }
            let entries = AppKinds.index(fromMdfind: stdout)
            return AppCatalog(entries: entries, meta: AppKinds.enrich(entries, load: loadPlist) ?? [:])
        }
        building = task
        let result = await task.value
        building = nil
        if let result { built = result }
        return result ?? AppCatalog()
    }
}

/// The app that opens https URLs, as `_default_browser_name` reads it. Tests inject a stub.
protocol DefaultBrowserLookup: Sendable {
    /// The bundle's file name without ".app", or "" when there is none.
    func defaultBrowserName() async -> String
}

/// `NSWorkspace.URLForApplicationToOpenURL(https://example.com)` in Python. Native asks
/// LaunchServices directly (`LSCopyDefaultApplicationURLForURL`, which NSWorkspace wraps), so
/// AppKit stays out of JarvisTools.
struct LiveDefaultBrowser: DefaultBrowserLookup {
    func defaultBrowserName() async -> String {
        guard let url = URL(string: "https://example.com"),
              let app = LSCopyDefaultApplicationURLForURL(url as CFURL, .all, nil)?.takeRetainedValue() else { return "" }
        let base = (app as URL).lastPathComponent
        return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
    }
}

/// `find_apps` (plan: M05-M06 §2a, §3.5, A-APP-1): a kind query lists up to 12 installed apps
/// of that kind (the default browser marked), any other query the first 10 index entries whose
/// lowercased name contains it, as "Name (kinds)". Python joins each app's kinds from a set,
/// in hash order; native sorts them.
struct FindApps: ToolImpl {
    static let name = "find_apps"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let index: AppIndex
    let browser: any DefaultBrowserLookup

    /// `_find_apps(args.get("query", ""))`: `(query or "").lower()`, so a falsy value acts as ""
    /// (and is echoed with `str()` in the no-match reply) and any other non-str raises.
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let query = try PyArgs.stringOrEmpty(args, "query", method: "lower")
        let echo = args["query"].map { PyArgs.str($0) } ?? ""
        let catalog = await index.catalog()
        return .text(await AppKinds.findApps(query, catalog, echo: echo,
                                             defaultBrowser: { await browser.defaultBrowserName() }))
    }
}
