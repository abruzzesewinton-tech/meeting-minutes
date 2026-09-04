import Foundation

public struct MeetingSpeakerUtterance: Equatable, Sendable, Identifiable {
    public let id: String
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let audioStartSeconds: TimeInterval
    public let audioEndSeconds: TimeInterval
    public let text: String
    public let rawSpeaker: String
    public let displaySpeaker: String
    public let identityStatus: String
    public let audioURL: URL?
    public let isHumanCorrected: Bool

    public init(
        id: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        audioStartSeconds: TimeInterval,
        audioEndSeconds: TimeInterval,
        text: String,
        rawSpeaker: String,
        displaySpeaker: String,
        identityStatus: String,
        audioURL: URL?,
        isHumanCorrected: Bool
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.audioStartSeconds = audioStartSeconds
        self.audioEndSeconds = audioEndSeconds
        self.text = text
        self.rawSpeaker = rawSpeaker
        self.displaySpeaker = displaySpeaker
        self.identityStatus = identityStatus
        self.audioURL = audioURL
        self.isHumanCorrected = isHumanCorrected
    }
}

public struct MeetingSpeakerTimeline: Equatable, Sendable {
    public let sourceURL: URL?
    public let utterances: [MeetingSpeakerUtterance]
    public let hasHumanCorrections: Bool
    public let correctedAt: Date?

    public init(
        sourceURL: URL?,
        utterances: [MeetingSpeakerUtterance],
        hasHumanCorrections: Bool,
        correctedAt: Date?
    ) {
        self.sourceURL = sourceURL
        self.utterances = utterances
        self.hasHumanCorrections = hasHumanCorrections
        self.correctedAt = correctedAt
    }

    public var speakers: [String] {
        var seen = Set<String>()
        let values = utterances.compactMap { item in
            seen.insert(item.displaySpeaker).inserted
                ? item.displaySpeaker
                : nil
        }
        return values.sorted { lhs, rhs in
            let lhsAnonymous = lhs.hasPrefix("未确认发言人")
            let rhsAnonymous = rhs.hasPrefix("未确认发言人")
            if lhsAnonymous != rhsAnonymous {
                return !lhsAnonymous
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

public struct MeetingSpeakerCorrection: Codable, Equatable, Sendable {
    public let segmentID: String
    public let originalSpeaker: String
    public let correctedSpeaker: String
    public let correctedAt: Date

    public init(
        segmentID: String,
        originalSpeaker: String,
        correctedSpeaker: String,
        correctedAt: Date
    ) {
        self.segmentID = segmentID
        self.originalSpeaker = originalSpeaker
        self.correctedSpeaker = correctedSpeaker
        self.correctedAt = correctedAt
    }
}

public struct MeetingSpeakerCorrectionDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let meetingID: String
    public let sourceTimeline: String?
    public var corrections: [MeetingSpeakerCorrection]
    public var minutesInvalidatedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case sourceTimeline = "source_timeline"
        case corrections
        case minutesInvalidatedAt = "minutes_invalidated_at"
    }

    public init(
        schemaVersion: Int = 1,
        meetingID: String,
        sourceTimeline: String?,
        corrections: [MeetingSpeakerCorrection],
        minutesInvalidatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.sourceTimeline = sourceTimeline
        self.corrections = corrections
        self.minutesInvalidatedAt = minutesInvalidatedAt
    }
}

public enum MeetingSpeakerTimelineReader {
    public static let correctionsRelativePath =
        "meeting-assistant/speaker-corrections.json"

    public static func inspect(sessionURL: URL) -> MeetingSpeakerTimeline {
        let sourceURL = preferredTimelineURL(in: sessionURL)
        let correctionDocument = readCorrections(sessionURL: sessionURL)
        let corrections = Dictionary(
            uniqueKeysWithValues: (correctionDocument?.corrections ?? []).map {
                ($0.segmentID, $0)
            }
        )

        guard let sourceURL,
              let data = try? Data(contentsOf: sourceURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return MeetingSpeakerTimeline(
                sourceURL: sourceURL,
                utterances: [],
                hasHumanCorrections: !(correctionDocument?.corrections.isEmpty ?? true),
                correctedAt: correctionDocument?.minutesInvalidatedAt
            )
        }

        let utterances = rows.compactMap { row -> MeetingSpeakerUtterance? in
            guard let id = row["id"] as? String,
                  let text = row["text"] as? String
            else { return nil }
            let rawSpeaker = (row["speaker"] as? String) ?? "unknown"
            let identityStatus = (row["identity_status"] as? String) ?? "unconfirmed"
            let confirmedPerson = (row["confirmed_person"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let verifiedSpeaker: String
            if identityStatus == "confirmed_person",
               let confirmedPerson,
               !confirmedPerson.isEmpty {
                verifiedSpeaker = confirmedPerson
            } else {
                verifiedSpeaker = "未确认发言人 · \(rawSpeaker)"
            }
            let correction = corrections[id]
            let displaySpeaker = correction?.correctedSpeaker ?? verifiedSpeaker
            let audioURL = resolvedAudioURL(
                file: row["audio_file"] as? String,
                sessionURL: sessionURL
            )

            return MeetingSpeakerUtterance(
                id: id,
                startSeconds: number(row["meeting_start"] ?? row["start"]),
                endSeconds: number(row["meeting_end"] ?? row["end"]),
                audioStartSeconds: number(row["start"]),
                audioEndSeconds: number(row["end"]),
                text: text,
                rawSpeaker: rawSpeaker,
                displaySpeaker: displaySpeaker,
                identityStatus: correction == nil
                    ? identityStatus
                    : "human_corrected",
                audioURL: audioURL,
                isHumanCorrected: correction != nil
            )
        }

        return MeetingSpeakerTimeline(
            sourceURL: sourceURL,
            utterances: utterances,
            hasHumanCorrections: !corrections.isEmpty,
            correctedAt: correctionDocument?.minutesInvalidatedAt
        )
    }

    @discardableResult
    public static func saveCorrection(
        sessionURL: URL,
        segmentID: String,
        originalSpeaker: String,
        correctedSpeaker: String,
        now: Date = Date()
    ) throws -> URL {
        let cleanName = correctedSpeaker
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let sourceURL = preferredTimelineURL(in: sessionURL)
        var document = readCorrections(sessionURL: sessionURL)
            ?? MeetingSpeakerCorrectionDocument(
                meetingID: sessionURL.lastPathComponent,
                sourceTimeline: sourceURL?.path,
                corrections: [],
                minutesInvalidatedAt: now
            )
        let replacement = MeetingSpeakerCorrection(
            segmentID: segmentID,
            originalSpeaker: originalSpeaker,
            correctedSpeaker: cleanName,
            correctedAt: now
        )
        if let index = document.corrections.firstIndex(where: {
            $0.segmentID == segmentID
        }) {
            document.corrections[index] = replacement
        } else {
            document.corrections.append(replacement)
        }
        document.minutesInvalidatedAt = now

        let targetURL = sessionURL.appendingPathComponent(
            correctionsRelativePath
        )
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: targetURL, options: .atomic)
        return targetURL
    }

    public static func readCorrections(
        sessionURL: URL
    ) -> MeetingSpeakerCorrectionDocument? {
        let url = sessionURL.appendingPathComponent(correctionsRelativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(
            MeetingSpeakerCorrectionDocument.self,
            from: data
        )
    }

    private static func preferredTimelineURL(in sessionURL: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sessionURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var confirmed: [(URL, Date)] = []
        var base: [(URL, Date)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            guard url.pathExtension.lowercased() == "json",
                  name.contains("speaker-timeline"),
                  !name.contains("before-")
            else { continue }
            let modified = (
                try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            ) ?? .distantPast
            if name.contains("user-confirmed") {
                confirmed.append((url, modified))
            } else if name == "speaker-timeline.json" {
                base.append((url, modified))
            }
        }
        return (confirmed.isEmpty ? base : confirmed)
            .sorted { $0.1 > $1.1 }
            .first?
            .0
    }

    private static func resolvedAudioURL(
        file: String?,
        sessionURL: URL
    ) -> URL? {
        guard let file, !file.isEmpty else { return nil }
        let explicitURL = URL(fileURLWithPath: file)
        if explicitURL.isFileURL,
           explicitURL.path.hasPrefix("/"),
           FileManager.default.fileExists(atPath: explicitURL.path) {
            return explicitURL
        }
        let localURL = sessionURL.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: localURL.path)
            ? localURL
            : nil
    }

    private static func number(_ value: Any?) -> TimeInterval {
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value) ?? 0
        }
        return 0
    }
}
