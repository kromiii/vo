import Foundation
import FoundationModels

/// On-device meeting summarizer using Apple Intelligence Foundation Models (`SystemLanguageModel`).
///
/// Supports real-time rolling / incremental summarization during a live meeting session,
/// keeping memory and context window consumption bounded and updating the summary file live.
actor Summarizer {
    let summaryOut: String?
    let customPrompt: String?

    private(set) var currentSummary: String = ""
    private var pendingLines: [TranscriptLine] = []
    private var isUpdating: Bool = false
    private var lastUpdateTime: Date = Date()
    private var totalCapturedLines: Int = 0

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
    /// and return the final Markdown meeting summary.
    func finalize() async throws -> String {
        // Wait for any in-flight background update to complete
        while isUpdating {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        if !pendingLines.isEmpty {
            let lines = pendingLines
            pendingLines.removeAll()
            let updated = try await performSummarize(lines: lines, existingSummary: currentSummary)
            currentSummary = updated
            writeSummaryToFileIfNeeded()
        }

        return currentSummary
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
            let updated = try await performSummarize(lines: lines, existingSummary: currentSummary)
            currentSummary = updated
            writeSummaryToFileIfNeeded()
        } catch {
            // Re-queue the un-summarized lines at the front so they aren't lost
            pendingLines.insert(contentsOf: lines, at: 0)
        }
    }

    private func writeSummaryToFileIfNeeded() {
        guard let summaryOut, !currentSummary.isEmpty else { return }
        let resolved = (summaryOut as NSString).expandingTildeInPath
        try? currentSummary.write(toFile: resolved, atomically: true, encoding: .utf8)
    }

    // MARK: - LLM Inference

    /// Generate an updated meeting summary given new transcript lines and an optional existing summary.
    private func performSummarize(lines: [TranscriptLine], existingSummary: String) async throws -> String {
        guard !lines.isEmpty else { return existingSummary }

        try Self.checkAvailability()

        let formattedLines = Self.formatTranscript(lines)
        let promptText: String
        if existingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // First pass: generate initial structured minutes
            promptText = SummaryPrompts.finalPrompt(
                transcript: formattedLines,
                isIntermediateSummary: false,
                customPrompt: customPrompt
            )
        } else {
            // Incremental pass: update existing minutes with new lines
            promptText = SummaryPrompts.updatePrompt(
                existingSummary: existingSummary,
                newUtterances: formattedLines,
                customPrompt: customPrompt
            )
        }

        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: promptText)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let genError as LanguageModelSession.GenerationError {
            throw VoError.summarizationFailed(reason: genError.localizedDescription)
        } catch {
            throw VoError.summarizationFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Batch API (for backwards compatibility & tests)

    /// Generate a meeting summary from a batch of transcript lines (e.g. for offline evaluation).
    func summarize(lines: [TranscriptLine]) async throws -> String {
        currentSummary = ""
        pendingLines = []
        totalCapturedLines = 0

        guard !lines.isEmpty else {
            return "No transcript content was captured to summarize."
        }

        let chunkSize = 30
        for i in stride(from: 0, to: lines.count, by: chunkSize) {
            let end = min(i + chunkSize, lines.count)
            let chunk = Array(lines[i..<end])
            let updated = try await performSummarize(lines: chunk, existingSummary: currentSummary)
            currentSummary = updated
        }

        return currentSummary
    }

    // MARK: - Helper

    nonisolated private static func extractDisplayTime(from isoDateString: String) -> String {
        guard let tIndex = isoDateString.firstIndex(of: "T") else { return "" }
        let afterT = isoDateString[isoDateString.index(after: tIndex)...]
        let timePart = afterT.prefix(8)
        return String(timePart)
    }
}
