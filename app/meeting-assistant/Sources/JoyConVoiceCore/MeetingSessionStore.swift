import Foundation

public struct MeetingSegmentMetadata: Codable, Equatable, Sendable {
    public let index: Int
    public let file: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: String
    public var bytes: Int64?
}

public struct MeetingEventMetadata: Codable, Equatable, Sendable {
    public let kind: String
    public let occurredAt: Date
    public let detail: String?
}

public struct MeetingContextMetadata: Codable, Equatable, Sendable {
    public let topic: String?
    public let participantCount: Int?
    public let participants: [String]
    public let savedAt: Date

    public init(
        topic: String?,
        participantCount: Int?,
        participants: [String],
        savedAt: Date
    ) {
        self.topic = topic
        self.participantCount = participantCount
        self.participants = participants
        self.savedAt = savedAt
    }
}

public struct MeetingSessionMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let mode: VoiceMode
    public let startedAt: Date
    public var endedAt: Date?
    public var status: String
    public let expectedInputDevice: String
    public let segmentDurationSeconds: TimeInterval
    public var segments: [MeetingSegmentMetadata]
    public var events: [MeetingEventMetadata]
    public var context: MeetingContextMetadata?
}

public final class MeetingSessionStore: @unchecked Sendable {
    public let directoryURL: URL

    private let metadataURL: URL
    private var metadata: MeetingSessionMetadata
    private let encoder: JSONEncoder
    private let lock = NSLock()

    public init(
        baseDirectory: URL,
        expectedInputDevice: String,
        segmentDurationSeconds: TimeInterval,
        now: Date = Date()
    ) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let id = "\(formatter.string(from: now))-meeting"

        directoryURL = baseDirectory.appendingPathComponent(id, isDirectory: true)
        metadataURL = directoryURL.appendingPathComponent("session.json")
        metadata = MeetingSessionMetadata(
            id: id,
            mode: .meeting,
            startedAt: now,
            endedAt: nil,
            status: "preparing",
            expectedInputDevice: expectedInputDevice,
            segmentDurationSeconds: segmentDurationSeconds,
            segments: [],
            events: [],
            context: nil
        )
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try writeMetadataLocked()
    }

    public func beginSegment(at now: Date = Date()) throws -> (index: Int, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let index = metadata.segments.count + 1
        let file = String(format: "audio-%04d.wav", index)
        metadata.status = "recording"
        metadata.segments.append(
            MeetingSegmentMetadata(
                index: index,
                file: file,
                startedAt: now,
                endedAt: nil,
                status: "recording",
                bytes: nil
            )
        )
        try writeMetadataLocked()
        return (index, directoryURL.appendingPathComponent(file))
    }

    public func finishSegment(
        index: Int,
        status: String,
        at now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let offset = metadata.segments.firstIndex(where: { $0.index == index }) else {
            return
        }
        let fileURL = directoryURL.appendingPathComponent(metadata.segments[offset].file)
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        metadata.segments[offset].endedAt = now
        metadata.segments[offset].status = status
        metadata.segments[offset].bytes = (attributes?[.size] as? NSNumber)?.int64Value
        try writeMetadataLocked()
    }

    public func importAudioFile(
        from sourceURL: URL,
        durationSeconds: TimeInterval?,
        at now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        let fileExtension = sourceURL.pathExtension.isEmpty
            ? "audio"
            : sourceURL.pathExtension.lowercased()
        let index = metadata.segments.count + 1
        let file = String(format: "audio-%04d.%@", index, fileExtension)
        let destinationURL = directoryURL.appendingPathComponent(file)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        do {
            let safeDuration = durationSeconds.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            let endedAt = safeDuration.map { metadata.startedAt.addingTimeInterval($0) }
                ?? now
            let attributes = try? fileManager.attributesOfItem(
                atPath: destinationURL.path
            )
            metadata.segments.append(
                MeetingSegmentMetadata(
                    index: index,
                    file: file,
                    startedAt: metadata.startedAt,
                    endedAt: endedAt,
                    status: "saved",
                    bytes: (attributes?[.size] as? NSNumber)?.int64Value
                )
            )
            metadata.events.append(
                MeetingEventMetadata(
                    kind: "audio_imported",
                    occurredAt: now,
                    detail: sourceURL.lastPathComponent
                )
            )
            metadata.endedAt = endedAt
            metadata.status = "saved"
            try writeMetadataLocked()
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    public func appendEvent(
        _ kind: String,
        detail: String? = nil,
        at now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        metadata.events.append(
            MeetingEventMetadata(kind: kind, occurredAt: now, detail: detail)
        )
        try writeMetadataLocked()
    }

    public func finalize(status: String = "saved", at now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        metadata.endedAt = now
        metadata.status = status
        try writeMetadataLocked()
    }

    public func saveContext(
        topic: String?,
        participantCount: Int?,
        participants: [String],
        at now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let cleanTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let cleanParticipants = participants.compactMap { value -> String? in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
        metadata.context = MeetingContextMetadata(
            topic: cleanTopic?.isEmpty == false ? cleanTopic : nil,
            participantCount: participantCount.flatMap { $0 > 0 ? $0 : nil },
            participants: cleanParticipants,
            savedAt: now
        )
        metadata.events.append(
            MeetingEventMetadata(
                kind: "meeting_context_saved",
                occurredAt: now,
                detail: cleanParticipants.isEmpty ? nil : cleanParticipants.joined(separator: "、")
            )
        )
        try writeMetadataLocked()
    }

    public func snapshot() -> MeetingSessionMetadata {
        lock.lock()
        defer { lock.unlock() }
        return metadata
    }

    private func writeMetadataLocked() throws {
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }
}
