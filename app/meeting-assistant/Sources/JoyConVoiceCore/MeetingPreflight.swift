import Foundation

public struct MeetingPreflightReport: Sendable {
    public let actualInputDevice: String
    public let sessionsDirectory: String
    public let availableDiskBytes: Int64?
    public let minimumDiskBytes: Int64

    public init(
        actualInputDevice: String,
        sessionsDirectory: String,
        availableDiskBytes: Int64?,
        minimumDiskBytes: Int64
    ) {
        self.actualInputDevice = actualInputDevice
        self.sessionsDirectory = sessionsDirectory
        self.availableDiskBytes = availableDiskBytes
        self.minimumDiskBytes = minimumDiskBytes
    }
}

public enum MeetingPreflightError: LocalizedError {
    case unexpectedInput(expected: String, actual: String)
    case sessionsDirectoryNotWritable(String)
    case insufficientDisk(availableBytes: Int64, requiredBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedInput(expected, actual):
            return "当前输入设备是“\(actual)”，请先在系统设置 → 声音 → 输入中选择“\(expected)”。"
        case let .sessionsDirectoryNotWritable(path):
            return "录音目录不可写：\(path)"
        case let .insufficientDisk(availableBytes, requiredBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "可用磁盘空间只有 \(formatter.string(fromByteCount: availableBytes))，会议录音至少需要预留 \(formatter.string(fromByteCount: requiredBytes))。"
        }
    }
}

public enum MeetingPreflight {
    public static let defaultMinimumDiskBytes: Int64 = 2_000_000_000

    public static func acceptsInput(actual: String, expected: String?) -> Bool {
        expected == nil || actual == expected
    }

    public static func hasEnoughDisk(
        availableBytes: Int64,
        minimumBytes: Int64 = defaultMinimumDiskBytes
    ) -> Bool {
        availableBytes >= minimumBytes
    }

    public static func inspect(
        sessionsRoot: URL,
        expectedInputDevice: String? = nil,
        minimumDiskBytes: Int64 = defaultMinimumDiskBytes
    ) throws -> MeetingPreflightReport {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: sessionsRoot,
            withIntermediateDirectories: true
        )
        guard fileManager.isWritableFile(atPath: sessionsRoot.path) else {
            throw MeetingPreflightError.sessionsDirectoryNotWritable(sessionsRoot.path)
        }

        let actualInput = try AudioDeviceCatalog.defaultInputName()
        if !acceptsInput(actual: actualInput, expected: expectedInputDevice),
           let expectedInputDevice {
            throw MeetingPreflightError.unexpectedInput(
                expected: expectedInputDevice,
                actual: actualInput
            )
        }

        let values = try? sessionsRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let availableBytes = values?.volumeAvailableCapacityForImportantUsage
        if let availableBytes,
           !hasEnoughDisk(availableBytes: availableBytes, minimumBytes: minimumDiskBytes) {
            throw MeetingPreflightError.insufficientDisk(
                availableBytes: availableBytes,
                requiredBytes: minimumDiskBytes
            )
        }

        return MeetingPreflightReport(
            actualInputDevice: actualInput,
            sessionsDirectory: sessionsRoot.path,
            availableDiskBytes: availableBytes,
            minimumDiskBytes: minimumDiskBytes
        )
    }
}
