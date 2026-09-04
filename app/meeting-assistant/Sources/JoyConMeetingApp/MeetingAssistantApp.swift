import AppKit
import AVFoundation
import Combine
import Foundation
import JoyConVoiceCore
import SwiftUI
import UniformTypeIdentifiers

private enum MeetingAppPhase: Equatable {
    case checking
    case ready
    case recording
    case paused
    case awaitingDetails
    case processing
    case completed
    case failed
}

private enum MeetingProcessingState: Equatable {
    case saved
    case processing
    case incomplete
    case transcribed

    var text: String {
        switch self {
        case .saved: "录音已保存"
        case .processing: "正在转写"
        case .incomplete: "转写未完成"
        case .transcribed: "转写已完成"
        }
    }
}

private enum ProjectLocator {
    static let projectURL: URL = {
        if let configuredPath = Bundle.main.object(
            forInfoDictionaryKey: "JoyConProjectPath"
        ) as? String,
           !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()
}

private struct MeetingAudioSegment: Identifiable, Equatable {
    let id: Int
    let title: String
    let url: URL
    let durationSeconds: TimeInterval?
}

private struct MeetingChoice: Identifiable, Equatable {
    let id: String
    let directoryURL: URL
    let startedAt: Date
    let topic: String?
    let durationSeconds: Int?
    let processingState: MeetingProcessingState
    let inputDevice: String
    let segmentCount: Int
    let participants: [String]
    let readableArtifacts: MeetingReadableArtifacts
    let audioSegments: [MeetingAudioSegment]
    let speakerTimeline: MeetingSpeakerTimeline

    var title: String {
        let cleanTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTopic?.isEmpty == false {
            return cleanTopic!
        }
        if let minutesTitle = readableArtifacts.minutesTitle,
           !minutesTitle.isEmpty {
            return minutesTitle
        }
        return id
    }

    var stateText: String {
        if minutesOutdated {
            return "纪要需更新"
        }
        return readableArtifacts.minutesURL == nil
            ? processingState.text
            : "纪要已生成"
    }

    var hasMinutes: Bool {
        readableArtifacts.minutesURL != nil
    }

    var minutesOutdated: Bool {
        hasMinutes && speakerTimeline.hasHumanCorrections
    }
}

@MainActor
private final class MeetingAppModel: ObservableObject {
    static let segmentDurationSeconds: TimeInterval = 600

    @Published private(set) var phase: MeetingAppPhase = .checking
    @Published private(set) var headline = "正在检查会议环境"
    @Published private(set) var detail = "请稍候…"
    @Published private(set) var currentInput = "正在读取"
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var recordedSeconds = 0
    @Published var isDetailsPresented = false
    @Published var isDiscardConfirmationPresented = false
    @Published var isDeleteConfirmationPresented = false
    @Published private(set) var meetingChoices: [MeetingChoice] = []
    @Published private(set) var lastCopiedMeetingID: String?
    @Published var selectedMeetingID: String?
    @Published var topic = ""
    @Published var participantCount = ""
    @Published var participants = ""

    private let sessionsRoot: URL
    private var recorder: SegmentedMeetingRecorder?
    private var pendingStore: MeetingSessionStore?
    private var lastSavedSessionURL: URL?
    private var elapsedTask: Task<Void, Never>?
    private var recordingActivity: NSObjectProtocol?
    private var processingProcess: Process?
    private var processingLogHandle: FileHandle?
    private var processingStopRequested = false
    private var pendingDeletionMeetingID: String?
    private var meetingStartedAt: Date?
    private var captureStartedAt: Date?
    private var recordedAccumulated: TimeInterval = 0
    private var didRunInitialCheck = false

    init() {
        sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/JoyConVoice/sessions", isDirectory: true)
    }

    var primaryTitle: String {
        switch phase {
        case .checking: "正在检查…"
        case .ready: "开始录音"
        case .recording: "停止并保存"
        case .paused: "停止并保存"
        case .awaitingDetails: "等待填写会议信息"
        case .processing: "正在本地转写…"
        case .completed: "开始下一场会议"
        case .failed: "重新检查"
        }
    }

    var primaryEnabled: Bool {
        switch phase {
        case .ready, .recording, .paused, .completed, .failed: true
        case .checking, .awaitingDetails, .processing: false
        }
    }

    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }
    var isMeetingActive: Bool { phase == .recording || phase == .paused }
    var canDiscardCurrentMeeting: Bool { isMeetingActive || phase == .awaitingDetails }
    var isProcessing: Bool { phase == .processing }
    var canImportAudioFile: Bool {
        !isMeetingActive && phase != .awaitingDetails && processingProcess == nil
    }
    var canStopProcessing: Bool { phase == .processing && processingProcess != nil }
    var canRetryProcessing: Bool {
        guard let lastSavedSessionURL,
              !isMeetingActive,
              phase != .processing
        else { return false }
        return !FileManager.default.fileExists(
            atPath: lastSavedSessionURL
                .appendingPathComponent("meeting-package.json")
                .path
        )
    }
    var retryProcessingTitle: String {
        guard let lastSavedSessionURL else { return "开始本地转写" }
        let logExists = FileManager.default.fileExists(
            atPath: lastSavedSessionURL
                .appendingPathComponent("postprocess.log")
                .path
        )
        return processingStopRequested || logExists
            ? "继续本地转写"
            : "开始本地转写"
    }

    var elapsedText: String {
        formattedDuration(elapsedSeconds)
    }

    var recordedText: String {
        formattedDuration(recordedSeconds)
    }

    private func formattedDuration(_ value: Int) -> String {
        let hours = value / 3_600
        let minutes = (value % 3_600) / 60
        let seconds = value % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func runInitialCheckIfNeeded() {
        guard !didRunInitialCheck else { return }
        didRunInitialCheck = true
        checkReadiness()
    }

    func checkReadiness() {
        phase = .checking
        headline = "正在检查会议环境"
        detail = "确认系统默认麦克风和录音空间。"
        do {
            let report = try MeetingPreflight.inspect(
                sessionsRoot: sessionsRoot,
                expectedInputDevice: nil
            )
            currentInput = report.actualInputDevice
            phase = .ready
            headline = "可以开始会议"
            detail = "将使用 macOS 当前默认输入设备，音频只保存在这台 Mac。"
            refreshMeetingChoices()
        } catch {
            currentInput = (try? AudioDeviceCatalog.defaultInputName()) ?? "不可用"
            phase = .failed
            headline = "暂时不能开始录音"
            detail = error.localizedDescription
        }
    }

    func performPrimaryAction() {
        switch phase {
        case .ready, .completed:
            Task { await startRecording() }
        case .recording:
            stopAndRequestDetails()
        case .paused:
            stopAndRequestDetails()
        case .failed:
            checkReadiness()
        case .checking, .awaitingDetails, .processing:
            break
        }
    }

    func retryProcessing() {
        guard let sessionURL = lastSavedSessionURL else { return }
        launchPostprocessing(for: sessionURL)
    }

    func pauseOrResume() {
        guard let recorder else { return }
        let now = Date()
        do {
            if phase == .recording {
                try recorder.pause(at: now)
                freezeRecordedClock(at: now)
                phase = .paused
                headline = "会议录音已暂停"
                detail = "暂停期间不会写入音频；点“继续录音”会开始新分段。"
            } else if phase == .paused {
                try recorder.resume(at: now)
                captureStartedAt = now
                phase = .recording
                headline = "会议录音中"
                detail = "已从新分段继续录音。"
            }
        } catch {
            headline = "录音状态没有切换"
            detail = error.localizedDescription
            NSSound.beep()
        }
    }

    func requestDiscardCurrentMeeting() {
        guard canDiscardCurrentMeeting else { return }
        isDiscardConfirmationPresented = true
    }

    func discardCurrentMeeting() {
        let now = Date()
        let sessionURL: URL
        do {
            if isMeetingActive, let recorder {
                sessionURL = recorder.store.directoryURL
                freezeRecordedClock(at: now)
                try recorder.prepareForDiscard(at: now)
                self.recorder = nil
                stopRecordingActivity()
            } else if phase == .awaitingDetails, let store = pendingStore {
                sessionURL = store.directoryURL
                try store.appendEvent("recording_discarded", at: now)
                try store.finalize(status: "discarded", at: now)
                isDetailsPresented = false
            } else {
                return
            }
            try FileManager.default.trashItem(at: sessionURL, resultingItemURL: nil)
            pendingStore = nil
            if lastSavedSessionURL == sessionURL {
                lastSavedSessionURL = nil
            }
            meetingStartedAt = nil
            captureStartedAt = nil
            elapsedSeconds = 0
            recordedSeconds = 0
            recordedAccumulated = 0
            phase = .ready
            headline = "本次录音已放弃"
            detail = "录音已移到废纸篓，没有启动本地转写。"
            refreshMeetingChoices()
        } catch {
            self.recorder = nil
            pendingStore = nil
            isDetailsPresented = false
            stopRecordingActivity()
            meetingStartedAt = nil
            captureStartedAt = nil
            phase = .failed
            headline = "录音已停止，但未能移到废纸篓"
            detail = "本次会话不会自动转写。文件仍在：\(sessionURL.path)。\(error.localizedDescription)"
        }
    }

    func stopProcessing() {
        guard let process = processingProcess, process.isRunning else { return }
        processingStopRequested = true
        let childTerminator = Process()
        childTerminator.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        childTerminator.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? childTerminator.run()
        childTerminator.waitUntilExit()
        process.terminate()
        headline = "正在停止本地转写"
        detail = "已完成的音频分段缓存会保留。"
    }

    func refreshHistory() {
        refreshMeetingChoices()
        if selectedMeetingID == nil {
            selectedMeetingID = meetingChoices.first?.id
        }
    }

    func selectMeeting(_ choice: MeetingChoice) {
        selectedMeetingID = choice.id
    }

    func canStartProcessing(_ choice: MeetingChoice) -> Bool {
        !isMeetingActive
            && phase != .awaitingDetails
            && processingProcess == nil
            && choice.processingState != .transcribed
    }

    func startProcessing(_ choice: MeetingChoice) {
        guard canStartProcessing(choice) else {
            headline = "现在不能开始转写"
            detail = processingProcess == nil
                ? "请先保存当前会议。"
                : "已有一场会议正在转写，请等待或先停止它。"
            return
        }
        lastSavedSessionURL = choice.directoryURL
        launchPostprocessing(for: choice.directoryURL)
    }

    func copyCodexPrompt(for choice: MeetingChoice) {
        let sessionURL = choice.directoryURL
        let sessionID = sessionURL.lastPathComponent
        let packageURL = sessionURL.appendingPathComponent("meeting-package.json")
        let sourceURL = FileManager.default.fileExists(atPath: packageURL.path)
            ? packageURL
            : sessionURL
        let correctionURL = sessionURL.appendingPathComponent(
            MeetingSpeakerTimelineReader.correctionsRelativePath
        )
        let correctionInstruction = choice.speakerTimeline.hasHumanCorrections
            ? "优先应用人工修订层 \(correctionURL.path)，重新生成候选纪要；不要覆盖原始转写和原始声线证据。"
            : "未确认说话人不署名。"
        let prompt = """
        整理会议 \(sessionID)。读取本地会议资料 \(sourceURL.path)，按会议纪要标准流程处理；原始音频不上传。\(correctionInstruction)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        headline = "Codex提示词已复制"
        detail = "已精确绑定会议 \(sessionID)。"
        lastCopiedMeetingID = choice.id
    }

    func copySpeakerSummaryPrompt(for choice: MeetingChoice) {
        let sessionURL = choice.directoryURL
        let sessionID = sessionURL.lastPathComponent
        let correctionURL = sessionURL.appendingPathComponent(
            MeetingSpeakerTimelineReader.correctionsRelativePath
        )
        let correctionInstruction = choice.speakerTimeline.hasHumanCorrections
            ? "必须先应用人工修订层 \(correctionURL.path)。"
            : ""
        let prompt = """
        为会议 \(sessionID) 补充按发言人总结。读取 \(sessionURL.path) 中的原始转写、人工确认说话人时间线和现有会议纪要；\(correctionInstruction)在会议纪要中新增或更新“## 按人观点与责任边界”，每位已确认发言人使用“### 姓名”，只总结其核心观点、决定、异议和待办。未确认发言不得归入任何姓名，不上传原始音频，不改写原始转写和声线证据。
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        headline = "按人总结提示词已复制"
        detail = "已精确绑定会议 \(sessionID)。"
        lastCopiedMeetingID = choice.id
    }

    func saveSpeakerCorrection(
        for choice: MeetingChoice,
        utterance: MeetingSpeakerUtterance,
        correctedSpeaker: String
    ) throws {
        try MeetingSpeakerTimelineReader.saveCorrection(
            sessionURL: choice.directoryURL,
            segmentID: utterance.id,
            originalSpeaker: utterance.displaySpeaker,
            correctedSpeaker: correctedSpeaker
        )
        refreshMeetingChoices()
        selectedMeetingID = choice.id
        headline = "说话人修订已保存"
        detail = choice.hasMinutes
            ? "原纪要仍保留，并已标记为需要重新生成。"
            : "原始声线时间线没有被修改。"
    }

    func openMeetingFolder(_ choice: MeetingChoice) {
        NSWorkspace.shared.open(choice.directoryURL)
    }

    func openTranscript(_ choice: MeetingChoice) {
        guard let transcriptURL = choice.readableArtifacts.transcriptURL else {
            headline = "还没有可打开的转写文本"
            detail = "可以先开始本地转写。"
            return
        }
        NSWorkspace.shared.open(transcriptURL)
    }

    func openMinutes(_ choice: MeetingChoice) {
        guard let minutesURL = choice.readableArtifacts.minutesURL else {
            headline = "还没有会议纪要"
            detail = "转写完成后，可复制提示词交给 Codex 整理。"
            return
        }
        NSWorkspace.shared.open(minutesURL)
    }

    func openMinutesPDF(_ choice: MeetingChoice) {
        guard let pdfURL = choice.readableArtifacts.minutesPDFURL else { return }
        NSWorkspace.shared.open(pdfURL)
    }

    func requestDeleteMeeting(_ choice: MeetingChoice) {
        guard !isMeetingActive,
              !(processingProcess != nil && lastSavedSessionURL == choice.directoryURL)
        else {
            headline = "这场会议暂时不能删除"
            detail = "请先停止当前录音或转写。"
            return
        }
        pendingDeletionMeetingID = choice.id
        isDeleteConfirmationPresented = true
    }

    func deletePendingMeeting() {
        guard let pendingDeletionMeetingID,
              let choice = meetingChoices.first(where: {
                  $0.id == pendingDeletionMeetingID
              })
        else {
            isDeleteConfirmationPresented = false
            self.pendingDeletionMeetingID = nil
            return
        }
        do {
            try FileManager.default.trashItem(
                at: choice.directoryURL,
                resultingItemURL: nil
            )
            if lastSavedSessionURL == choice.directoryURL {
                lastSavedSessionURL = nil
            }
            self.pendingDeletionMeetingID = nil
            isDeleteConfirmationPresented = false
            if selectedMeetingID == choice.id {
                selectedMeetingID = nil
            }
            refreshHistory()
            headline = "会议已移到废纸篓"
            detail = "录音、转写和该目录内的纪要都可从废纸篓恢复。"
        } catch {
            self.pendingDeletionMeetingID = nil
            isDeleteConfirmationPresented = false
            headline = "会议没有删除"
            detail = error.localizedDescription
        }
    }

    var pendingDeletionTitle: String {
        guard let pendingDeletionMeetingID,
              let choice = meetingChoices.first(where: {
                  $0.id == pendingDeletionMeetingID
              })
        else { return "这场会议" }
        return choice.title
    }

    func saveDetailsAndProcess() {
        finishDetails(saveEnteredValues: true, beginProcessing: true)
    }

    func saveDetailsOnly() {
        finishDetails(saveEnteredValues: true, beginProcessing: false)
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(
            at: sessionsRoot,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(sessionsRoot)
    }

    func importAudioFile() {
        guard !isMeetingActive,
              phase != .awaitingDetails,
              processingProcess == nil
        else {
            headline = "现在不能导入录音"
            detail = "请先保存当前会议，或等待正在进行的转写结束。"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "导入会议录音"
        panel.message = "录音只复制到本机会议目录；导入后不会自动转写。"
        panel.prompt = "导入录音"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                guard durationSeconds.isFinite, durationSeconds > 0 else {
                    throw NSError(
                        domain: "MeetingAssistant.Import",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "无法读取这份录音的有效时长。"]
                    )
                }

                let store = try MeetingSessionStore(
                    baseDirectory: sessionsRoot,
                    expectedInputDevice: "导入录音文件",
                    segmentDurationSeconds: Self.segmentDurationSeconds
                )
                try store.importAudioFile(
                    from: sourceURL,
                    durationSeconds: durationSeconds
                )
                try store.saveContext(
                    topic: sourceURL.deletingPathExtension().lastPathComponent,
                    participantCount: nil,
                    participants: []
                )
                lastSavedSessionURL = store.directoryURL
                phase = .completed
                headline = "录音已导入"
                detail = "已保存到本机会议记录，尚未开始转写。"
                refreshHistory()
                selectedMeetingID = store.directoryURL.lastPathComponent
            } catch {
                phase = .failed
                headline = "录音没有导入"
                detail = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    func prepareForTermination() {
        if isMeetingActive, let recorder {
            let store = recorder.store
            do {
                freezeRecordedClock(at: Date())
                try recorder.stop()
                lastSavedSessionURL = store.directoryURL
                try? store.saveContext(
                    topic: nil,
                    participantCount: nil,
                    participants: []
                )
            } catch {
                try? store.finalize(status: "saved_on_exit")
            }
            self.recorder = nil
            stopRecordingActivity()
        } else if phase == .awaitingDetails, let store = pendingStore {
            try? store.saveContext(
                topic: topic,
                participantCount: parsedParticipantCount,
                participants: parsedParticipants
            )
            lastSavedSessionURL = store.directoryURL
            pendingStore = nil
        }
    }

    private func startRecording() async {
        phase = .checking
        headline = "正在准备麦克风"
        detail = "首次使用时，macOS 会询问麦克风权限。"

        guard await ensureMicrophonePermission() else {
            phase = .failed
            headline = "没有麦克风权限"
            detail = "请在系统设置 → 隐私与安全性 → 麦克风中允许“会议助手”。"
            return
        }

        do {
            let report = try MeetingPreflight.inspect(
                sessionsRoot: sessionsRoot,
                expectedInputDevice: nil
            )
            currentInput = report.actualInputDevice
            let store = try MeetingSessionStore(
                baseDirectory: sessionsRoot,
                expectedInputDevice: report.actualInputDevice,
                segmentDurationSeconds: Self.segmentDurationSeconds
            )
            let newRecorder = SegmentedMeetingRecorder(
                store: store,
                expectedInputDevice: report.actualInputDevice,
                segmentDurationSeconds: Self.segmentDurationSeconds
            ) { [weak self] notice in
                Task { @MainActor [weak self] in
                    self?.handleRecorderNotice(notice)
                }
            }
            try newRecorder.start()
            recorder = newRecorder
            pendingStore = nil
            elapsedSeconds = 0
            recordedSeconds = 0
            recordedAccumulated = 0
            meetingStartedAt = Date()
            captureStartedAt = meetingStartedAt
            topic = ""
            participantCount = ""
            participants = ""
            phase = .recording
            headline = "会议录音中"
            detail = "结束时点“停止并保存”，原始音频会先安全落盘。"
            startRecordingActivity()
            startElapsedTimer()
        } catch {
            phase = .failed
            headline = "录音没有开始"
            detail = error.localizedDescription
        }
    }

    private func stopAndRequestDetails() {
        guard let recorder else { return }
        let store = recorder.store
        do {
            freezeRecordedClock(at: Date())
            try recorder.stop()
            self.recorder = nil
            stopRecordingActivity()
            pendingStore = store
            lastSavedSessionURL = store.directoryURL
            phase = .awaitingDetails
            headline = "录音已安全保存"
            detail = "可以只保存并立刻开始下一场，也可以现在转写。"
            isDetailsPresented = true
        } catch {
            self.recorder = nil
            stopRecordingActivity()
            lastSavedSessionURL = store.directoryURL
            phase = .failed
            headline = "停止录音时出现异常"
            detail = "请先不要删除录音目录：\(error.localizedDescription)"
        }
    }

    private func finishDetails(
        saveEnteredValues: Bool,
        beginProcessing: Bool
    ) {
        guard let store = pendingStore else {
            isDetailsPresented = false
            return
        }
        do {
            try store.saveContext(
                topic: saveEnteredValues ? topic : nil,
                participantCount: saveEnteredValues ? parsedParticipantCount : nil,
                participants: saveEnteredValues ? parsedParticipants : []
            )
            pendingStore = nil
            isDetailsPresented = false
            lastSavedSessionURL = store.directoryURL
            meetingStartedAt = nil
            captureStartedAt = nil
            elapsedSeconds = 0
            recordedSeconds = 0
            recordedAccumulated = 0
            if beginProcessing {
                launchPostprocessing(for: store.directoryURL)
            } else {
                phase = .ready
                headline = "录音已保存，等待转写"
                detail = "可以马上开始下一场；以后从历史记录中开始转写。"
                refreshMeetingChoices()
                selectedMeetingID = store.directoryURL.lastPathComponent
            }
        } catch {
            headline = "会议信息没有保存"
            detail = error.localizedDescription
        }
    }

    private var parsedParticipantCount: Int? {
        let value = participantCount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(value), count > 0 else { return nil }
        return count
    }

    private var parsedParticipants: [String] {
        let separators = CharacterSet(charactersIn: ",，、;；\n")
        var seen = Set<String>()
        return participants
            .components(separatedBy: separators)
            .compactMap { item -> String? in
                let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { return nil }
                return name
            }
    }

    private func launchPostprocessing(for sessionURL: URL) {
        let scriptURL = ProjectLocator.projectURL.appendingPathComponent("整理最近会议.command")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            phase = .failed
            headline = "录音已保存，自动整理未启动"
            detail = "找不到本地整理程序。录音仍在原目录中。"
            return
        }

        let logURL = sessionURL.appendingPathComponent("postprocess.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        do {
            processingStopRequested = false
            let logHandle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, sessionURL.path, "--no-pause"]
            process.currentDirectoryURL = ProjectLocator.projectURL
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] finishedProcess in
                let status = finishedProcess.terminationStatus
                Task { @MainActor [weak self] in
                    self?.postprocessingFinished(status: status)
                }
            }
            try process.run()
            processingProcess = process
            processingLogHandle = logHandle
            lastSavedSessionURL = sessionURL
            phase = .processing
            headline = "录音已保存，正在本地转写"
            detail = "可以继续使用 Mac；处理完成后会收到通知。"
            refreshMeetingChoices()
        } catch {
            processingLogHandle?.closeFile()
            processingLogHandle = nil
            phase = .failed
            headline = "录音已保存，自动整理未启动"
            detail = error.localizedDescription
        }
    }

    private func postprocessingFinished(status: Int32) {
        processingLogHandle?.closeFile()
        processingLogHandle = nil
        processingProcess = nil
        if processingStopRequested {
            phase = .failed
            headline = "本地转写已停止"
            detail = "缓存已保留，点“继续本地转写”可接着处理。"
        } else if status == 0 {
            phase = .completed
            headline = "这次会议已经准备好"
            detail = "可复制一条已绑定本次会议的提示词，交给 Codex 整理。"
        } else {
            phase = .failed
            headline = "录音已保存，本地转写未完成"
            detail = "可以点“重试本地整理”；已完成的分段会自动复用。"
        }
        refreshMeetingChoices()
    }

    private func handleRecorderNotice(_ notice: MeetingRecorderNotice) {
        switch notice {
        case .paused:
            break
        case .resumed:
            break
        case .inputDisconnected:
            headline = "麦克风暂时断开"
            detail = "录音会话仍保留；接收器恢复后会自动开始新分段。"
            NSSound.beep()
        case .inputReconnected:
            headline = "麦克风已恢复，继续录音"
            detail = "断开前后的音频会保存在不同分段中。"
        case .recorderRecovered:
            headline = "录音器已自动恢复"
            detail = "会议仍在继续，新音频已写入下一分段。"
        case let .error(message):
            headline = "录音出现异常"
            detail = message
            NSSound.beep()
        case .started, .rotated, .stopped, .discarded:
            break
        }
    }

    private func refreshMeetingChoices() {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        meetingChoices = Array(urls.compactMap { directoryURL -> MeetingChoice? in
            guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            let metadataURL = directoryURL.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? decoder.decode(MeetingSessionMetadata.self, from: data),
                  metadata.status != "discarded",
                  metadata.status != "recording",
                  metadata.status != "preparing"
            else { return nil }

            let packageExists = fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent("meeting-package.json").path
            )
            let logExists = fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent("postprocess.log").path
            )
            let processingState: MeetingProcessingState
            if packageExists {
                processingState = .transcribed
            } else if phase == .processing, lastSavedSessionURL == directoryURL {
                processingState = .processing
            } else if logExists {
                processingState = .incomplete
            } else {
                processingState = .saved
            }
            let duration = metadata.endedAt.map {
                max(0, Int($0.timeIntervalSince(metadata.startedAt)))
            }
            let readableArtifacts = MeetingReadableArtifactsReader.inspect(
                sessionURL: directoryURL
            )
            let audioSegments = metadata.segments.compactMap {
                segment -> MeetingAudioSegment? in
                let url = directoryURL.appendingPathComponent(segment.file)
                guard fileManager.fileExists(atPath: url.path) else {
                    return nil
                }
                let duration = segment.endedAt.map {
                    max(0, $0.timeIntervalSince(segment.startedAt))
                }
                return MeetingAudioSegment(
                    id: segment.index,
                    title: "录音 \(segment.index)",
                    url: url,
                    durationSeconds: duration
                )
            }
            let speakerTimeline = MeetingSpeakerTimelineReader.inspect(
                sessionURL: directoryURL
            )
            return MeetingChoice(
                id: metadata.id,
                directoryURL: directoryURL,
                startedAt: metadata.startedAt,
                topic: metadata.context?.topic,
                durationSeconds: duration,
                processingState: processingState,
                inputDevice: metadata.expectedInputDevice,
                segmentCount: metadata.segments.count,
                participants: metadata.context?.participants ?? [],
                readableArtifacts: readableArtifacts,
                audioSegments: audioSegments,
                speakerTimeline: speakerTimeline
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
        .prefix(50))
        if let selectedMeetingID,
           !meetingChoices.contains(where: { $0.id == selectedMeetingID }) {
            self.selectedMeetingID = meetingChoices.first?.id
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let now = Date()
                if let meetingStartedAt {
                    elapsedSeconds = max(0, Int(now.timeIntervalSince(meetingStartedAt)))
                }
                let active = captureStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
                recordedSeconds = max(0, Int(recordedAccumulated + active))
            }
        }
    }

    private func freezeRecordedClock(at now: Date) {
        if let captureStartedAt {
            recordedAccumulated += max(0, now.timeIntervalSince(captureStartedAt))
            self.captureStartedAt = nil
        }
        recordedSeconds = max(0, Int(recordedAccumulated))
    }

    private func startRecordingActivity() {
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [
                .idleSystemSleepDisabled,
                .automaticTerminationDisabled,
                .suddenTerminationDisabled,
            ],
            reason: "会议录音正在进行"
        )
    }

    private func stopRecordingActivity() {
        elapsedTask?.cancel()
        elapsedTask = nil
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
    }
}

@MainActor
private final class MeetingAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MeetingAppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.prepareForTermination()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sender.activate(ignoringOtherApps: true)
        sender.windows.first(where: { $0.title == "会议助手" })?.makeKeyAndOrderFront(nil)
        return true
    }
}

private struct MeetingAssistantView: View {
    @ObservedObject var model: MeetingAppModel
    @State private var isExpanded = false
    @State private var hostWindow: NSWindow?

    var body: some View {
        Group {
            if isExpanded {
                expandedView
                    .frame(minWidth: 780, minHeight: 560)
            } else {
                MeetingCompactView(model: model) {
                    setExpanded(true)
                }
                .frame(minWidth: 390, minHeight: 335)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            MeetingWindowReader { window in
                guard hostWindow !== window else { return }
                guard MeetingWindowCoordinator.shared.register(window) else {
                    return
                }
                hostWindow = window
                configureWindow(window, expanded: isExpanded, animated: false)
            }
        }
        .task {
            model.runInitialCheckIfNeeded()
            model.refreshHistory()
        }
        .sheet(isPresented: $model.isDetailsPresented) {
            MeetingDetailsView(model: model)
        }
        .alert(
            "放弃这次录音？",
            isPresented: $model.isDiscardConfirmationPresented
        ) {
            Button("取消", role: .cancel) {}
            Button("放弃并移到废纸篓", role: .destructive) {
                model.discardCurrentMeeting()
            }
        } message: {
            Text("这次录音不会转写。文件会移到废纸篓，仍可从废纸篓恢复。")
        }
        .confirmationDialog(
            "删除“\(model.pendingDeletionTitle)”？",
            isPresented: $model.isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) {
                model.deletePendingMeeting()
            }
        } message: {
            Text("这场会议目录中的录音、转写和已有纪要会一起移到废纸篓，之后仍可恢复。")
        }
    }

    private var expandedView: some View {
        MeetingHistorySection(model: model) {
            setExpanded(false)
        }
        .frame(maxHeight: .infinity)
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if let hostWindow {
            configureWindow(hostWindow, expanded: expanded, animated: false)
        }
    }

    private func configureWindow(
        _ window: NSWindow,
        expanded: Bool,
        animated: Bool
    ) {
        window.styleMask.insert(.resizable)
        let size = expanded
            ? NSSize(width: 1040, height: 760)
            : NSSize(width: 390, height: 335)
        window.minSize = expanded
            ? NSSize(width: 780, height: 560)
            : NSSize(width: 390, height: 335)
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: size)
        ).size
        let targetFrame = NSRect(
            x: window.frame.minX,
            y: window.frame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        window.setFrame(targetFrame, display: true, animate: animated)
    }
}

@MainActor
private final class MeetingWindowCoordinator {
    static let shared = MeetingWindowCoordinator()

    private weak var primaryWindow: NSWindow?

    func register(_ window: NSWindow) -> Bool {
        if let primaryWindow,
           primaryWindow !== window,
           primaryWindow.isVisible {
            window.close()
            primaryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        primaryWindow = window
        return true
    }
}

private struct MeetingWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindow(window)
            }
        }
    }
}

private struct MeetingCompactView: View {
    @ObservedObject var model: MeetingAppModel
    let expand: () -> Void

    private var statusColor: Color {
        if model.isRecording { return .red }
        if model.isPaused { return .orange }
        return .accentColor
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 82, height: 82)
                    Image(
                        systemName: model.isRecording
                            ? "waveform"
                            : (model.isPaused ? "pause.fill" : "mic.fill")
                    )
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(statusColor)
                }
                .padding(.top, 18)

                Text(model.headline)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .padding(.top, 14)

                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 320)
                    .padding(.top, 6)

                Label(
                    model.isMeetingActive
                        ? "会议 \(model.elapsedText) · 实录 \(model.recordedText)"
                        : "输入：\(model.currentInput)",
                    systemImage: model.isMeetingActive ? "clock" : "mic"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)

                Group {
                    if model.isMeetingActive {
                        HStack(spacing: 16) {
                            PlayerControlButton(
                                title: model.isPaused ? "继续" : "暂停",
                                icon: model.isPaused ? "play.fill" : "pause.fill",
                                color: model.isPaused ? .green : .orange,
                                prominent: true
                            ) {
                                model.pauseOrResume()
                            }
                            PlayerControlButton(
                                title: "保存",
                                icon: "stop.fill",
                                color: .accentColor
                            ) {
                                model.performPrimaryAction()
                            }
                            PlayerControlButton(
                                title: "放弃",
                                icon: "trash",
                                color: .red
                            ) {
                                model.requestDiscardCurrentMeeting()
                            }
                        }
                    } else {
                        Button(model.primaryTitle) {
                            model.performPrimaryAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!model.primaryEnabled)
                    }
                }
                .frame(height: 62)
                .padding(.top, 8)

                Spacer(minLength: 4)

                HStack {
                    Button("打开录音文件夹") {
                        model.openRecordingsFolder()
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("重新检查") {
                        model.checkReadiness()
                    }
                    .buttonStyle(.link)
                    .disabled(model.isMeetingActive)
                }
                .font(.caption)

                Text("使用系统默认输入 · 原始音频留存 · 本地离线转写")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }

            Button(action: expand) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("展开更多功能：历史记录、导入录音与会议详情")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

private struct MeetingStatusSection: View {
    @ObservedObject var model: MeetingAppModel

    private var statusColor: Color {
        if model.isRecording { return .red }
        if model.isPaused { return .orange }
        return .accentColor
    }

    private var statusIcon: String {
        if model.isRecording { return "waveform.circle.fill" }
        if model.isPaused { return "pause.circle.fill" }
        return "mic.fill"
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        LinearGradient(
                            colors: [
                                statusColor.opacity(0.2),
                                statusColor.opacity(0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 82, height: 82)
                Image(systemName: statusIcon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(model.isRecording ? Color.red : Color.secondary)
                    .frame(width: 12, height: 12)
                    .overlay {
                        Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 3)
                    }
                    .padding(7)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("当前会议")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.headline)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 14) {
                    Label(model.currentInput, systemImage: "mic")
                        .lineLimit(1)
                    if model.isMeetingActive {
                        Label("会议 \(model.elapsedText)", systemImage: "clock")
                        Label("实录 \(model.recordedText)", systemImage: "waveform")
                            .foregroundStyle(statusColor)
                    } else {
                        Label("音频仅保存在本机", systemImage: "lock.shield")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                if model.isMeetingActive {
                    HStack(alignment: .top, spacing: 14) {
                        PlayerControlButton(
                            title: model.isPaused ? "继续" : "暂停",
                            icon: model.isPaused ? "play.fill" : "pause.fill",
                            color: model.isPaused ? .green : .orange,
                            prominent: true
                        ) {
                            model.pauseOrResume()
                        }
                        PlayerControlButton(
                            title: "保存",
                            icon: "stop.fill",
                            color: .accentColor
                        ) {
                            model.performPrimaryAction()
                        }
                        PlayerControlButton(
                            title: "放弃",
                            icon: "trash",
                            color: .red
                        ) {
                            model.requestDiscardCurrentMeeting()
                        }
                    }
                } else {
                    Button {
                        model.performPrimaryAction()
                    } label: {
                        Label(model.primaryTitle, systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.primaryEnabled)
                }

                if model.canStopProcessing {
                    Button("停止转写并保留缓存") {
                        model.stopProcessing()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                } else if model.canRetryProcessing {
                    Button(model.retryProcessingTitle) {
                        model.retryProcessing()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 225)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.16))
        }
    }
}

private struct PlayerControlButton: View {
    let title: String
    let icon: String
    let color: Color
    var prominent = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: prominent ? 17 : 14, weight: .semibold))
                    .frame(
                        width: prominent ? 42 : 36,
                        height: prominent ? 42 : 36
                    )
                    .foregroundStyle(prominent ? Color.white : color)
                    .background(
                        prominent ? color : color.opacity(0.12),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help(title)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MeetingDetailsView: View {
    @ObservedObject var model: MeetingAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("补充会议信息")
                    .font(.title2.weight(.semibold))
                Text("都可以留空。信息会随本次录音保存，帮助后续区分说话人。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("主要主题内容", text: $model.topic, prompt: Text("例如：产品周例会"))

                TextField("参与会议人数", text: $model.participantCount, prompt: Text("例如：6"))
                    .onChange(of: model.participantCount) { value in
                        model.participantCount = String(value.filter(\.isNumber).prefix(3))
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text("参与人")
                    TextEditor(text: $model.participants)
                        .font(.body)
                        .frame(height: 92)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25))
                        }
                    Text("可用换行、逗号或顿号分隔；新名字会进入待声纹确认清单。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("放弃录音（不转写）", role: .destructive) {
                    model.requestDiscardCurrentMeeting()
                }
                Spacer()
                Button("保存并转写") {
                    model.saveDetailsAndProcess()
                }
                Spacer()
                Button("只保存，稍后转写") {
                    model.saveDetailsOnly()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .alert(
            "放弃这次录音？",
            isPresented: $model.isDiscardConfirmationPresented
        ) {
            Button("取消", role: .cancel) {}
            Button("放弃并移到废纸篓", role: .destructive) {
                model.discardCurrentMeeting()
            }
        } message: {
            Text("这次录音不会转写。文件会移到废纸篓，仍可从废纸篓恢复。")
        }
    }
}

private enum MeetingHistoryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case transcribed = "已转写"
    case pending = "待处理"

    var id: Self { self }
}

private struct MeetingExpandedRecordingBar: View {
    @ObservedObject var model: MeetingAppModel

    private var statusColor: Color {
        if model.isRecording { return .red }
        if model.isPaused { return .orange }
        return .accentColor
    }

    private var statusIcon: String {
        if model.isRecording { return "waveform" }
        if model.isPaused { return "pause.fill" }
        return "mic.fill"
    }

    var body: some View {
        Group {
            if model.isMeetingActive {
                HStack(spacing: 8) {
                    Button {
                        model.pauseOrResume()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: statusIcon)
                                .font(.system(size: 15, weight: .semibold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.headline)
                                    .font(.callout.weight(.semibold))
                                Text("会议 \(model.elapsedText) · 实录 \(model.recordedText)")
                                    .font(.caption2)
                                    .opacity(0.82)
                            }
                            Spacer()
                            Label(
                                model.isPaused ? "继续录音" : "暂停录音",
                                systemImage: model.isPaused ? "play.fill" : "pause.fill"
                            )
                            .font(.callout.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(statusColor)
                        .background(
                            statusColor.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.performPrimaryAction()
                    } label: {
                        Label("停止并保存", systemImage: "stop.fill")
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    model.performPrimaryAction()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 32, height: 32)
                            Image(systemName: statusIcon)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.headline)
                                .font(.callout.weight(.semibold))
                            Text("输入：\(model.currentInput)")
                                .font(.caption2)
                                .opacity(0.82)
                        }
                        Spacer()
                        Label(model.primaryTitle, systemImage: "record.circle")
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.primaryEnabled)
                .help(model.primaryTitle)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MeetingHistorySection: View {
    @ObservedObject var model: MeetingAppModel
    let collapse: (() -> Void)?
    @State private var searchText = ""
    @State private var filter: MeetingHistoryFilter = .all
    @State private var meetingListWidth: CGFloat = 390
    @State private var splitDragStartWidth: CGFloat?

    init(
        model: MeetingAppModel,
        collapse: (() -> Void)? = nil
    ) {
        self.model = model
        self.collapse = collapse
    }

    private func durationText(_ seconds: Int?) -> String {
        guard let seconds else { return "时长未知" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return "\(hours)小时\(minutes)分钟"
        }
        if minutes > 0 {
            return "\(minutes)分钟"
        }
        return "\(seconds)秒"
    }

    private var filteredChoices: [MeetingChoice] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return model.meetingChoices.filter { choice in
            let filterMatches: Bool
            switch filter {
            case .all:
                filterMatches = true
            case .transcribed:
                filterMatches = choice.processingState == .transcribed
            case .pending:
                filterMatches = choice.processingState != .transcribed
            }
            guard filterMatches else { return false }
            guard !query.isEmpty else { return true }
            let searchable = (
                [choice.title, choice.id] + choice.participants
            ).joined(separator: " ").lowercased()
            return searchable.contains(query)
        }
    }

    private var selectedChoice: MeetingChoice? {
        if let selectedMeetingID = model.selectedMeetingID,
           let selected = filteredChoices.first(where: { $0.id == selectedMeetingID }) {
            return selected
        }
        return filteredChoices.first
    }

    private func clampedListWidth(_ proposed: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let maximum = max(280, min(640, totalWidth - 430))
        return min(max(280, proposed), maximum)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MeetingExpandedRecordingBar(model: model)

                Button {
                    model.refreshHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 30, height: 30)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.borderless)
                .help("刷新会议记录")
                if let collapse {
                    Button(action: collapse) {
                        Image(systemName: "rectangle.compress.vertical")
                            .frame(width: 30, height: 30)
                            .background(
                                Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.borderless)
                    .help("收起为录音小窗口")
                }
            }

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                    VStack(spacing: 8) {
                        TextField("搜索主题、参与人或会议编号", text: $searchText)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Picker("筛选", selection: $filter) {
                                ForEach(MeetingHistoryFilter.allCases) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            Text("\(filteredChoices.count) 场")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()

                            Button {
                                model.importAudioFile()
                            } label: {
                                Image(systemName: "doc.badge.plus")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!model.canImportAudioFile)
                            .help("导入会议录音（仅保存，不自动转写）")
                        }
                    }

                    if filteredChoices.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text(searchText.isEmpty ? "暂无会议记录" : "没有符合条件的会议")
                                .font(.callout.weight(.medium))
                            Text("放弃的录音不会出现在这里")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(filteredChoices) { choice in
                                    MeetingHistoryRow(
                                        choice: choice,
                                        durationText: durationText(choice.durationSeconds),
                                        isSelected: selectedChoice?.id == choice.id
                                    ) {
                                        model.selectMeeting(choice)
                                    }
                                }
                            }
                        }
                    }
                }
                    .padding(14)
                    .frame(
                        width: clampedListWidth(
                            meetingListWidth,
                            totalWidth: geometry.size.width
                        )
                    )

                    ZStack {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.10))
                            .frame(width: 1)
                        Capsule()
                            .fill(Color.secondary.opacity(0.42))
                            .frame(width: 3, height: 34)
                    }
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .help("左右拖动以调整会议列表宽度")
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if splitDragStartWidth == nil {
                                    splitDragStartWidth = meetingListWidth
                                }
                                meetingListWidth = clampedListWidth(
                                    (splitDragStartWidth ?? meetingListWidth)
                                        + value.translation.width,
                                    totalWidth: geometry.size.width
                                )
                            }
                            .onEnded { _ in
                                splitDragStartWidth = nil
                            }
                    )

                    Group {
                        if let selectedChoice {
                            MeetingHistoryDetail(
                                model: model,
                                choice: selectedChoice,
                                durationText: durationText(selectedChoice.durationSeconds)
                            )
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.secondary)
                                Text("选择一场会议查看详情")
                                    .font(.callout.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 410)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.16))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .onAppear {
            model.refreshHistory()
        }
    }
}

private struct MeetingHistoryRow: View {
    let choice: MeetingChoice
    let durationText: String
    let isSelected: Bool
    let action: () -> Void

    private var statusColor: Color {
        if choice.hasMinutes { return .purple }
        switch choice.processingState {
        case .transcribed: return .green
        case .processing: return .blue
        case .incomplete: return .orange
        case .saved: return .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "waveform")
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(
                        "\(choice.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(durationText)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(choice.stateText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.11) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class MeetingAudioPlayerModel: NSObject, ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var stopAt: TimeInterval?
    private var timer: AnyCancellable?

    func toggle(url: URL, from start: TimeInterval = 0, to end: TimeInterval? = nil) {
        if currentURL == url, isPlaying, abs(currentTime - start) < 1.5 {
            pause()
            return
        }
        play(url: url, from: start, to: end)
    }

    func play(url: URL, from start: TimeInterval = 0, to end: TimeInterval? = nil) {
        do {
            if currentURL != url {
                player = try AVAudioPlayer(contentsOf: url)
                currentURL = url
            }
            guard let player else { return }
            player.currentTime = min(max(0, start), player.duration)
            stopAt = end
            duration = player.duration
            currentTime = player.currentTime
            player.play()
            isPlaying = true
            startTimer()
        } catch {
            NSSound.beep()
        }
    }

    func pause() {
        player?.pause()
        currentTime = player?.currentTime ?? currentTime
        isPlaying = false
        timer?.cancel()
        timer = nil
    }

    func seek(to value: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, value), player.duration)
        currentTime = player.currentTime
    }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if let stopAt = self.stopAt, player.currentTime >= stopAt {
                    player.pause()
                    self.isPlaying = false
                    self.timer?.cancel()
                    self.timer = nil
                } else if !player.isPlaying {
                    self.isPlaying = false
                    self.timer?.cancel()
                    self.timer = nil
                }
            }
    }
}

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case result = "最终结果"
    case transcript = "原始转写"
    case speakers = "发言人原话"
    case speakerSummary = "发言人总结"

    var id: Self { self }
}

private struct MeetingHistoryDetail: View {
    @ObservedObject var model: MeetingAppModel
    let choice: MeetingChoice
    let durationText: String

    @StateObject private var player = MeetingAudioPlayerModel()
    @State private var selectedTab: MeetingDetailTab = .result
    @State private var selectedSpeaker = ""
    @State private var selectedSummarySpeaker = ""
    @State private var transcriptText = ""
    @State private var correctionTarget: MeetingSpeakerUtterance?
    @State private var correctionName = ""
    @State private var correctionError: String?

    private var statusColor: Color {
        if choice.minutesOutdated { return .orange }
        if choice.hasMinutes { return .purple }
        switch choice.processingState {
        case .transcribed: return .green
        case .processing: return .blue
        case .incomplete: return .orange
        case .saved: return .secondary
        }
    }

    private var resultPreview: String {
        if let preview = choice.readableArtifacts.minutesPreview {
            return preview
        }
        if let preview = choice.readableArtifacts.transcriptPreview {
            return preview
        }
        if choice.processingState == .transcribed {
            return "会议文字已经准备好，可以复制提示词交给 Codex 整理。"
        }
        if choice.processingState == .incomplete {
            return "上次转写没有完成；已生成的缓存会保留，可以继续处理。"
        }
        if choice.processingState == .processing {
            return "正在本机转写，完成后这里会显示文字预览。"
        }
        return "原始录音已经安全保存。需要时再开始转写，不会自动处理。"
    }

    private var speakerUtterances: [MeetingSpeakerUtterance] {
        guard !activeSpeaker.isEmpty else {
            return choice.speakerTimeline.utterances
        }
        return choice.speakerTimeline.utterances.filter {
            $0.displaySpeaker == activeSpeaker
        }
    }

    private var activeSpeaker: String {
        choice.speakerTimeline.speakers.contains(selectedSpeaker)
            ? selectedSpeaker
            : (choice.speakerTimeline.speakers.first ?? "")
    }

    private var activeSpeakerSummary: MeetingSpeakerSummary? {
        let summaries = choice.readableArtifacts.speakerSummaries
        return summaries.first(where: {
            $0.speaker == selectedSummarySpeaker
        }) ?? summaries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            processingStages

            Picker("查看内容", selection: $selectedTab) {
                ForEach(MeetingDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .result:
                    resultView
                case .transcript:
                    transcriptView
                case .speakers:
                    speakersView
                case .speakerSummary:
                    speakerSummaryView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .padding(17)
        .onAppear {
            selectedSpeaker = choice.speakerTimeline.speakers.first ?? ""
            selectedSummarySpeaker = choice.readableArtifacts
                .speakerSummaries.first?.speaker ?? ""
        }
        .onChange(of: choice.id) { _ in
            player.pause()
            selectedTab = .result
            selectedSpeaker = choice.speakerTimeline.speakers.first ?? ""
            selectedSummarySpeaker = choice.readableArtifacts
                .speakerSummaries.first?.speaker ?? ""
        }
        .task(id: choice.id) {
            loadTranscript()
        }
        .sheet(item: $correctionTarget) { utterance in
            speakerCorrectionSheet(utterance)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(choice.startedAt.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(choice.stateText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.11), in: Capsule())
        }
    }

    private var processingStages: some View {
        HStack(spacing: 6) {
            MeetingStageChip(title: "录音", completed: !choice.audioSegments.isEmpty)
            MeetingStageChip(
                title: "转写",
                completed: choice.processingState == .transcribed
            )
            MeetingStageChip(
                title: "声线",
                completed: !choice.speakerTimeline.utterances.isEmpty
            )
            MeetingStageChip(
                title: choice.minutesOutdated ? "纪要待更新" : "纪要",
                completed: choice.hasMinutes && !choice.minutesOutdated,
                warning: choice.minutesOutdated
            )
        }
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MeetingInfoTile(
                    icon: "clock",
                    title: "会议时长",
                    value: durationText
                )
                MeetingInfoTile(
                    icon: "waveform.path",
                    title: "音频分段",
                    value: "\(choice.segmentCount) 段"
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                DetailLine(title: "输入设备", value: choice.inputDevice)
                DetailLine(
                    title: "参与人",
                    value: choice.participants.isEmpty
                        ? "未填写"
                        : choice.participants.joined(separator: "、")
                )
                DetailLine(title: "会议编号", value: choice.id)
            }
            if choice.minutesOutdated {
                Label(
                    "说话人已人工修订。原纪要保留为历史结果，请重新交给 Codex 生成新版。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }
            ScrollView {
                Text(resultPreview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(
                (choice.hasMinutes ? Color.purple : Color.accentColor)
                    .opacity(0.07),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if choice.readableArtifacts.transcriptURL == nil {
                MeetingEmptyState(
                    title: "尚未生成原始转写",
                    icon: "text.badge.xmark",
                    detail: "可以先开始本地转写，完成后在这里查看完整文字记录。"
                )
            } else {
                HStack {
                    Label("原始转写文字", systemImage: "text.alignleft")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("在文件中打开") {
                        model.openTranscript(choice)
                    }
                    .buttonStyle(.borderless)
                }
                ScrollView {
                    Text(
                        transcriptText.isEmpty
                            ? "正在读取转写文字…"
                            : transcriptText
                    )
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                }
                .background(
                    Color.secondary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }

    private var speakersView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if choice.speakerTimeline.utterances.isEmpty {
                MeetingEmptyState(
                    title: "尚未形成说话人时间线",
                    icon: "person.wave.2",
                    detail: "完成声线识别或人工复核后，这里会按发言人显示原话。"
                )
            } else {
                Picker("发言人", selection: Binding(
                    get: { activeSpeaker },
                    set: { selectedSpeaker = $0 }
                )) {
                    ForEach(choice.speakerTimeline.speakers, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("\(speakerUtterances.count) 条发言")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("只有人工确认姓名会直接显示")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(speakerUtterances) { utterance in
                            speakerRow(utterance)
                        }
                    }
                }
            }
        }
    }

    private var speakerSummaryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if choice.readableArtifacts.speakerSummaries.isEmpty {
                Spacer()
                VStack(spacing: 9) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("尚未生成按发言人总结")
                        .font(.callout.weight(.semibold))
                    Text("完成会议纪要后，可以让 Codex 按已确认发言人归纳核心观点、决定和待办。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        model.copySpeakerSummaryPrompt(for: choice)
                    } label: {
                        Label("复制按人总结提示词", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if let summary = activeSpeakerSummary {
                Picker(
                    "发言人",
                    selection: Binding(
                        get: { summary.speaker },
                        set: { selectedSummarySpeaker = $0 }
                    )
                ) {
                    ForEach(choice.readableArtifacts.speakerSummaries) { item in
                        Text(item.speaker).tag(item.speaker)
                    }
                }
                .pickerStyle(.menu)

                if choice.minutesOutdated {
                    Label(
                        "说话人已人工修订，此处总结来自旧纪要，需要重新生成。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                ScrollView {
                    Text(summary.summary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(
                    Color.purple.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10)
                )

                Text("内容读取自现有会议纪要，不会在页面中临时生成。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func speakerRow(
        _ utterance: MeetingSpeakerUtterance
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                if let url = utterance.audioURL {
                    player.toggle(
                        url: url,
                        from: utterance.audioStartSeconds,
                        to: utterance.audioEndSeconds
                    )
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(utterance.audioURL == nil)
            .help("播放这句话的原音")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(timeText(utterance.startSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if utterance.isHumanCorrected {
                        Label("人工修订", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(utterance.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button("修正") {
                correctionName = utterance.displaySpeaker.hasPrefix("未确认发言人")
                    ? ""
                    : utterance.displaySpeaker
                correctionError = nil
                correctionTarget = utterance
            }
            .buttonStyle(.borderless)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private func speakerCorrectionSheet(
        _ utterance: MeetingSpeakerUtterance
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修正这句话的发言人")
                .font(.title3.weight(.semibold))
            Text(utterance.text)
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            TextField("输入正确姓名", text: $correctionName)
                .textFieldStyle(.roundedBorder)
            Text("本次只修正这一句话。原始声线时间线保持不变；已有纪要会标记为需要重新生成。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let correctionError {
                Text(correctionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") {
                    correctionTarget = nil
                }
                Button("保存修订") {
                    do {
                        try model.saveSpeakerCorrection(
                            for: choice,
                            utterance: utterance,
                            correctedSpeaker: correctionName
                        )
                        selectedSpeaker = correctionName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        correctionTarget = nil
                    } catch {
                        correctionError = "没有保存：请输入姓名并重试。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    correctionName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
        .padding(22)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if choice.hasMinutes && !choice.minutesOutdated {
                Button {
                    model.openMinutes(choice)
                } label: {
                    Label("打开完整纪要", systemImage: "doc.text")
                }
                .buttonStyle(.borderedProminent)
            } else if choice.processingState == .transcribed {
                Button {
                    model.copyCodexPrompt(for: choice)
                } label: {
                    Label(
                        model.lastCopiedMeetingID == choice.id
                            ? "提示词已复制"
                            : (choice.minutesOutdated
                                ? "复制重新生成提示词"
                                : "交给 Codex 整理"),
                        systemImage: model.lastCopiedMeetingID == choice.id
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    model.startProcessing(choice)
                } label: {
                    Label(
                        choice.processingState == .incomplete
                            ? "继续转写"
                            : "开始转写",
                        systemImage: "text.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartProcessing(choice))
            }

            if choice.readableArtifacts.transcriptURL != nil {
                Button("打开转写") {
                    model.openTranscript(choice)
                }
            }
            Button {
                model.openMeetingFolder(choice)
            } label: {
                Image(systemName: "folder")
            }
            .help("打开会议文件夹")
            Spacer()
            Button(role: .destructive) {
                model.requestDeleteMeeting(choice)
            } label: {
                Image(systemName: "trash")
            }
            .help("删除会议")
        }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func loadTranscript() {
        guard let url = choice.readableArtifacts.transcriptURL else {
            transcriptText = ""
            return
        }
        transcriptText = (try? String(contentsOf: url, encoding: .utf8))
            ?? "转写文件暂时无法读取，请使用“在文件中打开”检查原文件。"
    }
}

private struct MeetingStageChip: View {
    let title: String
    let completed: Bool
    var warning = false

    var body: some View {
        Label(
            title,
            systemImage: warning
                ? "exclamationmark.circle.fill"
                : (completed ? "checkmark.circle.fill" : "circle")
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(warning ? Color.orange : (completed ? Color.green : Color.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            (warning ? Color.orange : (completed ? Color.green : Color.secondary))
                .opacity(0.08),
            in: Capsule()
        )
    }
}

private struct MeetingEmptyState: View {
    let title: String
    let icon: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingInfoTile: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.medium))
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetailLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct MeetingMenuView: View {
    @ObservedObject var model: MeetingAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.headline)
        if model.isMeetingActive {
            Text("会议 \(model.elapsedText) · 实录 \(model.recordedText)")
        }
        Divider()
        Button("显示会议助手") {
            if let window = NSApp.windows.first(where: {
                $0.title == "会议助手" && $0.isVisible
            }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openWindow(id: "meeting-assistant")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if model.isMeetingActive {
            Button(model.isPaused ? "继续录音" : "暂停录音") {
                model.pauseOrResume()
            }
            Button("停止并保存") {
                model.performPrimaryAction()
            }
            Button("放弃本次录音") {
                openWindow(id: "meeting-assistant")
                NSApp.activate(ignoringOtherApps: true)
                model.requestDiscardCurrentMeeting()
            }
        } else {
            Button(model.primaryTitle) {
                model.performPrimaryAction()
            }
            .disabled(!model.primaryEnabled)
        }
        if model.canStopProcessing {
            Button("停止本地转写（保留缓存）") {
                model.stopProcessing()
            }
        }
        if model.canRetryProcessing {
            Button(model.retryProcessingTitle) {
                model.retryProcessing()
            }
        }
        Button("打开录音文件夹") {
            model.openRecordingsFolder()
        }
        Divider()
        Button("退出会议助手") {
            NSApp.terminate(nil)
        }
    }
}

@main
private struct MeetingAssistantApp: App {
    @StateObject private var model = MeetingAppModel()
    @NSApplicationDelegateAdaptor(MeetingAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("会议助手", id: "meeting-assistant") {
            MeetingAssistantView(model: model)
                .onAppear {
                    appDelegate.model = model
                }
        }
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MeetingMenuView(model: model)
        } label: {
            Image(
                systemName: model.isRecording
                    ? "record.circle.fill"
                    : (model.isPaused ? "pause.circle.fill" : "mic.fill")
            )
        }
        .menuBarExtraStyle(.menu)
    }
}
