import Foundation
import FoundationModels

/// On-device meeting summarizer using Apple Intelligence Foundation Models (`SystemLanguageModel`).
///
/// Supports real-time rolling / incremental summarization during a live meeting session,
/// keeping memory and context window consumption bounded and updating the summary file live.
actor Summarizer {
    let summaryOut: String?
    let customPrompt: String?

    /// Representation of a summarized transcript chunk.
    struct ChunkSummary: Sendable {
        let index: Int
        let startTime: String
        let endTime: String
        let utteranceCount: Int
        let summaryText: String
    }

    private(set) var partialSummaries: [ChunkSummary] = []
    private(set) var finalSummary: String = ""
    private var pendingLines: [TranscriptLine] = []
    private var isUpdating: Bool = false
    private var lastUpdateTime: Date = Date()
    private var totalCapturedLines: Int = 0
    private var chunkIndex: Int = 0

    /// Callback invoked when a new chunk summary is produced.
    typealias ChunkHandler = @Sendable (ChunkSummary) async -> Void
    private var onAppendChunk: ChunkHandler?

    func setOnAppendChunk(_ handler: @escaping ChunkHandler) {
        self.onAppendChunk = handler
    }

    /// Threshold of pending lines before triggering an automatic background summary update.
    private let updateChunkThreshold = 25
    /// Minimum time between background summary updates if there are at least some pending lines.
    private let updateIntervalSeconds: TimeInterval = 60.0

    init(summaryOut: String? = nil, customPrompt: String? = nil) {
        self.summaryOut = summaryOut
        self.customPrompt = customPrompt
    }

    /// Check if Foundation Models / Apple Intelligence is available on this system.
    nonisolated static func checkAvailability() throws {
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
    nonisolated static func parseTranscriptLines(fromJSONLLines lines: [String]) -> [TranscriptLine] {
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
    nonisolated static func loadTranscriptLines(fromPath path: String) throws -> [TranscriptLine] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        return parseTranscriptLines(fromJSONLLines: lines)
    }

    /// Format transcript lines into a readable dialog block.
    nonisolated static func formatTranscript(_ lines: [TranscriptLine]) -> String {
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

    // MARK: - Streaming / Real-time API

    /// Feed a new transcript line as it is finalized by the renderer.
    func append(_ line: TranscriptLine) {
        pendingLines.append(line)
        totalCapturedLines += 1
        checkTriggerUpdate()
    }

    /// Total number of transcript lines received so far.
    var utteranceCount: Int {
        totalCapturedLines
    }

    /// Finish summarization at session exit, incorporating any remaining pending lines,
    /// synthesizing a unified meeting minutes document, and returning the final Markdown.
    func finalize() async throws -> String {
        // Wait for any in-flight background update to complete
        while isUpdating {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Summarize any remaining pending lines into a final chunk
        if !pendingLines.isEmpty {
            let lines = pendingLines
            pendingLines.removeAll()
            do {
                let chunk = try await performChunkSummarize(lines: lines, index: chunkIndex)
                chunkIndex += 1
                partialSummaries.append(chunk)
                writeInterimSummaryToFileIfNeeded()
                if let onAppendChunk {
                    await onAppendChunk(chunk)
                }
            } catch {
                // If chunk summarization fails, keep lines for direct fallback below
                pendingLines = lines
            }
        }

        // Now synthesize the final unified meeting minutes
        try Self.checkAvailability()
        let result: String

        if partialSummaries.isEmpty {
            if !pendingLines.isEmpty {
                let formatted = Self.formatTranscript(pendingLines)
                let prompt = SummaryPrompts.finalPrompt(
                    transcript: formatted,
                    isIntermediateSummary: false,
                    customPrompt: customPrompt
                )
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                result = "No transcript content was captured to summarize."
            }
        } else if partialSummaries.count == 1 && pendingLines.isEmpty {
            let single = partialSummaries[0]
            let prompt = SummaryPrompts.finalPrompt(
                transcript: single.summaryText,
                isIntermediateSummary: true,
                customPrompt: customPrompt
            )
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let combinedParts = partialSummaries.map { part in
                let timeRange = (!part.startTime.isEmpty && !part.endTime.isEmpty) ? " [\(part.startTime) - \(part.endTime)]" : ""
                return "### Part \(part.index + 1)\(timeRange)\n\(part.summaryText)"
            }.joined(separator: "\n\n")

            let prompt = SummaryPrompts.finalPrompt(
                transcript: combinedParts,
                isIntermediateSummary: true,
                customPrompt: customPrompt
            )
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        self.finalSummary = result
        writeFinalSummaryToFile(result)
        return result
    }

    // MARK: - Background Update Logic

    private func checkTriggerUpdate() {
        guard !isUpdating else { return }
        let elapsed = Date().timeIntervalSince(lastUpdateTime)
        if pendingLines.count >= updateChunkThreshold || (pendingLines.count >= 10 && elapsed >= updateIntervalSeconds) {
            triggerBackgroundUpdate()
        }
    }

    private func triggerBackgroundUpdate() {
        guard !isUpdating, !pendingLines.isEmpty else { return }
        isUpdating = true
        let linesToSummarize = pendingLines
        pendingLines.removeAll()

        Task {
            await self.runBackgroundUpdate(lines: linesToSummarize)
        }
    }

    private func runBackgroundUpdate(lines: [TranscriptLine]) async {
        defer {
            isUpdating = false
            lastUpdateTime = Date()
            // If more lines accumulated while updating, check if another update is needed
            if pendingLines.count >= updateChunkThreshold {
                triggerBackgroundUpdate()
            }
        }

        do {
            let chunk = try await performChunkSummarize(lines: lines, index: chunkIndex)
            chunkIndex += 1
            partialSummaries.append(chunk)
            writeInterimSummaryToFileIfNeeded()
            if let onAppendChunk {
                await onAppendChunk(chunk)
            }
        } catch {
            // Re-queue the un-summarized lines at the front so they aren't lost
            pendingLines.insert(contentsOf: lines, at: 0)
        }
    }

    private func writeInterimSummaryToFileIfNeeded() {
        guard let summaryOut, !partialSummaries.isEmpty else { return }
        let resolved = (summaryOut as NSString).expandingTildeInPath
        let content = partialSummaries.map { part in
            let timeRange = (!part.startTime.isEmpty && !part.endTime.isEmpty) ? " [\(part.startTime) - \(part.endTime)]" : ""
            return "## Part \(part.index + 1)\(timeRange)\n\n\(part.summaryText)"
        }.joined(separator: "\n\n")
        try? content.write(toFile: resolved, atomically: true, encoding: .utf8)
    }

    private func writeFinalSummaryToFile(_ content: String) {
        guard let summaryOut, !content.isEmpty else { return }
        let resolved = (summaryOut as NSString).expandingTildeInPath
        try? content.write(toFile: resolved, atomically: true, encoding: .utf8)
    }

    // MARK: - LLM Inference

    /// Generate a concise summary chunk for a set of transcript lines.
    private func performChunkSummarize(lines: [TranscriptLine], index: Int) async throws -> ChunkSummary {
        guard !lines.isEmpty else {
            return ChunkSummary(index: index, startTime: "", endTime: "", utteranceCount: 0, summaryText: "")
        }

        try Self.checkAvailability()

        let startTime = lines.first?.timestamp ?? ""
        let endTime = lines.last?.timestamp ?? ""
        let formattedLines = Self.formatTranscript(lines)
        let promptText = SummaryPrompts.chunkPrompt(
            index: index,
            startTimestamp: startTime,
            endTimestamp: endTime,
            chunkText: formattedLines
        )

        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: promptText)
            let summaryText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChunkSummary(
                index: index,
                startTime: startTime,
                endTime: endTime,
                utteranceCount: lines.count,
                summaryText: summaryText
            )
        } catch let genError as LanguageModelSession.GenerationError {
            throw VoError.summarizationFailed(reason: genError.localizedDescription)
        } catch {
            throw VoError.summarizationFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Batch API (for backwards compatibility & tests)

    /// Generate a meeting summary from a batch of transcript lines (e.g. for offline evaluation).
    func summarize(lines: [TranscriptLine]) async throws -> String {
        partialSummaries = []
        finalSummary = ""
        pendingLines = lines
        totalCapturedLines = lines.count
        chunkIndex = 0

        guard !lines.isEmpty else {
            return "No transcript content was captured to summarize."
        }

        return try await finalize()
    }

    // MARK: - Helper

    nonisolated private static func extractDisplayTime(from isoDateString: String) -> String {
        guard let tIndex = isoDateString.firstIndex(of: "T") else { return "" }
        let afterT = isoDateString[isoDateString.index(after: tIndex)...]
        let timePart = afterT.prefix(8)
        return String(timePart)
    }
}
