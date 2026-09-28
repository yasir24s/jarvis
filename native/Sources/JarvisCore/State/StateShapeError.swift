import Foundation

// Shared by the M1 *Logic loaders (plan: M01 §3.7, §8 R8); first used by
// Persona/Personality.swift and Persona/Emotions.swift.

/// A parseable but wrong-shaped state file where Python raises mid-turn: a learned entry
/// without "note", NaN in emotions, a string "at" (M01 §3.7, §8 R8). Python's loaders do not
/// catch these, so the turn fails; native throws and M3/M12 decide the UX.
public struct StateShapeError: Error, Equatable, Sendable, CustomStringConvertible {
    public let file: StateFile
    public let detail: String

    public init(file: StateFile, detail: String) {
        self.file = file
        self.detail = detail
    }

    public var description: String { "\(file.rawValue): \(detail)" }
}

