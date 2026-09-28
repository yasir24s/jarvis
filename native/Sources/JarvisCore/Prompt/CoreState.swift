import Foundation

// The single owner of JARVIS's module state (plan: M01 §3.8; integration decision D-35).
// Holds what jarvis.py keeps in module globals (_corr_cache, _history, LAST_TONE, _LAST_CMD)
// and replays process_command's head in Python's exact order; proven against the REAL
// process_command by the `m1_prompt` golden suite. Every subsystem's logic is the Persona
// layer's: this type only sequences the calls and owns the state between them.
//
// Not here yet: the two persona LLM phases (consolidatePersonalityIfDue,
// distillPersonalityIfDue) and their `_last_distill` field belong to M01 T12.

/// The snapshot values that live in CoreState rather than in a file: `len(_history)` and
/// `len(_corrections_load())` (the cache, loaded on first use). The file-backed values come
/// from the dataset section's `FileSnapshotSources`.
public struct CoreSnapshotInputs: Sendable, Equatable {
    public let historyTurns: Int
    public let correctionsCount: Int
}

public actor CoreState {
    public struct TurnPrompt: Sendable, Equatable {
        /// `sys_prompt`: what the local model gets as `messages[0]`.
        public let system: String
        /// `sys_prompt + _claude_history_preamble()`: what Claude gets.
        public let claudeSystem: String
    }

    private let store: StateStore
    private let clock: any JarvisClock
    private let research: any ResearchCounting
    private let frontApp: any FrontAppProviding
    /// SYSTEM_PROMPT, evaluated once like Python's import-time f-string.
    private let basePrompt: String

    /// `_corr_cache`: nil until first use; replaced on every save, even a failed one.
    private var corrections: [JSONObject]?
    /// `_history`.
    public private(set) var history: HistoryLog
    /// `LAST_TONE`.
    private var lastTone = LastTone()
    /// `_LAST_CMD` (D-35: owned here; FeedbackLogic is the pure half).
    private var lastCmd = FeedbackLogic.LastCommand()

    /// Loads history.json once, as `_history = _history_load()` does at import.
    public init(store: StateStore, clock: any JarvisClock, research: any ResearchCounting,
                frontApp: any FrontAppProviding) {
        self.store = store
        self.clock = clock
        self.research = research
        self.frontApp = frontApp
        self.basePrompt = SystemPrompt.base(changelogPath: StateStore.join(store.root, "CHANGELOG.md"))
        self.history = HistoryLog.load(store.load(.history))
    }

    // MARK: - Corrections

    /// `_corrections_load()`.
    private func correctionsLoad() -> [JSONObject] {
        if let c = corrections { return c }
        let c = CorrectionsLogic.filter(store.load(.corrections))
        corrections = c
        return c
    }

    /// `_corrections_save(pairs)`: cap, cache, then write (a failed write keeps the cache).
    private func correctionsSave(_ pairs: [JSONObject]) {
        let kept = CorrectionsLogic.capped(pairs)
        corrections = kept
        store.save(.corrections, .array(kept.map { .object($0) }))
    }

    /// `_apply_corrections(text)`.
    public func applyCorrections(_ text: String) throws(StateShapeError) -> String {
        try CorrectionsLogic.apply(text, pairs: correctionsLoad())
    }

    /// `learn_correction(text)`.
    public func learnCorrection(_ text: String) -> String {
        let r = CorrectionsLogic.learn(text, pairs: correctionsLoad(), now: clock.now())
        if let save = r.save { correctionsSave(save) }
        return r.reply
    }

    /// `forget_correction(text)`.
    public func forgetCorrection(_ text: String) -> String {
        let r = CorrectionsLogic.forget(text, pairs: correctionsLoad())
        correctionsSave(r.save)
        return r.reply
    }

    /// `_whisper_prompt`'s inputs: the profile's `facts.name.value` (skipped when the load or
    /// a lookup fails, or it is falsy) and the `meant` of the last 12 cached corrections.
    public func whisperVocabularyInputs() -> (name: String?, meant: [String]) {
        var name: String?
        if let p = try? ProfileLogic.load(store.load(.profile)),
           let v = p["facts"]?.objectValue?["name"]?.objectValue?["value"], v.pyTruthy {
            name = v.stringValue
        }
        let meant = Py.tail(correctionsLoad(), 12).compactMap { p -> String? in
            guard let m = p["meant"], m.pyTruthy else { return nil }
            return m.stringValue
        }
        return (name, meant)
    }

    // MARK: - Personality

    /// `personality_note_tool(note)`.
    public func personalityNoteTool(_ note: String) throws(StateShapeError) -> String {
        try PersonalityLogic.noteTool(note, store: store, now: clock.now())
    }

    /// `personality_rewrite_tool(core)`.
    public func personalityRewriteTool(_ core: String) -> String {
        PersonalityLogic.rewriteTool(core, store: store)
    }

    /// `personality_forget()`.
    public func personalityFactoryReset() {
        PersonalityLogic.forget(store: store)
    }

    // MARK: - Emotions / tone

    /// `emotion_event(name, mag)`: saves, then bumps `emotion_<name>`.
    public func emotionEvent(_ name: String, magnitude: Double = 1.0) throws(StateShapeError) {
        try EmotionLogic.event(name, magnitude: magnitude, store: store, now: clock.now(), research: research)
    }

    /// `set_tone(desc)`.
    public func setTone(_ desc: String) throws(StateShapeError) {
        try lastTone.set(desc, store: store, now: clock.now(), research: research)
    }

    // MARK: - Knowledge / profile

    /// `kb_remember(topic, summary)`.
    public func kbRemember(topic: String, summary: String) throws(StateShapeError) {
        try KnowledgeLogic.remember(topic: topic, summary: summary, store: store, now: clock.now())
    }

    /// `kb_lookup(query)`.
    public func kbLookup(_ query: String) throws(StateShapeError) -> String? {
        try KnowledgeLogic.lookup(query, store: store)
    }

    /// `profile_forget(match)` (nil: forget everything).
    public func profileForget(_ match: String?) throws(StateShapeError) {
        try ProfileLogic.forget(matching: match, store: store)
    }

    // MARK: - Turn

    /// process_command's head (jarvis.py `process_command`, up to the backend call). The front
    /// app is read first: it is the only suspension point, so the rest is one actor step.
    public func beginTurn(_ text: String, online: Bool) async throws(StateShapeError) -> TurnPrompt {
        let front = await frontApp.frontmostAppName()
        try KnowledgeLogic.noteTopic(text, store: store)                        // kb_note_topic
        try ProfileLogic.maybeLearn(text, store: store, now: clock.now())        // maybe_learn_profile
        try PersonalityLogic.maybeLearn(text, store: store, now: clock.now())    // maybe_learn_personality
        try EmotionLogic.react(text, store: store, now: clock.now(), research: research)  // emotion_react
        research.bump("interactions", by: 1)
        try trackFeedback(text)
        history.appendUser(text)
        var system = basePrompt
        system += try PersonalityLogic.context(store: store)
        system += try EmotionLogic.context(store: store, now: clock.now())
        system += lastTone.context(now: clock.now())
        system += AppContextLogic.context(frontApp: front)
        system += try ProfileLogic.context(store: store)
        system += try KnowledgeLogic.context(store: store)
        if !online, let fact = try KnowledgeLogic.lookup(text, store: store), !fact.isEmpty {
            system += " (Previously learned: " + Py.prefix(fact, 300) + ")"
        }
        return TurnPrompt(system: system, claudeSystem: system + (try history.claudePreamble()))
    }

    /// `track_feedback(text)`: bump, then the emotion event, then `_LAST_CMD` (which Python
    /// leaves alone when the event raises).
    private func trackFeedback(_ text: String) throws(StateShapeError) {
        let outcome = FeedbackLogic.track(text, last: lastCmd, now: clock.now())
        if let counter = outcome.counter { research.bump(counter, by: 1) }
        if let event = outcome.emotionEvent {
            try EmotionLogic.event(event, store: store, now: clock.now(), research: research)
        }
        lastCmd = outcome.last
    }

    /// `_history.append({"role": "assistant", "content": reply})`.
    public func recordAssistant(_ reply: String) {
        history.appendAssistant(reply)
    }

    /// The brain-error branch: drop the trailing user turn, if it is one.
    public func popTrailingUserTurn() {
        history.popTrailingUser()
    }

    /// `_history_save()`: failures are swallowed, as in Python.
    public func saveHistory() {
        store.save(.history, history.serialized())
    }

    // MARK: - Dataset

    public func snapshotInputs() -> CoreSnapshotInputs {
        CoreSnapshotInputs(historyTurns: history.turns.count, correctionsCount: correctionsLoad().count)
    }
}
