import JarvisChat
import JarvisCore
import SwiftUI

/// A finished assistant row (plan: M02-M04 §3.12): inline markdown with the reply's line
/// breaks kept (`ChatMarkdown.options`). Links render, and open only when clicked, and only for
/// http and https (`ChatLinks`); any other link is ignored and logged. Streaming rows and user
/// rows do not come here; they are plain text.
struct MarkdownText: View {
    let text: String

    var body: some View {
        Text(ChatMarkdown.attributed(text))
            .environment(\.openURL, OpenURLAction { url in
                ChatLinks.opens(url, log: { JarvisLog.log($0, category: .security) }) ? .systemAction : .discarded
            })
    }
}
