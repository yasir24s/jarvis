import Foundation
import JarvisCore
import JarvisVoice

/// The app's voice (M8, D-54): the F5 clone through the jarvis-voice helper in
/// `Contents/Helpers/`, macOS `say` as the fallback, and the one player, all behind SpeechQueue.
/// Nothing starts until a reply is spoken: the helper is launched by its first request and exits
/// after 5 idle minutes. Its stderr goes to `jarvis-voice/helper.log` in the temporary folder.
@MainActor
final class AppVoice {
    let f5: F5Engine
    let queue: SpeechQueue

    init() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jarvis-voice", directoryHint: .isDirectory)
        let f5 = F5Engine(launcher: VoiceHelperSetup.inApp(log: folder.appending(path: "helper.log")))
        self.f5 = f5
        queue = SpeechQueue(engine: f5, fallback: SayEngine(), player: EnginePlayer(),
                            helperFootprintMB: { f5.lastFootprintMB },
                            log: { JarvisLog.log($0, category: .voice) })
    }

    /// `SpeakContext.ttsBackend`: "f5", or "say" while F5 is unavailable (not installed, or
    /// resting after two failures in a row). Both are local voices.
    var backend: String {
        f5.isAvailable ? EngineID.f5.rawValue : EngineID.say.rawValue
    }

    /// Speaks a finished reply; a new reply cancels whatever is queued or playing.
    func speak(_ text: String, turn: UUID) {
        let queue = self.queue
        Task { await queue.say(text, turn: turn) }
    }

    /// The menus' Stop Speaking.
    func stop() {
        let queue = self.queue
        Task { await queue.cancelAll() }
    }

    /// Quit: speech stops, then the helper's stdin is closed and it has up to 2 s to exit.
    func shutdown() async {
        await queue.cancelAll()
        await f5.release()
    }
}
