import Foundation
import JoyConVoiceCore

private enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private final class FakeAudioRecorder: MeetingAudioRecording, @unchecked Sendable {
    private(set) var isRecording = false
    private(set) var startedFiles: [String] = []

    func start(at url: URL) throws {
        isRecording = true
        startedFiles.append(url.lastPathComponent)
        try Data("test-audio".utf8).write(to: url)
    }

    func stop() {
        isRecording = false
    }
}

private final class InputState: @unchecked Sendable {
    var name = "MacBook麦克风"
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestError.failed(message) }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "meeting-assistant-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func testCurrentDefaultInputPolicy() throws {
    try require(
        MeetingPreflight.acceptsInput(actual: "MacBook麦克风", expected: nil),
        "未锁定设备时应接受系统默认输入"
    )
    try require(
        MeetingPreflight.acceptsInput(
            actual: "Wireless Mic Rx",
            expected: "Wireless Mic Rx"
        ),
        "锁定设备后应接受同一输入"
    )
    try require(
        !MeetingPreflight.acceptsInput(
            actual: "MacBook麦克风",
            expected: "Wireless Mic Rx"
        ),
        "锁定设备后不应接受其他输入"
    )
}

private func testPauseResumeSegments() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try MeetingSessionStore(
        baseDirectory: root,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        now: start
    )
    let audio = FakeAudioRecorder()
    let recorder = SegmentedMeetingRecorder(
        store: store,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        audioRecorder: audio,
        inputNameProvider: { "MacBook麦克风" },
        noticeHandler: { _ in }
    )

    try recorder.start(at: start)
    try recorder.pause(at: start.addingTimeInterval(10))
    try recorder.resume(at: start.addingTimeInterval(25))
    try recorder.stop(at: start.addingTimeInterval(40))

    let snapshot = store.snapshot()
    try require(snapshot.status == "saved", "停止后会话应安全保存")
    try require(snapshot.segments.count == 2, "暂停继续应形成两个分段")
    try require(
        snapshot.segments.map(\.status) == ["saved", "saved"],
        "两个分段都应保存"
    )
    try require(
        audio.startedFiles == ["audio-0001.wav", "audio-0002.wav"],
        "继续录音应写入新文件"
    )
    try require(
        snapshot.events.map(\.kind) == [
            "recording_started",
            "recording_paused",
            "recording_resumed",
            "recording_stopped",
        ],
        "暂停继续事件链不完整"
    )
}

private func testChangedInputBlocksResume() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try MeetingSessionStore(
        baseDirectory: root,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        now: start
    )
    let audio = FakeAudioRecorder()
    let input = InputState()
    let recorder = SegmentedMeetingRecorder(
        store: store,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        audioRecorder: audio,
        inputNameProvider: { input.name },
        noticeHandler: { _ in }
    )

    try recorder.start(at: start)
    try recorder.pause(at: start.addingTimeInterval(10))
    input.name = "外接麦克风"

    do {
        try recorder.resume(at: start.addingTimeInterval(20))
        throw SelfTestError.failed("输入设备改变后不应继续录音")
    } catch is MeetingRecorderError {
        // Expected.
    }

    let snapshot = store.snapshot()
    try require(snapshot.segments.count == 1, "错误设备不应创建新分段")
    try require(
        snapshot.events.last?.kind == "resume_blocked_wrong_input",
        "应记录继续录音被拦截的原因"
    )
    try require(!audio.isRecording, "拦截后录音器应保持停止")
}

private func testDiscardPreparationStopsAndMarksSession() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try MeetingSessionStore(
        baseDirectory: root,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        now: start
    )
    let audio = FakeAudioRecorder()
    let recorder = SegmentedMeetingRecorder(
        store: store,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        audioRecorder: audio,
        inputNameProvider: { "MacBook麦克风" },
        noticeHandler: { _ in }
    )

    try recorder.start(at: start)
    try recorder.prepareForDiscard(at: start.addingTimeInterval(8))

    let snapshot = store.snapshot()
    try require(snapshot.status == "discarded", "放弃后会话状态应为discarded")
    try require(snapshot.segments.count == 1, "放弃不应创建额外分段")
    try require(snapshot.segments[0].status == "discarded", "当前分段应标记为discarded")
    try require(
        snapshot.events.map(\.kind) == ["recording_started", "recording_discarded"],
        "放弃事件链不完整"
    )
    try require(!audio.isRecording, "放弃前必须先停止录音器")
}

private func testStopOnlySavesWithoutProcessingArtifacts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try MeetingSessionStore(
        baseDirectory: root,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        now: start
    )
    let audio = FakeAudioRecorder()
    let recorder = SegmentedMeetingRecorder(
        store: store,
        expectedInputDevice: "MacBook麦克风",
        segmentDurationSeconds: 600,
        audioRecorder: audio,
        inputNameProvider: { "MacBook麦克风" },
        noticeHandler: { _ in }
    )

    try recorder.start(at: start)
    try recorder.stop(at: start.addingTimeInterval(12))
    try store.saveContext(
        topic: "下一场前先保存",
        participantCount: 2,
        participants: ["甲", "乙"],
        at: start.addingTimeInterval(13)
    )

    let snapshot = store.snapshot()
    try require(snapshot.status == "saved", "只保存后会话状态应为saved")
    try require(snapshot.context?.topic == "下一场前先保存", "只保存应保留会议信息")
    try require(
        !FileManager.default.fileExists(
            atPath: store.directoryURL
                .appendingPathComponent("postprocess.log")
                .path
        ),
        "只保存不应创建转写日志"
    )
    try require(
        !FileManager.default.fileExists(
            atPath: store.directoryURL
                .appendingPathComponent("meeting-package.json")
                .path
        ),
        "只保存不应创建转写包"
    )
}

private func testImportedAudioIsSavedWithoutTranscription() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("source.m4a")
    try Data("fake-audio-for-copy-test".utf8).write(to: sourceURL)
    let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try MeetingSessionStore(
        baseDirectory: sessionsURL,
        expectedInputDevice: "导入录音文件",
        segmentDurationSeconds: 600,
        now: start
    )
    try store.importAudioFile(
        from: sourceURL,
        durationSeconds: 125,
        at: start.addingTimeInterval(1)
    )

    let snapshot = store.snapshot()
    try require(snapshot.status == "saved", "导入录音应保存为待处理会议")
    try require(snapshot.segments.count == 1, "导入录音应形成一个音频分段")
    try require(snapshot.segments[0].file == "audio-0001.m4a", "导入应保留音频扩展名")
    try require(
        FileManager.default.fileExists(
            atPath: store.directoryURL.appendingPathComponent("audio-0001.m4a").path
        ),
        "导入录音应复制到会议目录"
    )
    try require(
        snapshot.events.last?.kind == "audio_imported",
        "导入录音应记录来源事件"
    )
    try require(
        !FileManager.default.fileExists(
            atPath: store.directoryURL.appendingPathComponent("postprocess.log").path
        ),
        "导入录音不应自动启动转写"
    )
}

private func testReadableArtifactDiscoveryAndPreview() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let transcriptURL = root.appendingPathComponent("transcript.txt")
    try Data("第一段转写内容。\\n第二段转写内容。".utf8).write(to: transcriptURL)
    let package: [String: Any] = [
        "transcription": [
            "artifacts": [
                "text": transcriptURL.path,
            ],
        ],
    ]
    let packageData = try JSONSerialization.data(withJSONObject: package)
    try packageData.write(to: root.appendingPathComponent("meeting-package.json"))

    let minutes = """
    # 产品例会｜会议纪要

    ## 基本信息

    - 时间：今天

    ## 会议结论

    讨论了录音保存、历史删除和纪要预览。
    - 下一步：先做轻量版本。

    ## 按人观点与责任边界

    ### 甲

    - 核心观点：先保留录音，再安排转写。

    ### 乙

    - 待办：检查会议记录页面。

    ## 其他

    不应进入摘要。
    """
    try Data(minutes.utf8).write(to: root.appendingPathComponent("会议纪要.md"))

    let result = MeetingReadableArtifactsReader.inspect(sessionURL: root)
    try require(result.transcriptURL == transcriptURL, "应找到转写文本")
    try require(
        result.transcriptPreview?.contains("第一段转写内容") == true,
        "应生成转写预览"
    )
    try require(
        result.minutesTitle == "产品例会｜会议纪要",
        "应读取纪要标题"
    )
    try require(
        result.minutesPreview?.contains("录音保存") == true,
        "应读取会议摘要"
    )
    try require(
        result.minutesPreview?.contains("不应进入摘要") == false,
        "纪要预览不应越过摘要段"
    )
    try require(result.speakerSummaries.count == 2, "应读取两位发言人总结")
    try require(
        result.speakerSummaries[0].speaker == "甲"
            && result.speakerSummaries[0].summary.contains("先保留录音"),
        "按人总结内容不正确"
    )
}

private func testSpeakerTimelineSafetyAndCorrectionOverlay() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let attributionURL = root
        .appendingPathComponent("speaker-attribution/run-1/stage2-user-confirmed")
    try FileManager.default.createDirectory(
        at: attributionURL,
        withIntermediateDirectories: true
    )
    let audioURL = root.appendingPathComponent("audio-0001.wav")
    try Data("audio".utf8).write(to: audioURL)
    let timelineURL = attributionURL
        .appendingPathComponent("speaker-timeline.user-confirmed.json")
    let rows: [[String: Any]] = [
        [
            "id": "seg_0001",
            "start": 1.2,
            "end": 2.4,
            "meeting_start": 11.2,
            "meeting_end": 12.4,
            "speaker": "C01-S01",
            "text": "人工确认的原话",
            "audio_file": "audio-0001.wav",
            "identity_status": "confirmed_person",
            "confirmed_person": "示例发言人乙",
        ],
        [
            "id": "seg_0002",
            "start": 3.0,
            "end": 4.0,
            "meeting_start": 13.0,
            "meeting_end": 14.0,
            "speaker": "C01-S02",
            "text": "只有模型候选的原话",
            "audio_file": "audio-0001.wav",
            "identity_status": "model_candidate",
            "confirmed_person": NSNull(),
            "model_candidate": ["name": "不应展示的姓名"],
        ],
    ]
    let originalData = try JSONSerialization.data(
        withJSONObject: rows,
        options: [.prettyPrinted, .sortedKeys]
    )
    try originalData.write(to: timelineURL)

    let before = MeetingSpeakerTimelineReader.inspect(sessionURL: root)
    try require(before.utterances.count == 2, "应读取两条声线时间线")
    try require(
        before.utterances[0].displaySpeaker == "示例发言人乙",
        "人工确认姓名应显示"
    )
    try require(
        before.utterances[1].displaySpeaker == "未确认发言人 · C01-S02",
        "模型候选姓名不得作为已确认姓名显示"
    )
    try require(
        before.utterances[1].audioStartSeconds == 3,
        "播放原音应使用分段内时间"
    )

    _ = try MeetingSpeakerTimelineReader.saveCorrection(
        sessionURL: root,
        segmentID: "seg_0002",
        originalSpeaker: before.utterances[1].displaySpeaker,
        correctedSpeaker: "示例发言人丙",
        now: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let after = MeetingSpeakerTimelineReader.inspect(sessionURL: root)
    try require(after.hasHumanCorrections, "人工修订后应标记修订层")
    try require(
        after.utterances[1].displaySpeaker == "示例发言人丙",
        "人工修订层应覆盖界面显示"
    )
    let preservedData = try Data(contentsOf: timelineURL)
    try require(
        preservedData == originalData,
        "人工修订不得改写原始声线时间线"
    )
}

let tests: [(String, () throws -> Void)] = [
    ("系统默认输入策略", testCurrentDefaultInputPolicy),
    ("暂停继续安全分段", testPauseResumeSegments),
    ("输入变更拦截", testChangedInputBlocksResume),
    ("放弃录音安全停止", testDiscardPreparationStopsAndMarksSession),
    ("只保存不启动转写", testStopOnlySavesWithoutProcessingArtifacts),
    ("导入录音只保存", testImportedAudioIsSavedWithoutTranscription),
    ("纪要与转写预览", testReadableArtifactDiscoveryAndPreview),
    ("声线证据与人工修订层", testSpeakerTimelineSafetyAndCorrectionOverlay),
]

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
    }
    print("PASS \(tests.count)/\(tests.count)")
} catch {
    FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
    exit(1)
}
