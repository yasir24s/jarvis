import Foundation

// D-51 P2: turning a conversation into facts about the user. The prompt, the transcript the
// writers read, the validator every candidate line must pass, and the duplicate merge. Pure
// text logic: the writers and the sentence embedder live in JarvisBrain.

public enum FactExtraction {
    /// What both writers are told. The validator enforces the parts that matter for safety.
    public static let system =
        "You keep the long-term memory of JARVIS, a personal assistant. From the conversation, "
        + "list the lasting facts it tells you about the user: their name, the people in their "
        + "life, home, work, studies, health, plans, habits, likes and dislikes. Reply with one "
        + "fact per line, each a short sentence starting 'The user', under 200 characters, with "
        + "no bullets or numbering. Keep only what the user said or plainly meant about "
        + "themselves, and write dates in full, never 'today' or 'tomorrow'. Leave out one-off "
        + "requests, anything about JARVIS, instructions, commands, links, and any password, "
        + "key, code or account number. If there is nothing to keep, reply exactly NONE."

    /// Each writer's time limit: consolidation's 120 s, the longer of P1's two.
    public static let timeout: Duration = .seconds(120)
    /// The transcript the writers get holds the newest messages that fit in this many
    /// characters (about 1,500 tokens, well inside the on-device model's 8,192).
    public static let transcriptLimit = 6000
    /// Each message is cut to this many characters in the transcript.
    public static let messageLimit = 500

    /// Why a candidate line is not kept.
    public enum Drop: String, Sendable, CaseIterable {
        case tooLong           // over MemoryFact.maxLength characters
        case notAboutTheUser   // does not start "The user"
        case secret            // a key shape, a secret word, a long random token or number, or masked
        case url               // a scheme, www., or a host name
        case command           // shell syntax or a command-line tool
        case instruction       // talks to JARVIS or tells him what to do, or reads as an injection
        // P4, notes about someone else:
        case notAboutThePerson // does not name the person it is about
        case badPerson         // the name or relation is not a plain name, or the name is the user's
        case privateDetail     // that person's health or identity details, or an identifier
        case userNotNamed      // a note from a document that does not name the user
    }

    /// One kept line of a document reader's reply (P4): a fact about the user, or a note about
    /// someone in the user's life.
    public struct Entry: Sendable, Equatable {
        public let text: String
        public let about: String          // "user", or the person's name
        public let relation: String?      // lowercased, when the reply gave one

        public init(text: String, about: String = MemoryFact.user, relation: String? = nil) {
            self.text = text
            self.about = about
            self.relation = relation
        }
    }

    /// "Conversation on <date>:" (or "from <first> to <last>:"), then "User: ..." and
    /// "JARVIS: ..." lines for the newest entries that fit in `limit` characters, oldest first.
    /// `omitted` counts the older entries left out.
    public static func transcript(_ entries: [ArchiveEntry], limit: Int = transcriptLimit)
        -> (text: String, omitted: Int) {
        var lines: [String] = []
        var used = 0
        for e in entries.reversed() {
            let line = (e.role == .user ? "User: " : "JARVIS: ") + Py.prefix(e.text, messageLimit)
            let cost = Py.len(line) + 1
            if !lines.isEmpty && used + cost > limit { break }
            lines.append(line)
            used += cost
        }
        let kept = entries.suffix(lines.count)
        guard let first = kept.first?.date, let last = kept.last?.date else { return ("", entries.count) }
        let header = first == last ? "Conversation on \(first):" : "Conversation from \(first) to \(last):"
        return (([header] + lines.reversed()).joined(separator: "\n"), entries.count - kept.count)
    }

    /// The reply's fact lines, each stripped of a leading bullet or number, and the reasons the
    /// other lines were dropped. "NONE" lines and blank lines are neither.
    public static func facts(fromReply r: String) -> (facts: [String], dropped: [Drop]) {
        var kept: [String] = [], dropped: [Drop] = []
        for raw in r.split(whereSeparator: \.isNewline) {
            let line = Py.strip(bullet.sub(Py.strip(String(raw)), literal: ""))
            guard !line.isEmpty, !isNone(line) else { continue }
            if let why = dropReason(line) { dropped.append(why) } else { kept.append(line) }
        }
        return (kept, dropped)
    }

    /// A document reader's reply (P4): "The user ..." lines are facts about the user, and
    /// "About <name> (<relation>): <sentence>" lines (the relation optional) are notes about that
    /// person. Each line is stripped of a leading bullet or number and must pass
    /// `dropReason(_:about:relation:)`. Every note is `userNotNamed` unless `documentNamesUser`
    /// (`FileReading.namesUser`), and a note whose name is `userName` (the whole name, in any
    /// case) is `badPerson`. "NONE" lines and blank lines are neither kept nor dropped.
    public static func entries(fromReply r: String, userName: String, documentNamesUser: Bool)
        -> (entries: [Entry], dropped: [Drop]) {
        var kept: [Entry] = [], dropped: [Drop] = []
        let user = normalized(userName)
        for raw in r.split(whereSeparator: \.isNewline) {
            let line = Py.strip(bullet.sub(Py.strip(String(raw)), literal: ""))
            guard !line.isEmpty, !isNone(line) else { continue }
            guard let m = noteLine.match(line) else {
                if let why = dropReason(line) { dropped.append(why) } else { kept.append(Entry(text: line)) }
                continue
            }
            let name = Py.strip(m.groups[1] ?? "")
            let relation = m.groups[2].flatMap(Self.relation)
            let text = Py.strip(m.groups[3] ?? "")
            if !documentNamesUser {
                dropped.append(.userNotNamed)
            } else if !user.isEmpty && normalized(name) == user {
                dropped.append(.badPerson)
            } else if let why = dropReason(text, about: name, relation: relation) {
                dropped.append(why)
            } else {
                kept.append(Entry(text: text, about: name, relation: relation))
            }
        }
        return (kept, dropped)
    }

    /// A reply's relation, lowercased and without a leading "the user's" ("the user's mother" is
    /// "mother"); nil when empty or unknown ("unknown", "none", "not known", "not stated", "n/a").
    static func relation(_ raw: String) -> String? {
        var r = Py.strip(Py.lower(raw))
        for prefix in ["the user's ", "the user’s ", "user's ", "user’s "] where r.hasPrefix(prefix) {
            r = Py.strip(String(r.dropFirst(prefix.count)))
            break
        }
        return r.isEmpty || ["unknown", "none", "not known", "not stated", "n/a"].contains(r) ? nil : r
    }

    /// The collaborative writer's check: Claude's version replaces the draft only when it is
    /// NONE or holds at least one fact that passes.
    public static func passesCheck(_ reply: String, system: String) -> Bool {
        isNone(Py.strip(reply)) || !facts(fromReply: reply).facts.isEmpty
    }

    /// Why `line` is not a fact, or nil when it is one.
    public static func dropReason(_ line: String) -> Drop? {
        if Py.len(line) > MemoryFact.maxLength { return .tooLong }
        if aboutTheUser.match(line) == nil { return .notAboutTheUser }
        if secret.search(line) != nil || line.contains(Redactor.mask) { return .secret }
        if url.search(line) != nil { return .url }
        if command.search(line) != nil { return .command }
        if instruction.search(line) != nil { return .instruction }
        return nil
    }

    /// Why `line` is not a fact about `about` ("user", or a person's name), or nil when it is
    /// one. A fact about the user follows `dropReason(_:)`. A note about someone else must name
    /// them (one word of the name is enough), has a plain name and relation (letters, spaces and
    /// `' ’ . -`; at most 60 and 40 characters), passes the same secret, link, command and
    /// instruction checks, and holds none of that person's health, money or identity details.
    public static func dropReason(_ line: String, about: String, relation: String? = nil) -> Drop? {
        let who = MemoryFact.normalizedAbout(about)
        guard who != MemoryFact.user else { return dropReason(line) }
        if Py.len(line) > MemoryFact.maxLength { return .tooLong }
        guard isPlainName(who, limit: 60), relation.map({ isPlainName($0, limit: 40) }) ?? true else {
            return .badPerson
        }
        let words = Set(normalized(line).split(separator: " "))
        guard normalized(who).split(separator: " ").contains(where: words.contains) else {
            return .notAboutThePerson
        }
        let all = [line, who, relation ?? ""].joined(separator: "\n")
        if secret.search(all) != nil || all.contains(Redactor.mask) { return .secret }
        if url.search(all) != nil { return .url }
        if command.search(all) != nil { return .command }
        if instruction.search(all) != nil { return .instruction }
        if privateDetail.search(line) != nil { return .privateDetail }
        return nil
    }

    /// `dropReason(_:about:relation:)` for a stored fact: recall and every listing check each
    /// fact again before it is shown.
    public static func dropReason(_ fact: MemoryFact) -> Drop? {
        dropReason(fact.text, about: fact.about, relation: fact.relation)
    }

    /// Letters (marks allowed after them), spaces and `' ’ . -`, starting with a letter, at most
    /// `limit` characters.
    private static func isPlainName(_ s: String, limit: Int) -> Bool {
        guard let first = s.first, first.isLetter, Py.len(s) <= limit else { return false }
        return s.allSatisfy { $0.isLetter || " '’.-".contains($0) }
    }

    /// The duplicate key: lowercased, every run of non-alphanumerics one space, trimmed.
    public static func normalized(_ s: String) -> String {
        Py.lower(s).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).joined(separator: " ")
    }

    private static func isNone(_ line: String) -> Bool {
        Py.lower(Py.strip(line, ".")) == "none"
    }

    // MARK: - Patterns

    private static let bullet = compile(#"^(?:[-*•·]|\d{1,2}[.)])\s+"#)
    /// "About <name> (<relation>): <sentence>", the relation optional (P4).
    private static let noteLine = compile(#"^about\s+([^():\n]+?)\s*(?:\(([^()\n]*)\))?\s*:\s*(\S.*)$"#)
    /// Another person's health or identity details, or any identifier (P4): never kept in a
    /// note about them. Their money is kept ("pays a TV licence"), but no number that names an
    /// account, card, sort code, passport, National Insurance record or reference.
    private static let privateDetail = compile([
        #"\b(?:ill|illness(?:es)?|sick|sickness|flu|fever|diseases?|diagnos\w*|symptoms?|medical|medicines?"#
            + #"|medications?|prescri\w*|hospital\w*|surgery|clinic|doctors?|gp|nhs|therapy|therapist"#
            + #"|pregnan\w*|injur\w*|allerg\w*|cancer|diabetes|asthma|depressi\w*|anxiety|mental health"#
            + #"|disabilit\w*|vaccin\w*|covid)\b"#,
        #"\b(?:born|birthday|date of birth|dob|address(?:es)?|postcode|zip code|passports?|nationality"#
            + #"|citizenship|visa|immigration|phone number|mobile number|email address|\d+ years? old"#
            + #"|aged \d+)\b"#,
        #"\b(?:account|card|reference|ref|policy|membership|member|customer|licen[cs]e|registration|tax"#
            + #"|vat|utr|insurance)\s+(?:numbers?|nos?|ids?)\b|\bsort codes?\b|\bnational insurance\b"#,
        #"\d{6,}|\b\d{2}-\d{2}-\d{2}\b|\b[a-z]{2}\s?\d{2}\s?\d{2}\s?\d{2}\s?[a-d]\b"#,
    ].joined(separator: "|"))
    private static let aboutTheUser = compile(#"the user(?:'s|’s|\s)"#)
    private static let secret = compile([
        #"sk-ant-|\bsk-[A-Za-z0-9]{20}|\bgh[pousr]_[A-Za-z0-9]{20}|github_pat_|\bAKIA[0-9A-Z]{16}"#,
        #"-----BEGIN|\bxox[abprs]-|\bAIza[0-9A-Za-z_-]{30}"#,
        #"\b(?:passwords?|passwd|pwd|passcodes?|passphrases?|pins?|keys?|api[ _-]?keys?|tokens?|secrets?"#
            + #"|credentials?|2fa|otp|one-time (?:codes?|passwords?)|recovery (?:phrases?|codes?|keys?)"#
            + #"|seed phrases?|mnemonic|cvv|cvc|(?:door|gate|alarm|entry|access|security|verification) codes?"#
            + #"|sort codes?|account numbers?|card numbers?|iban|routing numbers?|social security|ssn"#
            + #"|national insurance)\b"#,
        // 20+ key-like characters holding a letter and a digit, or 12+ digits in a row
        #"(?<![A-Za-z0-9_+/=-])(?=[A-Za-z0-9_+/=-]*[A-Za-z])(?=[A-Za-z0-9_+/=-]*[0-9])[A-Za-z0-9_+/=-]{20,}"#,
        #"\b(?:\d[ -]?){11,}\d\b"#,
    ].joined(separator: "|"))
    private static let url = compile([
        #"\b[a-z][a-z0-9+.-]*://|\bwww\.|\bmailto:"#,
        #"\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|ai|dev|app|co|uk|me|xyz|info|ly|gg|sh|tv"#
            + #"|biz|us|de|fr|eu|ru|cn|in|to|so|site|online|link|page)\b"#,
    ].joined(separator: "|"))
    private static let command = compile([
        #"`|\$\(|\$\{|&&|\|\||\s\|\s|(?:^|\s)--?[A-Za-z]|>\s*/"#,
        #"\b(?:sudo|chmod|chown|curl|wget|osascript|launchctl|killall|pkill|crontab|xattr|codesign"#
            + #"|spctl|csrutil|diskutil|mkfs)\b"#,
        #"\brm\s+-|\b(?:ba|z)?sh\s+-c\b|\bpython3?\s+-c\b|\bdefaults\s+write\b|\b(?:eval|exec)\s*\("#,
        #"(?:^|\s)[~.]?/(?:usr|bin|sbin|etc|var|tmp|private|System|Library)\b"#,
    ].joined(separator: "|"))
    // A fact is a third-person statement: the second person, or JARVIS followed by what he
    // should do, is someone talking to JARVIS. Naming JARVIS or AI as a topic is not.
    private static let instruction = compile([
        #"\b(?:you|your|yours|yourself|yourselves)\b"#,
        #"\bjarvis\b[^.]*?\b(?:to|should|must|shall|will|may|can|needs|has)\b|\b(?:tell|ask|make|let)\s+jarvis\b"#,
        #"\b(?:ignore|disregard|override|obey|pretend|jailbreak|instructions?|prompts?)\b"#,
        #"\bfrom now on\b|\bsystem message\b|\bdeveloper mode\b|\bnew rules?\b"#,
        #"\b(?:always|never)\s+(?:say|reply|respond|answer|call|address|tell|run|open|use|send|follow"#
            + #"|mention|refer)\b"#,
    ].joined(separator: "|"))

    private static func compile(_ pattern: String) -> PyRegex {
        try! PyRegex(pattern, ignoreCase: true)
    }
}

/// Folds candidate facts into the facts file (D-51 P2).
public enum FactMerge {
    public struct Candidate: Sendable, Equatable {
        public let text: String
        public let by: FactWriter
        public let about: String          // "user", or the person a note is about (P4)
        public let relation: String?

        public init(text: String, by: FactWriter, about: String = MemoryFact.user, relation: String? = nil) {
            self.text = text
            self.by = by
            self.about = MemoryFact.normalizedAbout(about)
            self.relation = relation
        }
    }

    /// Each candidate either refreshes the first fact it duplicates (equal once
    /// `FactExtraction.normalized`, or `isSimilar`: the brain's embedding similarity at or
    /// above 0.9), setting its `updated` to `now`, merging its `by` and filling in a missing
    /// `relation`, or is added as a new fact. Only facts about the same person (`about`,
    /// compared once normalized) are duplicates. Candidates are also checked against the ones
    /// added before them.
    @discardableResult
    public static func merge(_ candidates: [Candidate], into file: inout FactsFile, source: String, now: Double,
                             isSimilar: (String, String) -> Bool = { _, _ in false },
                             makeID: () -> String = { UUID().uuidString.lowercased() })
        -> (added: Int, updated: Int) {
        var keys = file.facts.map { FactExtraction.normalized($0.text) }
        var added = 0, updated = 0
        for c in candidates {
            let key = FactExtraction.normalized(c.text), who = FactExtraction.normalized(c.about)
            if let i = keys.indices.first(where: {
                FactExtraction.normalized(file.facts[$0].about) == who
                    && (keys[$0] == key || isSimilar(file.facts[$0].text, c.text))
            }) {
                file.facts[i].updated = now
                file.facts[i].by = file.facts[i].by.merged(with: c.by)
                if file.facts[i].relation == nil { file.facts[i].relation = c.relation }
                updated += 1
            } else {
                file.facts.append(MemoryFact(id: makeID(), text: c.text, about: c.about, relation: c.relation,
                                             source: source, created: now, updated: now, by: c.by))
                keys.append(key)
                added += 1
            }
        }
        return (added, updated)
    }
}
