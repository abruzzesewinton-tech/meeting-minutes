import Foundation

public enum VoiceMode: String, Codable, CaseIterable, Sendable {
    case personal
    case interview
    case meeting
}

public enum ControllerState: Equatable, Sendable {
    case personal
    case modeSelection(previous: VoiceMode)
    case interview
    case meeting

    public var activeMode: VoiceMode {
        switch self {
        case .personal:
            return .personal
        case let .modeSelection(previous):
            return previous
        case .interview:
            return .interview
        case .meeting:
            return .meeting
        }
    }
}

public enum ControlInput: String, Sendable {
    case home
    case a
    case aLong
    case b
    case x
    case y
    case r
    case zrDown
    case zrUp
    case plusLong
    case stickPress
    case controllerDisconnected
    case controllerReconnected
}

public enum MarkerKind: String, Codable, Sendable {
    case otherSpeaker
    case selfSpeaker
    case speakerChanged
    case highlight
    case question
    case decision
    case actionItem
    case note
    case undo
    case controllerDisconnected
    case controllerReconnected
}

public enum ControlEffect: Equatable, Sendable {
    case showModeSelection(current: VoiceMode)
    case dismissOverlay
    case showSessionStatus(mode: VoiceMode)
    case startSession(mode: VoiceMode)
    case stopAndSaveSession(mode: VoiceMode)
    case appendMarker(MarkerKind)
    case beginPersonalDictation
    case endPersonalDictation
    case sendCurrentText
    case undoPersonalInput
    case insertNewline
    case warnControllerDisconnected
    case acknowledgeControllerReconnected
    case ignored(reason: String)
}

public struct MarkerRecord: Codable, Equatable, Sendable {
    public let sequence: Int
    public let elapsedMilliseconds: Int
    public let kind: MarkerKind
    public let createdAt: Date

    public init(
        sequence: Int,
        elapsedMilliseconds: Int,
        kind: MarkerKind,
        createdAt: Date = Date()
    ) {
        self.sequence = sequence
        self.elapsedMilliseconds = elapsedMilliseconds
        self.kind = kind
        self.createdAt = createdAt
    }
}
