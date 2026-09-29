import Foundation
import Testing
@testable import vo

@Suite("Summarizer logic")
struct SummarizerTests {
    @Test func parseTranscriptLinesExtractsChannelTimestampAndText() {
        let lines = [
            """
            {"seq":0,"channel":"mic","timestamp":"2026-06-10T08:34:56.234+09:00","src":{"lang":"en-US","text":"Hello, team."}}
            """,
            """
            {"seq":1,"channel":"speaker","timestamp":"2026-06-10T08:34:58.500+09:00","src":{"lang":"en-US","text":"Hi! How are you?"},"dst":{"lang":"ja-JP","text":"こんにちは！元気ですか？"}}
            """,
            """
            {"invalid": json}
            """,
            ""
        ]

        let parsed = Summarizer.parseTranscriptLines(fromJSONLLines: lines)
        #expect(parsed.count == 2)

        #expect(parsed[0].channel == "mic")
        #expect(parsed[0].timestamp == "08:34:56")
        #expect(parsed[0].text == "Hello, team.")

        #expect(parsed[1].channel == "speaker")
        #expect(parsed[1].timestamp == "08:34:58")
        #expect(parsed[1].text == "Hi! How are you? (こんにちは！元気ですか？)")
    }

    @Test func parseTranscriptLinesIgnoresEmptySrc() {
        let lines = [
            """
            {"seq":0,"channel":"mic","timestamp":"2026-06-10T08:34:56.234+09:00","src":{"lang":"en-US","text":""}}
            """,
            """
            {"seq":1,"channel":"mic","timestamp":"2026-06-10T08:34:57.000+09:00","src":{"lang":"en-US","text":"   "}}
            """
        ]

        let parsed = Summarizer.parseTranscriptLines(fromJSONLLines: lines)
        #expect(parsed.isEmpty)
    }

    @Test func formatTranscriptCombinesLinesCleanly() {
        let items = [
            Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "First topic."),
            Summarizer.TranscriptLine(timestamp: "10:00:05", channel: "speaker", text: "Agreed.")
        ]

        let formatted = Summarizer.formatTranscript(items)
        #expect(formatted.contains("[10:00:00] [mic] First topic."))
        #expect(formatted.contains("[10:00:05] [speaker] Agreed."))
    }

    @Test func formatTranscriptHandlesMissingTimestampsOrChannels() {
        let items = [
            Summarizer.TranscriptLine(timestamp: "", channel: "mic", text: "No timestamp."),
            Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "", text: "No channel."),
            Summarizer.TranscriptLine(timestamp: "", channel: "", text: "Neither.")
        ]

        let formatted = Summarizer.formatTranscript(items)
        #expect(formatted.contains("[mic] No timestamp."))
        #expect(formatted.contains("[10:00:00] No channel."))
        #expect(formatted.contains("- Neither."))
    }
}
