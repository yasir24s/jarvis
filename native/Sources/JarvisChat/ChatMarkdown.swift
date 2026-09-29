import Foundation
import JarvisCore

/// How a finished assistant row reads as markdown (plan: M02-M04 §3.12, `MarkdownText`).
public enum ChatMarkdown {
    /// Inline syntax only (emphasis, code, links), with the reply's own line breaks kept.
    public static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)

    /// The row's attributed text. Text the parser rejects is shown as it is.
    public static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The text a finished assistant row keeps once its turn ends.
public enum ReplyText {
    /// `reply` is what the turn returned; `shown` is what streamed into the row. The streamed
    /// text is kept when it has the same words as the reply, because it keeps the line breaks
    /// the markdown needs (a returned reply joins its sentences with single spaces). Otherwise
    /// the reply wins: a failed stream or a retracted message (R6) can leave streamed text the
    /// reply does not include. An empty reply keeps what was shown; "" means no row.
    public static func finished(reply: String, shown: String) -> String {
        let reply = Py.strip(reply)
        let shown = Py.strip(shown)
        if reply.isEmpty { return shown }
        return Py.split(shown) == Py.split(reply) ? shown : reply
    }
}
