import Foundation

public struct MeetingSpeakerSummary: Equatable, Sendable, Identifiable {
    public let speaker: String
    public let summary: String

    public var id: String { speaker }

    public init(speaker: String, summary: String) {
        self.speaker = speaker
        self.summary = summary
    }
}

public struct MeetingReadableArtifacts: Equatable, Sendable {
    public let transcriptURL: URL?
    public let transcriptPreview: String?
    public let minutesURL: URL?
    public let minutesPDFURL: URL?
    public let minutesTitle: String?
    public let minutesPreview: String?
    public let speakerSummaries: [MeetingSpeakerSummary]

    public init(
        transcriptURL: URL?,
        transcriptPreview: String?,
        minutesURL: URL?,
        minutesPDFURL: URL?,
        minutesTitle: String?,
        minutesPreview: String?,
        speakerSummaries: [MeetingSpeakerSummary]
    ) {
        self.transcriptURL = transcriptURL
        self.transcriptPreview = transcriptPreview
        self.minutesURL = minutesURL
        self.minutesPDFURL = minutesPDFURL
        self.minutesTitle = minutesTitle
        self.minutesPreview = minutesPreview
        self.speakerSummaries = speakerSummaries
    }
}

public enum MeetingReadableArtifactsReader {
    public static func inspect(sessionURL: URL) -> MeetingReadableArtifacts {
        let fileManager = FileManager.default
        let minutesURL = firstExistingURL(
            [
                sessionURL.appendingPathComponent("会议纪要.md"),
                sessionURL.appendingPathComponent("会议纪要.internal_final.md"),
            ],
            fileManager: fileManager
        ) ?? firstMatchingFile(
            in: sessionURL,
            fileExtension: "md",
            nameContains: "会议纪要",
            fileManager: fileManager
        )
        let pdfURL = firstExistingURL(
            [
                sessionURL.appendingPathComponent("会议纪要.pdf"),
                sessionURL.appendingPathComponent("会议纪要与原始对话.pdf"),
            ],
            fileManager: fileManager
        ) ?? firstMatchingFile(
            in: sessionURL,
            fileExtension: "pdf",
            nameContains: "会议纪要",
            fileManager: fileManager
        )
        let transcriptURL = transcriptArtifactURL(
            sessionURL: sessionURL,
            fileManager: fileManager
        )

        let minutesMarkdown = minutesURL.flatMap {
            readTextPrefix($0, byteLimit: 96_000)
        }
        let transcriptText = transcriptURL.flatMap {
            readTextPrefix($0, byteLimit: 24_000)
        }

        return MeetingReadableArtifacts(
            transcriptURL: transcriptURL,
            transcriptPreview: transcriptText.flatMap {
                compactPreview(from: $0, characterLimit: 520)
            },
            minutesURL: minutesURL,
            minutesPDFURL: pdfURL,
            minutesTitle: minutesMarkdown.flatMap(markdownTitle),
            minutesPreview: minutesMarkdown.flatMap {
                markdownSectionPreview(from: $0, characterLimit: 720)
            },
            speakerSummaries: minutesMarkdown.map(speakerSummaries) ?? []
        )
    }

    public static func markdownTitle(from markdown: String) -> String? {
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("# "), line.count > 2 else { continue }
            return String(line.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    public static func markdownSectionPreview(
        from markdown: String,
        characterLimit: Int
    ) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        let preferredHeadings = [
            "会议摘要",
            "内容摘要",
            "会议概览",
            "核心摘要",
            "概览",
            "候选结论",
            "会议结论",
            "主要结论",
            "核心结论",
        ]

        var startIndex: Int?
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("##") else { continue }
            let heading = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if preferredHeadings.contains(where: { heading.contains($0) }) {
                startIndex = index + 1
                break
            }
        }

        let candidateLines: ArraySlice<String>
        if let startIndex {
            let rest = lines[startIndex...]
            let endOffset = rest.firstIndex {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("##")
            } ?? lines.endIndex
            candidateLines = lines[startIndex..<endOffset]
        } else {
            candidateLines = lines.dropFirst()
        }

        return compactPreview(
            from: candidateLines.joined(separator: "\n"),
            characterLimit: characterLimit
        )
    }

    public static func speakerSummaries(
        from markdown: String
    ) -> [MeetingSpeakerSummary] {
        let lines = markdown.components(separatedBy: .newlines)
        let sectionKeywords = [
            "按人观点",
            "按人总结",
            "按发言人总结",
            "按发言人观点",
        ]
        guard let sectionStart = lines.firstIndex(where: { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("## ") else { return false }
            let title = String(line.dropFirst(3))
            return sectionKeywords.contains(where: { title.contains($0) })
        }) else { return [] }

        let sectionEnd = lines[(sectionStart + 1)...].firstIndex { rawLine in
            rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("## ")
        } ?? lines.endIndex

        var results: [MeetingSpeakerSummary] = []
        var currentSpeaker: String?
        var currentLines: [String] = []

        func appendCurrent() {
            guard let currentSpeaker,
                  let summary = compactPreview(
                      from: currentLines.joined(separator: "\n"),
                      characterLimit: 8_000
                  ),
                  !summary.isEmpty
            else { return }
            results.append(
                MeetingSpeakerSummary(
                    speaker: currentSpeaker,
                    summary: summary
                )
            )
        }

        for rawLine in lines[(sectionStart + 1)..<sectionEnd] {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("### ") {
                appendCurrent()
                let speaker = String(line.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentSpeaker = speaker.isEmpty ? nil : speaker
                currentLines = []
            } else if currentSpeaker != nil {
                currentLines.append(rawLine)
            }
        }
        appendCurrent()
        return results
    }

    private static func transcriptArtifactURL(
        sessionURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let readableCandidates = [
            "会议原始转写-说话人阅读版.md",
            "带说话人状态的逐段转写.md",
            "原始转写.md",
            "完整转写.md",
        ].map { sessionURL.appendingPathComponent($0) }
        if let readable = firstExistingURL(
            readableCandidates,
            fileManager: fileManager
        ) {
            return readable
        }

        let packageURL = sessionURL.appendingPathComponent("meeting-package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcription = root["transcription"] as? [String: Any],
              let artifacts = transcription["artifacts"] as? [String: Any]
        else { return nil }

        for key in ["text", "raw_text"] {
            guard let path = artifacts[key] as? String else { continue }
            let url = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func firstExistingURL(
        _ urls: [URL],
        fileManager: FileManager
    ) -> URL? {
        urls.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func firstMatchingFile(
        in directoryURL: URL,
        fileExtension: String,
        nameContains text: String,
        fileManager: FileManager
    ) -> URL? {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter {
                $0.pathExtension.lowercased() == fileExtension.lowercased()
                    && $0.deletingPathExtension().lastPathComponent.contains(text)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private static func readTextPrefix(
        _ url: URL,
        byteLimit: Int
    ) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit),
              !data.isEmpty
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func compactPreview(
        from text: String,
        characterLimit: Int
    ) -> String? {
        var pieces: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            line = line.replacingOccurrences(
                of: #"!\[[^\]]*\]\([^)]+\)"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"^[-*]\s+"#,
                with: "• ",
                options: .regularExpression
            )
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            pieces.append(line)
        }
        let joined = pieces.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        if joined.count <= characterLimit {
            return joined
        }
        let end = joined.index(joined.startIndex, offsetBy: characterLimit)
        return String(joined[..<end]).trimmingCharacters(
            in: .whitespacesAndNewlines
        ) + "…"
    }
}
