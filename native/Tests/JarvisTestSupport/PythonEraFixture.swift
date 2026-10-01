import Foundation

/// P6 part 4's synthetic Python-era state: a jarvis.log with two Python sessions and one native
/// session, paired lines and junk lines, and small history, knowledge and corrections files.
/// Every person, place and fact in it is invented.
public enum PythonEraFixture {
    public static let log = """
        [JARVIS] a line before any banner
        [Heard]   I keep invented bees on the roof
        [JARVIS]  This pair is before any session and is never read.

        ===== JARVIS starting 2026-06-10 09:15:00 =====
        [JARVIS] Loading the wake word model…
        [Heard]   Jarvis, I've started learning the cello this summer
        [Command] I've started learning the cello this summer
        [JARVIS]  Splendid, sir. Shall I warn the neighbours?
        [Heard]   Thanks
        [JARVIS]  You're welcome, sir.
        [Heard]   what's the weather like in Fernwick
        [Command] what's the weather like in Fernwick
        [JARVIS]  Mild and grey, sir.
        [Heard]   (upbeat music)
        [JARVIS]  I beg your pardon, sir?
        [Heard]   ...???
        [JARVIS]  Sir?
        [Heard]   my cousin Wren Halloway is visiting next week
        [JARVIS] (ignored — not your voice)
        [Heard]   I work night shifts at the Fernwick Infirmary
        [Command] I work night shifts at the Fernwick Infirmary
        [JARVIS]  Noted, sir. Coffee on standby.  (acting)

        ===== JARVIS (native) starting 2026-09-30 10:00:00 =====
        [Heard]   I moved to an invented town called Ashgrove
        [JARVIS]  This native pair must never be imported.

        ===== JARVIS starting 2026-06-12 20:00:00 =====
        [Heard]   I prefer my tea without sugar these days
        [JARVIS]  As you wish, sir.
        [Heard]   \("   ")
        [JARVIS]  Yes, sir?
        [Heard]   \u{FFFD}garbled\u{FFFD} words here
        [JARVIS]  Pardon?
        [Heard]   that's all, Jarvis

        """

    /// history.json: one kept exchange, and a one-word turn left out with its reply.
    public static let history = #"[{"role": "user", "content": "I'm training for an invented marathon in October"}, {"role": "assistant", "content": "Then I shall pace myself, sir."}, {"role": "user", "content": "ok"}, {"role": "assistant", "content": "Very good, sir."}]"#

    /// knowledge.json: its queue holds what the user last asked about; one item is one word.
    public static let knowledge = #"{"topics": {}, "queue": ["what time does the fernwick bakery open on sundays", "hello"]}"#

    /// corrections.json: one correction, added 2026-06-11 12:00 UTC.
    public static let corrections = #"[{"heard": "fern wick", "meant": "Fernwick", "added": 1781179200.0}]"#

    /// The files' modification times, so their batches have fixed days (2026-08-01 and
    /// 2026-08-02, noon UTC).
    public static let historyModified = Date(timeIntervalSince1970: 1_785_585_600)
    public static let knowledgeModified = Date(timeIntervalSince1970: 1_785_672_000)
}
