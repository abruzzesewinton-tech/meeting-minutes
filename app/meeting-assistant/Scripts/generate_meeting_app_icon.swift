#!/usr/bin/swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("用法：generate_meeting_app_icon.swift <输出 PNG>\n", stderr)
    exit(2)
}

let size = 1_024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("无法创建图标画布。\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

let backgroundRect = NSRect(x: 42, y: 42, width: 940, height: 940)
let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 218, yRadius: 218)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.035, green: 0.16, blue: 0.22, alpha: 1),
    ending: NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.48, alpha: 1)
)!
gradient.draw(in: background, angle: -48)

NSColor.white.withAlphaComponent(0.13).setFill()
NSBezierPath(
    roundedRect: NSRect(x: 96, y: 510, width: 832, height: 372),
    xRadius: 155,
    yRadius: 155
).fill()

NSColor.white.setFill()
let capsule = NSBezierPath(
    roundedRect: NSRect(x: 390, y: 348, width: 244, height: 420),
    xRadius: 122,
    yRadius: 122
)
capsule.fill()

let receiver = NSBezierPath()
receiver.lineWidth = 54
receiver.lineCapStyle = .round
receiver.appendArc(
    withCenter: NSPoint(x: 512, y: 475),
    radius: 218,
    startAngle: 180,
    endAngle: 360,
    clockwise: false
)
NSColor.white.setStroke()
receiver.stroke()

let stem = NSBezierPath()
stem.lineWidth = 54
stem.lineCapStyle = .round
stem.move(to: NSPoint(x: 512, y: 255))
stem.line(to: NSPoint(x: 512, y: 170))
stem.stroke()

let base = NSBezierPath()
base.lineWidth = 54
base.lineCapStyle = .round
base.move(to: NSPoint(x: 405, y: 170))
base.line(to: NSPoint(x: 619, y: 170))
base.stroke()

NSColor(calibratedRed: 1, green: 0.25, blue: 0.24, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 728, y: 708, width: 142, height: 142)).fill()
NSColor.white.withAlphaComponent(0.92).setStroke()
let dotRing = NSBezierPath(ovalIn: NSRect(x: 741, y: 721, width: 116, height: 116))
dotRing.lineWidth = 10
dotRing.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("无法导出 PNG。\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
} catch {
    fputs("保存图标失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
