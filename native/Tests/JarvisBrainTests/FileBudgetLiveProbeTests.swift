import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import Testing

/// D-51 P3's live measurement of the on-device budget for file reading. Skipped unless
/// JARVIS_LIVE_LOCAL=1. It counts tokens with the real tokenizer for the reading instructions
/// and for synthetic prose (never a user file), and prints how much text fits.
@Suite("P3 file budget: live probe (JARVIS_LIVE_LOCAL=1)")
struct FileBudgetLiveProbeTests {
    @Test("the reading budget against the real model's context", .enabled(if: LocalLiveProbeTests.enabled),
          .timeLimit(.minutes(5)))
    func probe() async throws {
        let model = SystemLanguageModel.default
        let counter = SystemFileTokenCounter(model: model)
        let context = counter.contextSize
        let limit = Int(Double(context) * LocalFileBudget.share)
        print("PROBE os \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("PROBE availability \(model.availability)")
        print("PROBE contextSize \(context), limit \(limit) (share \(LocalFileBudget.share))")
        let system = FileReading.system(userName: "Jordan Sample")
        let instructions = try await counter.tokenCount(instructions: system)
        print("PROBE instructions \(system.count) chars, \(instructions.map(String.init) ?? "no tokenizer") tokens")
        let sentences = [
            "The user moved to Leeds in March and walks to the office most days.",
            "Their sister Amira is getting married next spring, and they are planning the trip.",
            "Notes from the allotment: tomatoes in bed three, beans along the fence, onions by the shed.",
            "Revision plan for the dissertation: chapter two by Friday, then the survey results.",
        ]
        for target in [2_000, 6_000, 8_000, 10_000] {
            var text = ""
            var i = 0
            while text.count < target { text += sentences[i % sentences.count] + " "; i += 1 }
            text = String(text.prefix(target))
            let prompt = FileReading.prompt(text, kind: .markdown)
            let tokens = try await counter.tokenCount(prompt: prompt)
            let budget = await LocalFileBudget(counter: counter).measure(text: text, prompt: prompt,
                                                                         instructions: system)
            let perToken = tokens.map { String(format: "%.2f", Double(prompt.count) / Double($0)) } ?? "-"
            print("PROBE text \(target) chars: prompt \(prompt.count) chars, \(tokens.map(String.init) ?? "-") tokens "
                  + "(\(perToken) chars/token), with instructions \((tokens ?? 0) + (instructions ?? 0)) of \(limit), "
                  + "fits \(budget.fits)")
        }
    }
}
