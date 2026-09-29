import JarvisCore
import JarvisTools
import Synchronization
import Testing

@Suite("Gateway Unicode compatibility")
struct GatewayUnicodeTests {
    @Test
    func confirmationStripsPythonWhitespaceAndCountsCodePoints() async {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        // Python strips U+001C; each decomposed accent occupies two code points.
        let command = "\u{001C}rm " + String(repeating: "e\u{0301}", count: 60) + "\u{001F}"
        let args = JSONObject([.init(key: "command", value: .string(command))])
        let result = await gateway.call("run_command", args,
                                        turn: TurnContext(channel: .text), origin: .model(.local))
        let prefix = "rm " + String(repeating: "e\u{0301}", count: 48) + "e"
        #expect(result.record.outcome == .gated)
        #expect(Array(result.text.unicodeScalars) == Array(GuardStrings.gatePrompt("That will run: " + prefix).unicodeScalars))
    }

    @Test
    func blockedLogCountsCodePointsWithoutTrimming() async {
        let lines = Mutex<[String]>([])
        let gateway = ToolGateway(log: { text in lines.withLock { $0.append(text) } })
        let command = "  rm / " + String(repeating: "e\u{0301}", count: 70)
        let args = JSONObject([.init(key: "command", value: .string(command))])
        let result = await gateway.call("run_command", args,
                                        turn: TurnContext(channel: .text), origin: .model(.local))
        let expected = "BLOCKED command:   rm / " + String(repeating: "e\u{0301}", count: 56) + "e"
        #expect(result.record.outcome == .blockedGuard)
        #expect(lines.withLock { $0.map { Array($0.unicodeScalars) } } == [Array(expected.unicodeScalars)])
    }
}
