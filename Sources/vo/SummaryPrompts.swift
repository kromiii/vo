import ArgumentParser
import Foundation

/// Preset styles for AI summarization.
enum SummaryPreset: String, ExpressibleByArgument, CaseIterable, Sendable {
    case general
    case meeting
}

/// Templates for Apple Intelligence Foundation Models summarization prompts.
enum SummaryPrompts {
    /// Build a prompt for summarizing an intermediate chunk during Map-Reduce.
    static func chunkPrompt(
        index: Int,
        startTimestamp: String?,
        endTimestamp: String?,
        chunkText: String,
        targetLanguage: String? = nil,
        preset: SummaryPreset = .general
    ) -> String {
        let timeRange: String
        if let start = startTimestamp, !start.isEmpty, let end = endTimestamp, !end.isEmpty {
            timeRange = " (utterances \(start) to \(end))"
        } else {
            timeRange = ""
        }

        let languageInstruction: String
        if let targetLanguage, !targetLanguage.isEmpty {
            languageInstruction = "IMPORTANT: Write the entire summary in \(targetLanguage)."
        } else {
            languageInstruction = "IMPORTANT: Write the entire summary in the primary language used in the transcript."
        }

        switch preset {
        case .general:
            return """
            The following is part \(index + 1)\(timeRange) of a transcript.
            Summarize the key discussion points, main topics, and notable remarks in 3-5 concise bullet points.
            \(languageInstruction)

            ---
            \(chunkText)
            """
        case .meeting:
            return """
            The following is part \(index + 1)\(timeRange) of a meeting transcript.
            Summarize the key discussion points, decisions, and speaker remarks in 3-5 concise bullet points.
            \(languageInstruction)

            ---
            \(chunkText)
            """
        }
    }

    /// Build the final prompt for generating a structured summary.
    static func finalPrompt(
        transcript: String,
        isIntermediateSummary: Bool = false,
        customPrompt: String? = nil,
        targetLanguage: String? = nil,
        preset: SummaryPreset = .general
    ) -> String {
        if let customPrompt {
            return """
            \(customPrompt)

            ---
            \(transcript)
            """
        }

        switch preset {
        case .general:
            let sourceDescription = isIntermediateSummary
                ? "the intermediate summaries of each part"
                : "the transcript"

            let languageInstruction: String
            if let targetLanguage, !targetLanguage.isEmpty {
                languageInstruction = "IMPORTANT: Write the entire response in \(targetLanguage) (including all section headings, overview, key points, and takeaways). Do NOT use any other language."
            } else {
                languageInstruction = "IMPORTANT: Write the entire response in the primary language used in the transcript (including section headings). Do NOT translate into another language unless explicitly requested."
            }

            return """
            Analyze \(sourceDescription) below and synthesize a concise, structured summary in Markdown format.
            \(languageInstruction)
            Do NOT split or format by chronological parts/chunks; synthesize the entire content into a single unified summary.

            CONCISENESS & LENGTH REQUIREMENTS:
            - Keep the entire summary concise, readable in 2-3 minutes (target length: approx. 800 - 1,200 characters in Japanese, or 300 - 500 words in English).
            - Do NOT produce an overly long or exhaustive transcript recap. Strictly omit minor conversational details and focus exclusively on core takeaways and key discussions.

            Structure the summary cleanly:
            - **Title / Topic**: Concise Title / Topic
            - **Overview**: 2-4 concise sentences summarizing the main theme and overall context.
            - **Key Points**: Strictly 3-5 bullet points covering the most important concepts, discussion points, or highlights (each bullet should be 1-2 sentences). Do NOT exceed 5 bullets.
            - **Takeaways & Outcomes**: 2-4 bullet points of notable conclusions, takeaways, or next steps (or write "None" if not applicable).

            ---
            \(transcript)
            """

        case .meeting:
            let sourceDescription = isIntermediateSummary
                ? "the intermediate summaries of each part of the meeting"
                : "the meeting transcript"

            let languageInstruction: String
            if let targetLanguage, !targetLanguage.isEmpty {
                languageInstruction = "IMPORTANT: Write the entire response in \(targetLanguage) (including all section headings, summary, decisions, and action items). Do NOT use any other language."
            } else {
                languageInstruction = "IMPORTANT: Write the entire response in the primary language used in the transcript (including section headings). Do NOT translate into another language unless explicitly requested."
            }

            return """
            Analyze \(sourceDescription) below and synthesize a concise, structured meeting summary in Markdown format.
            \(languageInstruction)
            Do NOT split or format by chronological parts/chunks; synthesize the entire meeting into a single unified summary.

            CONCISENESS & LENGTH REQUIREMENTS:
            - Keep the entire summary concise, readable in 2-3 minutes (target length: approx. 800 - 1,200 characters in Japanese, or 300 - 500 words in English).
            - Do NOT produce an overly long or exhaustive transcript recap. Strictly omit minor conversational details and focus exclusively on high-level outcomes and agreements.

            Structure the minutes cleanly:
            - **Title / Header**: Meeting Title / Topic
            - **Summary**: 2-4 concise sentences summarizing the primary purpose, core outcome, and current status.
            - **Key Discussion Points**: Strictly 3-5 bullet points covering only the most important topics and agreed conclusions (each bullet should be 1-2 sentences). Do NOT exceed 5 bullets.
            - **Decisions**: 2-4 bullet points of concrete agreements or decisions made (or write "None" if none).
            - **Action Items**: 2-5 bullet points in checklist format `- [ ] [Owner] Task` focusing on concrete next steps (or write "None" if none).

            ---
            \(transcript)
            """
        }
    }

    /// Build a prompt for incrementally updating an existing summary with newly captured utterances.
    static func updatePrompt(
        existingSummary: String,
        newUtterances: String,
        customPrompt: String? = nil,
        targetLanguage: String? = nil,
        preset: SummaryPreset = .general
    ) -> String {
        if let customPrompt {
            return """
            \(customPrompt)

            ---
            Current Summary:
            \(existingSummary)

            ---
            New Utterances:
            \(newUtterances)
            """
        }

        let languageInstruction: String
        if let targetLanguage, !targetLanguage.isEmpty {
            languageInstruction = "Write the entire output in \(targetLanguage) (including all section headings)."
        } else {
            languageInstruction = "Write the entire output in the primary language used in the transcript (including section headings)."
        }

        switch preset {
        case .general:
            return """
            You are an expert editor maintaining a structured summary in Markdown.
            Update the current summary below by incorporating the new utterances from the ongoing audio.

            IMPORTANT INSTRUCTIONS:
            1. Synthesize the new content smoothly into the existing sections. Do NOT create chronological or "Part" sections (e.g. do NOT write "Part 1", "Part 2", etc.).
            2. Keep the summary well-structured:
               - **Title / Topic**: Maintain or adjust the title if appropriate.
               - **Overview**: 2-4 sentences describing the main theme and overall context.
               - **Key Points**: Strictly 3-5 bullet points covering the main concepts, discussion points, or highlights (each bullet should be 1-2 sentences). Do NOT exceed 5 bullets.
               - **Takeaways & Outcomes**: Notable conclusions, takeaways, or next steps (preserve previously noted takeaways unless superseded).
            3. \(languageInstruction)
            4. Return ONLY the complete updated Markdown document.

            ---
            Current Summary:
            \(existingSummary)

            ---
            New Utterances:
            \(newUtterances)
            """

        case .meeting:
            return """
            You are an expert meeting secretary maintaining structured meeting minutes in Markdown.
            Update the current meeting minutes below by incorporating the new utterances from the ongoing conversation.

            IMPORTANT INSTRUCTIONS:
            1. Synthesize the new discussion smoothly into the existing sections. Do NOT create chronological or "Part" sections (e.g. do NOT write "Part 1", "Part 2", etc.).
            2. Keep the minutes well-structured:
               - **Title / Header**: Maintain or adjust the meeting title if appropriate.
               - **Summary**: 2-4 sentences describing the overall purpose and current progress.
               - **Key Discussion Points**: Strictly 3-5 bullet points covering the main topics and conclusions (each bullet should be 1-2 sentences). Do NOT exceed 5 bullets.
               - **Decisions**: Agreed conclusions or decisions (preserve previously agreed decisions unless explicitly superseded).
               - **Action Items**: Checklist format `- [ ] [Owner] Task` (preserve previously assigned action items unless completed).
            3. \(languageInstruction)
            4. Return ONLY the complete updated Markdown document.

            ---
            Current Meeting Minutes:
            \(existingSummary)

            ---
            New Utterances:
            \(newUtterances)
            """
        }
    }
}
