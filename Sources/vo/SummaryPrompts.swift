import Foundation

/// Templates for Apple Intelligence Foundation Models summarization prompts.
enum SummaryPrompts {
    /// Build a prompt for summarizing an intermediate chunk during Map-Reduce.
    static func chunkPrompt(
        index: Int,
        startTimestamp: String?,
        endTimestamp: String?,
        chunkText: String
    ) -> String {
        let timeRange: String
        if let start = startTimestamp, !start.isEmpty, let end = endTimestamp, !end.isEmpty {
            timeRange = " (utterances \(start) to \(end))"
        } else {
            timeRange = ""
        }

        return """
        The following is part \(index + 1)\(timeRange) of a meeting transcript.
        Summarize the key discussion points, decisions, and speaker remarks in 3-5 concise bullet points.
        IMPORTANT: Respond in the primary language used in the transcript.

        ---
        \(chunkText)
        """
    }

    /// Build the final prompt for generating structured meeting minutes.
    static func finalPrompt(
        transcript: String,
        isIntermediateSummary: Bool = false,
        customPrompt: String? = nil
    ) -> String {
        if let customPrompt {
            return """
            \(customPrompt)

            ---
            \(transcript)
            """
        }

        let sourceDescription = isIntermediateSummary
            ? "the intermediate summaries of each part of the meeting"
            : "the meeting transcript"

        return """
        Analyze \(sourceDescription) below and create structured meeting minutes in Markdown format.
        IMPORTANT: Write the entire response in the primary language used in the transcript (including section headings). For example, use Japanese if the transcript is in Japanese.

        Structure the minutes cleanly:
        - **Title / Header**
        - **Summary**: 2-4 sentences describing the main purpose and overall outcome.
        - **Key Discussion Points**: Bullet points of main topics and conclusions.
        - **Decisions**: Agreed conclusions or decisions (or indicate none).
        - **Action Items**: Checklist format `- [ ] [Owner] Task` (or indicate none).

        ---
        \(transcript)
        """
    }
}
