#!/usr/bin/env swift
// Генератор иконки приложения.
//
// Рисует иконку кодом, чтобы в репозитории не лежал бинарный артефакт,
// который нельзя проверить глазами: композиция, цвета и размеры описаны
// прямо здесь и воспроизводимы на любой машине.
//
// Запуск:  swift Tools/make_icon.swift build/AppIcon.icns

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024
let inset: CGFloat = 100          // поля вокруг иконки в стиле macOS
let side = CGFloat(canvas) - inset * 2
let radius = side * 0.2237

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let space = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: canvas,
    height: canvas,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("ERR: не удалось создать контекст\n".utf8))
    exit(1)
}

let box = CGRect(x: inset, y: inset, width: side, height: side)
let center = CGPoint(x: canvas / 2, y: canvas / 2 + 10)

// 1. Фон: диагональный градиент от глубокого индиго к фиолетовому.
let shape = CGPath(
    roundedRect: box,
    cornerWidth: radius,
    cornerHeight: radius,
    transform: nil
)

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

let bg = CGGradient(
    colorsSpace: space,
    colors: [color(0x1B1240), color(0x3B1E7A), color(0x6D28D9)] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(
    bg,
    start: CGPoint(x: box.minX, y: box.maxY),
    end: CGPoint(x: box.maxX, y: box.minY),
    options: []
)

// 2. Мягкое свечение сверху — читается как источник света.
let glow = CGGradient(
    colorsSpace: space,
    colors: [color(0xA78BFA, alpha: 0.55), color(0xA78BFA, alpha: 0.0)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: center.x, y: box.maxY - side * 0.22),
    startRadius: 0,
    endCenter: CGPoint(x: center.x, y: box.maxY - side * 0.22),
    endRadius: side * 0.62,
    options: [.drawsAfterEndLocation]
)

// 3. Концентрические кольца — шаги диффузии: шум сходится к центру.
for (index, scale) in [0.46, 0.37, 0.28, 0.19].enumerated() {
    let r = side * CGFloat(scale)
    ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.30 - CGFloat(index) * 0.05))
    ctx.setLineWidth(side * 0.011)
    ctx.strokeEllipse(in: CGRect(
        x: center.x - r,
        y: center.y - r,
        width: r * 2,
        height: r * 2
    ))
}

// 4. Точки-«шум» по кольцам: у внешних мельче и тусклее.
var seed: UInt64 = 0x5EED_1234
func random() -> CGFloat {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return CGFloat((seed >> 33) % 10_000) / 10_000
}

for ring in 0..<4 {
    let radiusBase = side * [0.46, 0.37, 0.28, 0.19][ring]
    let count = 14 - ring * 2
    for i in 0..<count {
        let angle = (2 * CGFloat.pi * CGFloat(i) / CGFloat(count)) + random() * 0.28 - 0.14
        let jitter = radiusBase + (random() - 0.5) * side * 0.035
        let dot = side * (0.012 + random() * 0.008) * (1.0 - CGFloat(ring) * 0.12)
        let p = CGPoint(
            x: center.x + cos(angle) * jitter,
            y: center.y + sin(angle) * jitter
        )
        ctx.setFillColor(color(0xDDD6FE, alpha: 0.75 - CGFloat(ring) * 0.13))
        ctx.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
    }
}

// 5. Центр — «очищенное» изображение.
let coreRadius = side * 0.125
let core = CGGradient(
    colorsSpace: space,
    colors: [color(0xFFFFFF), color(0xC4B5FD)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(
    core,
    startCenter: center,
    startRadius: 0,
    endCenter: center,
    endRadius: coreRadius,
    options: []
)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillEllipse(in: CGRect(
    x: center.x - coreRadius * 0.52,
    y: center.y - coreRadius * 0.52,
    width: coreRadius * 1.04,
    height: coreRadius * 1.04
))

// 6. Внутренняя рамка для глубины.
ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.16))
ctx.setLineWidth(side * 0.008)
ctx.addPath(CGPath(
    roundedRect: box.insetBy(dx: side * 0.028, dy: side * 0.028),
    cornerWidth: radius * 0.93,
    cornerHeight: radius * 0.93,
    transform: nil
))
ctx.strokePath()

ctx.restoreGState()

guard let full = ctx.makeImage() else {
    FileHandle.standardError.write(Data("ERR: не удалось получить изображение\n".utf8))
    exit(1)
}

// Собираем .icns
let work = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (size, name) in variants {
    guard let scaled = draw(image: full, size: size) else {
        FileHandle.standardError.write(Data("ERR: не удалось масштабировать до \(size)\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: scaled)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("ERR: не удалось закодировать PNG \(size)\n".utf8))
        exit(1)
    }
    try png.write(to: work.appendingPathComponent(name))
}

func draw(image: CGImage, size: Int) -> CGImage? {
    let c = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    c?.interpolationQuality = .high
    c?.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return c?.makeImage()
}

let icns = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.icns")
try? FileManager.default.removeItem(at: icns)
try FileManager.default.createDirectory(
    at: icns.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", work.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("ERR: iconutil упал\n".utf8))
    exit(1)
}
print("OK: \(icns.path)")