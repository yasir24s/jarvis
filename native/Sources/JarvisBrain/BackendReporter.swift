import Foundation
import JarvisCore

// Backend reporting (plan: M02-M04 §3.10). T3.1 ships the research counter key; the actor's
// state (`set`, `report(localModelName:)`, `last`) arrives with the Claude driver.

public actor BackendReporter {
    /// `_set_backend`'s counter: `"backend_" + re.sub(r"\W+", "_", name.lower())`.
    /// Counter names come from `ResearchKey` (call sites never build them), so this is
    /// `ResearchKey.backend`; golden suite m3_backend_key runs the real `_set_backend`.
    public static func counterKey(_ name: String) -> String {
        ResearchKey.backend(name)
    }
}
