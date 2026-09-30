import Foundation
import NaturalLanguage
import Synchronization

/// Sentence vectors for recall and for merging duplicate facts (D-51 P2).
public protocol SentenceEmbedding: Sendable {
    /// The vector for `sentence`, or nil when no embedding is available.
    func vector(for sentence: String) -> [Double]?
}

/// `NLEmbedding.sentenceEmbedding(for: .english)`, loaded on first use (nil when the asset is
/// not on the Mac, and then every call is nil). NLEmbedding is not documented as thread-safe,
/// so calls are serialised.
public final class SystemSentenceEmbedding: SentenceEmbedding {
    private struct State {
        var loaded = false
        var embedding: NLEmbedding?
    }

    private let state = Mutex(State())

    public init() {}

    public func vector(for sentence: String) -> [Double]? {
        state.withLock { s in
            if !s.loaded {
                s.embedding = NLEmbedding.sentenceEmbedding(for: .english)
                s.loaded = true
            }
            return s.embedding?.vector(for: sentence)
        }
    }
}

/// Each fact's vector, computed once and cached by its text; queries are embedded afresh.
public final class FactVectors: Sendable {
    private let embedding: (any SentenceEmbedding)?
    private let cache = Mutex<[String: [Double]]>([:])

    /// - Parameter embedding: nil means no embedding (keyword overlap and exact duplicates only).
    public init(embedding: (any SentenceEmbedding)?) {
        self.embedding = embedding
    }

    /// The fact's cached vector, computed on first use. nil when the embedding is unavailable.
    public func vector(forFact text: String) -> [Double]? {
        if let hit = cache.withLock({ $0[text] }) { return hit }
        guard let v = embedding?.vector(for: text) else { return nil }
        cache.withLock { $0[text] = v }
        return v
    }

    /// A query's vector, not cached.
    public func vector(for text: String) -> [Double]? {
        embedding?.vector(for: text)
    }

    /// Forgets the vectors of facts no longer in `texts`.
    public func retain(_ texts: Set<String>) {
        cache.withLock { c in c = c.filter { texts.contains($0.key) } }
    }

    public var cachedCount: Int { cache.withLock { $0.count } }

    /// Whether fact `a` and candidate `b` are the same fact by embedding: cosine at or above
    /// `threshold`. False when either vector is unavailable.
    public func similar(_ a: String, _ b: String, threshold: Double = FactCompiler.duplicateSimilarity) -> Bool {
        guard let va = vector(forFact: a), let vb = vector(for: b), let c = Self.cosine(va, vb) else { return false }
        return c >= threshold
    }

    /// Cosine similarity; nil for vectors of different or zero length, or a zero vector.
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
