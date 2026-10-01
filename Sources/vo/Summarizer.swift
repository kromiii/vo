import Foundation
import FoundationModels

/// On-device meeting summarizer using Apple Intelligence Foundation Models (`SystemLanguageModel`).
struct Summarizer: Sendable {
    let customPrompt: String?

    init(customPrompt: String? = nil) {
        self.customPrompt = customPrompt
    }

    /// Check if Foundation Models / Apple Intelligence is available on this system.
    static func checkAvailability() throws {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return
        case .unavailable(let reason):
            let explanation: String
            switch reason {
            case .deviceNotEligible:
                explanation = "Device is not eligible for Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                explanation = "Apple Intelligence is disabled in System Settings."
            case .modelNotReady:
                explanation = "The foundation model is not ready (still downloading or preparing assets)."
            @unknown default:
                explanation = "Foundation model is currently unavailable."
            }
            throw VoError.foundationModelNotAvailable(reason: explanation)
        }
    }

    /// Single line representation of a transcript item.
    struct TranscriptLine: Sendable {
        let timestamp: String
        let channel: String
        let text: String
    }

    /// Parse transcript entries from JSONL lines produced by SessionLog / StreamRenderer.
    static func parseTranscriptLines(fromJSONLLines lines: [String]) -> [TranscriptLine] {
        var results: [TranscriptLine] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                continue
            }

            let channel = (obj["channel"] as? String) ?? ""
            let rawTimestamp = (obj["timestamp"] as? String) ?? ""
            let formattedTime = extractDisplayTime(from: rawTimestamp)

            let srcObj = obj["src"] as? [String: Any]
            let srcText = (srcObj?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let dstObj = obj["dst"] as? [String: Any]
            let dstText = (dstObj?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !srcText.isEmpty else { continue }

            let combinedText: String
            if let dstText, !dstText.isEmpty && dstText != srcText {
                combinedText = "\(srcText) (\(dstText))"
            } else {
                combinedText = srcText
            }

            results.append(TranscriptLine(
                timestamp: formattedTime,
                channel: channel,
                text: combinedText
            ))
        }

        return results
    }

    /// Read and parse transcript lines from a JSONL file on disk.
    static func loadTranscriptLines(fromPath path: String) throws -> [TranscriptLine] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        return parseTranscriptLines(fromJSONLLines: lines)
    }

    /// Format transcript lines into a readable dialog block.
    static func formatTranscript(_ lines: [TranscriptLine]) -> String {
        return lines.map { line in
            let prefix: String
            if !line.timestamp.isEmpty && !line.channel.isEmpty {
                prefix = "[\(line.timestamp)] [\(line.channel)]"
            } else if !line.channel.isEmpty {
                prefix = "[\(line.channel)]"
            } else if !line.timestamp.isEmpty {
                prefix = "[\(line.timestamp)]"
            } else {
                prefix = "-"
            }
            return "\(prefix) \(line.text)"
        }.joined(separator: "\n")
    }

    /// Generate an on-device meeting summary from the transcript lines.
    func summarize(lines: [TranscriptLine]) async throws -> String {
        guard !lines.isEmpty else {
            return "No transcript content was captured to summarize."
        }

        try Self.checkAvailability()

        let formatted = Self.formatTranscript(lines)

        // For large transcripts (> 6000 characters or > 50 lines), use chunked hierarchical summarization
        // to avoid exceeding the on-device model's context window size.
        if formatted.count > 6000 || lines.count > 60 {
            return try await summarizeHierarchically(lines: lines)
        }

        do {
            return try await summarizeDirect(transcript: formatted)
        } catch let genError as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = genError {
                // Fall back to hierarchical summarization if direct summarization exceeded context
                return try await summarizeHierarchically(lines: lines)
            }
            throw VoError.summarizationFailed(reason: genError.localizedDescription)
        } catch {
            throw VoError.summarizationFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Direct Summarization

    private func summarizeDirect(transcript: String) async throws -> String {
        let session = LanguageModelSession()
        let promptText = SummaryPrompts.finalPrompt(transcript: transcript, customPrompt: customPrompt)
        let response = try await session.respond(to: promptText)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Hierarchical (Map-Reduce) Summarization

    private func summarizeHierarchically(lines: [TranscriptLine]) async throws -> String {
        let chunkSize = 30
        var chunks: [[TranscriptLine]] = []
        for i in stride(from: 0, to: lines.count, by: chunkSize) {
            let end = min(i + chunkSize, lines.count)
            chunks.append(Array(lines[i..<end]))
        }

        var partialSummaries: [String] = []

        for (idx, chunk) in chunks.enumerated() {
            let chunkText = Self.formatTranscript(chunk)
            let session = LanguageModelSession()
            let prompt = SummaryPrompts.chunkPrompt(
                index: idx,
                startTimestamp: chunk.first?.timestamp,
                endTimestamp: chunk.last?.timestamp,
                chunkText: chunkText
            )
            do {
                let res = try await session.respond(to: prompt)
                let text = res.content.trimmingCharacters(in: .whitespacesAndNewlines)
                partialSummaries.append("### Part \(idx + 1)\n\(text)")
            } catch {
                // If a sub-chunk fails, include its raw text truncated as fallback
                let fallback = chunk.prefix(10).map { "\($0.channel): \($0.text)" }.joined(separator: "; ")
                partialSummaries.append("### Part \(idx + 1)\n(Summarization failed: \(fallback)...)")
            }
        }

        let combinedSummaries = partialSummaries.joined(separator: "\n\n")

        // Final reduce pass
        let reduceSession = LanguageModelSession()
        let finalPrompt = SummaryPrompts.finalPrompt(
            transcript: combinedSummaries,
            isIntermediateSummary: true,
            customPrompt: customPrompt
        )
        let finalResponse = try await reduceSession.respond(to: finalPrompt)
        return finalResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helper

    private static func extractDisplayTime(from isoDateString: String) -> String {
        // e.g. "2026-06-10T08:34:56.234+09:00" -> "08:34:56"
        guard let tIndex = isoDateString.firstIndex(of: "T") else { return "" }
        let afterT = isoDateString[isoDateString.index(after: tIndex)...]
        // Take first 8 chars (HH:mm:ss)
        let timePart = afterT.prefix(8)
        return String(timePart)
    }
}
