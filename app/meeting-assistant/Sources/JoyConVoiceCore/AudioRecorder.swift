import AudioToolbox
import AVFoundation
import Foundation

public enum AudioInputError: LocalizedError {
    case noDefaultInput
    case propertyReadFailed(OSStatus)
    case recorderDidNotStart

    public var errorDescription: String? {
        switch self {
        case .noDefaultInput:
            return "Mac 没有可用的默认音频输入设备。"
        case let .propertyReadFailed(status):
            return "读取默认音频输入设备失败（OSStatus \(status)）。"
        case .recorderDidNotStart:
            return "录音器没有成功启动；请检查麦克风权限和默认输入设备。"
        }
    }
}

public enum AudioDeviceCatalog {
    public static func defaultInputName() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw AudioInputError.propertyReadFailed(status)
        }
        guard deviceID != kAudioObjectUnknown else {
            throw AudioInputError.noDefaultInput
        }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard status == noErr else {
            throw AudioInputError.propertyReadFailed(status)
        }
        return name as String
    }
}

public protocol MeetingAudioRecording: AnyObject {
    func start(at url: URL) throws
    func stop()
    var isRecording: Bool { get }
}

public final class ContinuousAudioRecorder: NSObject, AVAudioRecorderDelegate, MeetingAudioRecording, @unchecked Sendable {
    private var recorder: AVAudioRecorder?

    public override init() {}

    public func start(at url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioInputError.recorderDidNotStart
        }
        self.recorder = recorder
    }

    public func stop() {
        recorder?.stop()
        recorder = nil
    }

    public var isRecording: Bool {
        recorder?.isRecording == true
    }
}
