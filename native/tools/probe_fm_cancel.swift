// V11 part 1: does cancelling a Foundation Models call free the model? Starts a long generation,
// cancels it after about a second, and records how long the call took to return and whether it
// threw. Then times a short follow-up call, against a short call on an idle model, to see whether
// the abandoned generation kept the model busy. No audio.
//
//     swift native/tools/probe_fm_cancel.swift [output-file]
//
// Run it under ~/jarvis-wt/.orchestrator/with-build-lock.sh: it compiles, and it loads the model.
import Foundation
import FoundationModels

let longPrompt = """
    Write a very long, detailed history of the city of London, from the Roman founding of \
    Londinium to the present day. Cover every century in its own paragraph, with names, dates \
    and events. Do not summarise; aim for at least two thousand words.
    """
let shortPrompt = "Reply with the single word: ready."
let options = GenerationOptions(samplingMode: .greedy)
let cancelAfter: Duration = .seconds(1)

var lines: [String] = []
func note(_ s: String) {
    print(s)
    lines.append(s)
}
func secs(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.2f", Double(c.seconds) + Double(c.attoseconds) / 1e18)
}
let clock = ContinuousClock()

func timedShort(_ label: String) async {
    let session = LanguageModelSession(instructions: "You are terse.")
    let start = clock.now
    do {
        let r = try await session.respond(to: shortPrompt, options: options)
        note("\(label): short respond took \(secs(clock.now - start)) s (\(r.content.count) chars)")
    } catch {
        note("\(label): short respond threw after \(secs(clock.now - start)) s: \(error)")
    }
}

/// Runs `body` in a Task, cancels it after `cancelAfter`, and reports when it came back.
func probe(_ label: String, _ body: @escaping @Sendable () async throws -> Int) async {
    let start = clock.now
    let task = Task { try await body() }
    try? await Task.sleep(for: cancelAfter)
    let cancelledAt = clock.now
    task.cancel()
    do {
        let chars = try await task.value
        note("\(label): returned normally \(secs(clock.now - cancelledAt)) s after cancel "
             + "(total \(secs(clock.now - start)) s, \(chars) chars)")
    } catch {
        note("\(label): threw \(type(of: error)) \(secs(clock.now - cancelledAt)) s after cancel "
             + "(total \(secs(clock.now - start)) s): \(error)")
    }
}

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSHomeDirectory() + "/jarvis-wt/.orchestrator/v11-probe.txt"

note("V11 probe \(Date()) model available: \(SystemLanguageModel.default.isAvailable)")
note("cancel after \(secs(cancelAfter)) s")

// Warm the model so the first timing is not a cold load.
await timedShort("warm-up")
await timedShort("baseline (idle model)")

// Uncancelled long generation, for scale: how long the whole thing takes.
do {
    let session = LanguageModelSession(instructions: "You are a historian.")
    let start = clock.now
    var chars = 0
    for try await snap in session.streamResponse(to: longPrompt, options: options) { chars = snap.content.count }
    note("reference: uncancelled long stream took \(secs(clock.now - start)) s (\(chars) chars)")
} catch {
    note("reference: long stream threw: \(error)")
}
await timedShort("after reference")

// 1. respond(), task cancelled.
await probe("respond + cancel") {
    let session = LanguageModelSession(instructions: "You are a historian.")
    let r = try await session.respond(to: longPrompt, options: options)
    return r.content.count
}
await timedShort("right after respond + cancel")

// 2. streamResponse(), breaking out on Task.isCancelled per element.
await probe("stream + break on isCancelled") {
    let session = LanguageModelSession(instructions: "You are a historian.")
    var chars = 0
    for try await snap in session.streamResponse(to: longPrompt, options: options) {
        chars = snap.content.count
        if Task.isCancelled { break }
    }
    return chars
}
await timedShort("right after stream + break")

// 3. streamResponse(), no explicit check: does the stream itself end on cancel?
await probe("stream, no check") {
    let session = LanguageModelSession(instructions: "You are a historian.")
    var chars = 0
    for try await snap in session.streamResponse(to: longPrompt, options: options) { chars = snap.content.count }
    return chars
}
await timedShort("right after stream, no check")

try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
print("wrote \(out)")
