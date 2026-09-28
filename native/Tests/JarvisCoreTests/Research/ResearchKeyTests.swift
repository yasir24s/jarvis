import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// Native-specified (schema 2, plan: M01b §2.3 "New counters", §3.2): these names have no
// Python oracle because the user declined the Python patch, so they are pinned here.

@Suite("ResearchKey schema-2 names (native-specified)")
struct ResearchKeySchema2Tests {
    @Test func staticNames() {
        #expect(ResearchKey.interactionsText == "interactions_text")
        #expect(ResearchKey.aliveHours == "alive_hours")
        #expect(ResearchKey.fastPathHandled == "fast_path_handled")
        #expect(ResearchKey.ttsElevenLabs == "tts_elevenlabs")
        #expect(ResearchKey.ttsPiper == "tts_piper")
        #expect(ResearchKey.ttsCharsElevenLabs == "tts_chars_elevenlabs")
    }

    @Test func schema1StaticNamesMatchTheCatalogue() {
        // §2.3: names byte-identical to jarvis.py's research_bump("…") literals.
        #expect([ResearchKey.interactions, ResearchKey.sttSegmentsDropped,
                 ResearchKey.personalityConsolidations, ResearchKey.userCorrection,
                 ResearchKey.rephraseSuspected, ResearchKey.speakerReject, ResearchKey.speakerPass,
                 ResearchKey.wakeRejectedForeignVoice]
                == ["interactions", "stt_segments_dropped", "personality_consolidations",
                    "user_correction", "rephrase_suspected", "speaker_reject", "speaker_pass",
                    "wake_rejected_foreign_voice"])
    }

    @Test func startsAndFallbacks() {
        #expect(ResearchKey.starts(build: .dev) == "starts_swift_dev")
        #expect(ResearchKey.starts(build: .release) == "starts_swift_release")
        #expect(TTSFallbackReason.allCases.map(ResearchKey.ttsFallback)
                == ["tts_fallback_offline", "tts_fallback_quota", "tts_fallback_timeout",
                    "tts_fallback_error", "tts_fallback_sensitive"])
    }

    @Test func toolNames() {
        let known: Set<String> = ["web_search", "run_command", "caf\u{E9}"]
        #expect(ResearchKey.tool("web_search", known: known) == "tool_web_search")
        #expect(ResearchKey.tool("rm_rf", known: known) == "tool_unknown")
        #expect(ResearchKey.tool("", known: known) == "tool_unknown")
        // Python `in` compares code points: a decomposed "café" is not the registered one.
        #expect(ResearchKey.tool("cafe\u{301}", known: known) == "tool_unknown")
        #expect(ResearchKey.tool("caf\u{E9}", known: known) == "tool_caf\u{E9}")
    }

    @Test func pathsAreStatePathsViews() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let p = sb.paths
        #expect(p.dir == sb.box.paths.researchDir)
        #expect(p.usage == sb.box.paths.researchUsage)
        #expect(p.metrics == sb.box.paths.researchMetrics)
        #expect(p.jarvisPy == sb.box.paths.jarvisPy)
        #expect(p.voiceprint == sb.box.paths.voiceprint)
        #expect(p.usageQuarantine(unix: 1786527000).lastPathComponent == "usage.json.corrupt-1786527000")
        #expect(p.usageQuarantine(unix: 1).deletingLastPathComponent().standardizedFileURL
                == p.dir.standardizedFileURL)
        #expect(ResearchPaths(here: sb.box.root) == p)
    }
}
