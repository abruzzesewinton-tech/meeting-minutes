// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "JoyConVoiceCore", targets: ["JoyConVoiceCore"]),
        .executable(name: "meeting-assistant", targets: ["JoyConMeetingApp"]),
        .executable(
            name: "meeting-assistant-self-test",
            targets: ["MeetingAssistantSelfTest"]
        ),
    ],
    targets: [
        .target(name: "JoyConVoiceCore"),
        .executableTarget(
            name: "JoyConMeetingApp",
            dependencies: ["JoyConVoiceCore"]
        ),
        .executableTarget(
            name: "MeetingAssistantSelfTest",
            dependencies: ["JoyConVoiceCore"]
        ),
    ]
)
