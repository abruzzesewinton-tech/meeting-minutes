import Dispatch
import Foundation

public enum MeetingRecorderError: LocalizedError {
    case unexpectedInput(expected: String, actual: String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case let .unexpectedInput(expected, actual):
            return "默认输入设备是“\(actual)”，不是“\(expected)”。会议录音未启动。"
        case .alreadyRunning:
            return "会议录音已经在运行。"
        }
    }
}

public enum MeetingRecorderNotice: Sendable {
    case started(segment: Int, file: String)
    case rotated(segment: Int, file: String)
    case paused
    case resumed(segment: Int, file: String)
    case inputDisconnected(actual: String)
    case inputReconnected(segment: Int, file: String)
    case recorderRecovered(segment: Int, file: String)
    case error(String)
    case stopped(directory: String)
    case discarded(directory: String)
}

public enum MeetingRecorderPolicy {
    public static func hasExpectedInput(actual: String?, expected: String) -> Bool {
        actual == expected
    }

    public static func shouldRotate(
        segmentStartedAt: Date,
        now: Date,
        segmentDurationSeconds: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(segmentStartedAt) >= segmentDurationSeconds
    }
}

public final class SegmentedMeetingRecorder: @unchecked Sendable {
    public let store: MeetingSessionStore

    private let expectedInputDevice: String
    private let segmentDurationSeconds: TimeInterval
    private let noticeHandler: @Sendable (MeetingRecorderNotice) -> Void
    private let audioRecorder: any MeetingAudioRecording
    private let inputNameProvider: @Sendable () throws -> String
    private let monitorQueue = DispatchQueue(label: "joycon.meeting.input-monitor")
    private let lock = NSLock()

    private var timer: DispatchSourceTimer?
    private var currentSegmentIndex: Int?
    private var currentSegmentStartedAt: Date?
    private var inputAvailable = false
    private var running = false
    private var paused = false

    public init(
        store: MeetingSessionStore,
        expectedInputDevice: String,
        segmentDurationSeconds: TimeInterval,
        audioRecorder: any MeetingAudioRecording = ContinuousAudioRecorder(),
        inputNameProvider: @escaping @Sendable () throws -> String = {
            try AudioDeviceCatalog.defaultInputName()
        },
        noticeHandler: @escaping @Sendable (MeetingRecorderNotice) -> Void
    ) {
        self.store = store
        self.expectedInputDevice = expectedInputDevice
        self.segmentDurationSeconds = segmentDurationSeconds
        self.audioRecorder = audioRecorder
        self.inputNameProvider = inputNameProvider
        self.noticeHandler = noticeHandler
    }

    public func start(at now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw MeetingRecorderError.alreadyRunning }

        let actual = (try? inputNameProvider()) ?? "不可用"
        guard MeetingRecorderPolicy.hasExpectedInput(
            actual: actual,
            expected: expectedInputDevice
        ) else {
            try? store.appendEvent("start_blocked_wrong_input", detail: actual, at: now)
            try? store.finalize(status: "start_blocked", at: now)
            throw MeetingRecorderError.unexpectedInput(
                expected: expectedInputDevice,
                actual: actual
            )
        }

        let segment = try startSegmentLocked(at: now)
        inputAvailable = true
        running = true
        paused = false
        try store.appendEvent("recording_started", detail: segment.url.lastPathComponent, at: now)
        startMonitorLocked()
        noticeHandler(.started(segment: segment.index, file: segment.url.lastPathComponent))
    }

    public func pause(at now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard running, !paused else { return }
        if let index = currentSegmentIndex {
            audioRecorder.stop()
            try store.finishSegment(index: index, status: "saved", at: now)
        }
        currentSegmentIndex = nil
        currentSegmentStartedAt = nil
        paused = true
        try store.appendEvent("recording_paused", at: now)
        noticeHandler(.paused)
    }

    public func resume(at now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard running, paused else { return }
        let actual = (try? inputNameProvider()) ?? "不可用"
        guard MeetingRecorderPolicy.hasExpectedInput(
            actual: actual,
            expected: expectedInputDevice
        ) else {
            try? store.appendEvent("resume_blocked_wrong_input", detail: actual, at: now)
            throw MeetingRecorderError.unexpectedInput(
                expected: expectedInputDevice,
                actual: actual
            )
        }
        let segment = try startSegmentLocked(at: now)
        inputAvailable = true
        paused = false
        try store.appendEvent("recording_resumed", detail: segment.url.lastPathComponent, at: now)
        noticeHandler(.resumed(segment: segment.index, file: segment.url.lastPathComponent))
    }

    public func stop(at now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        timer?.cancel()
        timer = nil
        if let index = currentSegmentIndex {
            audioRecorder.stop()
            try store.finishSegment(index: index, status: "saved", at: now)
        }
        currentSegmentIndex = nil
        currentSegmentStartedAt = nil
        running = false
        paused = false
        try store.appendEvent("recording_stopped", at: now)
        try store.finalize(status: "saved", at: now)
        noticeHandler(.stopped(directory: store.directoryURL.path))
    }

    public func prepareForDiscard(at now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        timer?.cancel()
        timer = nil
        if let index = currentSegmentIndex {
            audioRecorder.stop()
            try store.finishSegment(index: index, status: "discarded", at: now)
        }
        currentSegmentIndex = nil
        currentSegmentStartedAt = nil
        running = false
        paused = false
        try store.appendEvent("recording_discarded", at: now)
        try store.finalize(status: "discarded", at: now)
        noticeHandler(.discarded(directory: store.directoryURL.path))
    }

    private func startMonitorLocked() {
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    private func tick(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard running, !paused else { return }

        let actual = try? inputNameProvider()
        let available = MeetingRecorderPolicy.hasExpectedInput(
            actual: actual,
            expected: expectedInputDevice
        )

        if !available {
            guard inputAvailable else { return }
            audioRecorder.stop()
            if let index = currentSegmentIndex {
                try? store.finishSegment(index: index, status: "input_disconnected", at: now)
            }
            currentSegmentIndex = nil
            currentSegmentStartedAt = nil
            inputAvailable = false
            let detail = actual ?? "不可用"
            try? store.appendEvent("input_disconnected", detail: detail, at: now)
            noticeHandler(.inputDisconnected(actual: detail))
            return
        }

        if !inputAvailable {
            do {
                let segment = try startSegmentLocked(at: now)
                inputAvailable = true
                try store.appendEvent("input_reconnected", detail: segment.url.lastPathComponent, at: now)
                noticeHandler(
                    .inputReconnected(
                        segment: segment.index,
                        file: segment.url.lastPathComponent
                    )
                )
            } catch {
                noticeHandler(.error(error.localizedDescription))
            }
            return
        }

        if !audioRecorder.isRecording {
            recoverRecorderLocked(at: now)
            return
        }

        if let startedAt = currentSegmentStartedAt,
           MeetingRecorderPolicy.shouldRotate(
               segmentStartedAt: startedAt,
               now: now,
               segmentDurationSeconds: segmentDurationSeconds
           ) {
            rotateLocked(at: now)
        }
    }

    private func rotateLocked(at now: Date) {
        do {
            if let index = currentSegmentIndex {
                audioRecorder.stop()
                try store.finishSegment(index: index, status: "saved", at: now)
            }
            let segment = try startSegmentLocked(at: now)
            try store.appendEvent("segment_rotated", detail: segment.url.lastPathComponent, at: now)
            noticeHandler(.rotated(segment: segment.index, file: segment.url.lastPathComponent))
        } catch {
            currentSegmentIndex = nil
            currentSegmentStartedAt = nil
            inputAvailable = false
            try? store.appendEvent("segment_rotation_failed", detail: error.localizedDescription, at: now)
            noticeHandler(.error(error.localizedDescription))
        }
    }

    private func recoverRecorderLocked(at now: Date) {
        do {
            if let index = currentSegmentIndex {
                try store.finishSegment(index: index, status: "recorder_stopped", at: now)
            }
            let segment = try startSegmentLocked(at: now)
            try store.appendEvent("recorder_recovered", detail: segment.url.lastPathComponent, at: now)
            noticeHandler(.recorderRecovered(segment: segment.index, file: segment.url.lastPathComponent))
        } catch {
            currentSegmentIndex = nil
            currentSegmentStartedAt = nil
            inputAvailable = false
            try? store.appendEvent("recorder_recovery_failed", detail: error.localizedDescription, at: now)
            noticeHandler(.error(error.localizedDescription))
        }
    }

    private func startSegmentLocked(at now: Date) throws -> (index: Int, url: URL) {
        let segment = try store.beginSegment(at: now)
        do {
            try audioRecorder.start(at: segment.url)
            currentSegmentIndex = segment.index
            currentSegmentStartedAt = now
            return segment
        } catch {
            try? store.finishSegment(index: segment.index, status: "audio_start_failed", at: now)
            throw error
        }
    }
}
