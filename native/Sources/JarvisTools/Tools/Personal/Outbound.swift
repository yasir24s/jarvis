import Foundation
import JarvisCore

/// `send_message`, Python's `_send_message` (jarvis.py 3214-3237): an iMessage through Messages'
/// AppleScript, with the legacy `buddy` form as the fallback. The recipient is resolved first,
/// then the user is asked: native sends nothing until they confirm (Python sent at once; D-41,
/// DEVIATIONS). An executor, so the taint guard refuses it after untrusted reads.
struct SendMessage: ToolImpl {
    static let name = "send_message"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let lookup: ContactLookup
    var log: @Sendable (String) -> Void = { _ in }

    static func script(text: String, handle: String) -> String {
        "tell application \"Messages\"\n"
            + "  set svc to 1st account whose service type = iMessage\n"
            + "  send \"\(AppleScriptText.escape(text))\" to participant \"\(AppleScriptText.escape(handle))\" of svc\n"
            + "end tell"
    }

    static func legacyScript(text: String, handle: String) -> String {
        "tell application \"Messages\" to send \"\(AppleScriptText.escape(text))\" to buddy "
            + "\"\(AppleScriptText.escape(handle))\" of (service 1 whose service type is iMessage)"
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let text = Py.strip(try PyArgs.stringOrEmpty(args, "text", method: "strip"))
        if text.isEmpty { return .text("What would you like the message to say, sir?") }
        let recipientValue = args["recipient"] ?? .string("")
        let recipient = try PyArgs.stringOrEmpty(args, "recipient", method: "strip")
        let shown = PyArgs.str(recipientValue)
        let handle = await lookup.handle(recipient, preferEmail: false)
        if handle.isEmpty { return .text("I couldn't find \(shown) in your contacts, sir.") }
        let scripts = lookup.scripts, log = self.log
        let desc = "That will message \(shown) at \(handle): \(Py.prefix(text, 120))"
        return .needsConfirmation(desc: desc) {
            var out = await scripts.run(Self.script(text: text, handle: handle))
            if AppleScriptText.mentionsError(out) {
                out = await scripts.run(Self.legacyScript(text: text, handle: handle))
            }
            if AppleScriptText.mentionsError(out) {
                return "I couldn't send that message, sir — check Messages automation permission."
            }
            log("SENT iMessage")
            return "Message sent to \(shown), sir."
        }
    }
}

/// `send_email`, Python's `_send_email` (jarvis.py 3239-3257): Mail's AppleScript, sent without a
/// window. As send_message, the address is resolved first and nothing is sent until the user
/// confirms (D-41, DEVIATIONS).
struct SendEmail: ToolImpl {
    static let name = "send_email"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let lookup: ContactLookup
    var log: @Sendable (String) -> Void = { _ in }

    static func script(subject: String, body: String, address: String) -> String {
        "tell application \"Mail\"\n"
            + "  set m to make new outgoing message with properties {subject:\"\(AppleScriptText.escape(subject))\", "
            + "content:\"\(AppleScriptText.escape(body))\", visible:false}\n"
            + "  tell m to make new to recipient at end of to recipients "
            + "with properties {address:\"\(AppleScriptText.escape(address))\"}\n"
            + "  send m\n"
            + "end tell"
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let toValue = args["to"] ?? .string("")
        let to = try PyArgs.stringOrEmpty(args, "to", method: "strip")
        let shown = PyArgs.str(toValue)
        let address = await lookup.handle(to, preferEmail: true)
        if !Py.contains(address, "@") { return .text("I couldn't find an email address for \(shown), sir.") }
        let subject = try PyArgs.stringOrEmpty(args, "subject", method: "replace")
        let body = try PyArgs.stringOrEmpty(args, "body", method: "replace")
        let scripts = lookup.scripts, log = self.log
        let about = Py.strip(subject).isEmpty ? "" : " about \(Py.prefix(Py.strip(subject), 80))"
        return .needsConfirmation(desc: "That will email \(shown) at \(address)\(about)") {
            let out = await scripts.run(Self.script(subject: subject, body: body, address: address))
            if AppleScriptText.mentionsError(out) {
                return "I couldn't send the email, sir — check Mail automation permission."
            }
            log("SENT email")
            return "Email sent to \(shown), sir."
        }
    }
}
