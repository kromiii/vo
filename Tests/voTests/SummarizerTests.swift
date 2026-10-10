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

    @Test func chunkPromptIncludesRangeAndLanguageInstruction() {
        let prompt = SummaryPrompts.chunkPrompt(
            index: 0,
            startTimestamp: "10:00:00",
            endTimestamp: "10:05:00",
            chunkText: "[mic] Discussion topic"
        )
        #expect(prompt.contains("The following is part 1 (utterances 10:00:00 to 10:05:00)"))
        #expect(prompt.contains("IMPORTANT: Respond in the primary language used in the transcript."))
        #expect(prompt.contains("[mic] Discussion topic"))
    }

    @Test func chunkPromptHandlesEmptyTimestamps() {
        let prompt = SummaryPrompts.chunkPrompt(
            index: 1,
            startTimestamp: nil,
            endTimestamp: nil,
            chunkText: "Sample text"
        )
        #expect(prompt.contains("The following is part 2 of a meeting transcript."))
        #expect(!prompt.contains("utterances"))
    }

    @Test func finalPromptInstructsSameLanguage() {
        let prompt = SummaryPrompts.finalPrompt(transcript: "Transcript content")
        #expect(prompt.contains("Analyze the meeting transcript below"))
        #expect(prompt.contains("IMPORTANT: Write the entire response in the primary language used in the transcript"))
        #expect(prompt.contains("Transcript content"))
    }

    @Test func finalPromptHandlesIntermediateSummary() {
        let prompt = SummaryPrompts.finalPrompt(transcript: "Part summaries", isIntermediateSummary: true)
        #expect(prompt.contains("Analyze the intermediate summaries of each part of the meeting below"))
    }

    @Test func finalPromptAppliesCustomPrompt() {
        let prompt = SummaryPrompts.finalPrompt(
            transcript: "Transcript content",
            customPrompt: "Custom summarization rule"
        )
        #expect(prompt.contains("Custom summarization rule"))
        #expect(prompt.contains("Transcript content"))
        #expect(!prompt.contains("Analyze the meeting transcript"))
    }

    @Test func updatePromptIncludesExistingSummaryAndNewUtterances() {
        let prompt = SummaryPrompts.updatePrompt(
            existingSummary: "Existing Summary Content",
            newUtterances: "New Utterance Line"
        )
        #expect(prompt.contains("Existing Summary Content"))
        #expect(prompt.contains("New Utterance Line"))
        #expect(prompt.contains("IMPORTANT INSTRUCTIONS:"))
        #expect(prompt.contains("Synthesize the new discussion smoothly"))
    }

    @Test func updatePromptAppliesCustomPrompt() {
        let prompt = SummaryPrompts.updatePrompt(
            existingSummary: "Existing Summary Content",
            newUtterances: "New Utterance Line",
            customPrompt: "Custom Update Rule"
        )
        #expect(prompt.contains("Custom Update Rule"))
        #expect(prompt.contains("Existing Summary Content"))
        #expect(prompt.contains("New Utterance Line"))
        #expect(!prompt.contains("IMPORTANT INSTRUCTIONS:"))
    }

    @Test func summarizerTracksUtteranceCountAndAppends() async {
        let summarizer = Summarizer(summaryOut: nil, customPrompt: nil)
        #expect(await summarizer.utteranceCount == 0)

        await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "Hello"))
        await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:05", channel: "speaker", text: "World"))

        #expect(await summarizer.utteranceCount == 2)
    }

    @Test func chunkSummaryStoresMetadataCorrectly() {
        let chunk = Summarizer.ChunkSummary(
            index: 0,
            startTime: "10:00:00",
            endTime: "10:01:30",
            utteranceCount: 25,
            summaryText: "- Discussed feature launch\n- Assigned reviewer"
        )
        #expect(chunk.index == 0)
        #expect(chunk.startTime == "10:00:00")
        #expect(chunk.endTime == "10:01:30")
        #expect(chunk.utteranceCount == 25)
        #expect(chunk.summaryText.contains("feature launch"))
    }
}

