#!/usr/bin/env swift
// ============================================================
// 生成 App 图标（可复现，不依赖任何设计工具）
//
// 画的是本 App 的招牌图形：总览页那个分段环形仪表（RingGauge），
// 配色直接取自皮肤代码——A 版用「晨雾」的图例色，B 版用「午夜」的。
//
// 用法：
//   swift make_icon.swift [输出iconset目录] [a|b]
//   iconutil -c icns -o AppIcon.icns <输出iconset目录>
// ============================================================

import AppKit
import CoreGraphics
import Foundation

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
func hexA(_ v: UInt32, _ a: CGFloat) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
func white(_ v: CGFloat) -> NSColor { hexA(0xFFFFFF, v) }
func deg2rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// ── 设计尺寸：全部按 1024 逻辑坐标画，再整体缩放到目标像素 ──
enum Design {
    static let canvas: CGFloat = 1024
    /// macOS 图标栅格：图形占居中 824×824，四边留透明
    static let tileSide: CGFloat = 824
    static var tileRect: CGRect {
        let o = (canvas - tileSide) / 2
        return CGRect(x: o, y: o, width: tileSide, height: tileSide)
    }
    static let tileRadius: CGFloat = 185.4
    static var center: CGPoint { CGPoint(x: canvas / 2, y: canvas / 2) }
}

// ── 两个候选：一个晨雾（浅），一个午夜（深） ──
struct IconSpec {
    var bgTop: NSColor
    var bgBottom: NSColor
    var border: NSColor
    var track: NSColor
    var arcs: [NSColor]      // 顺时针，从 12 点起
    var hub: NSColor
}

let specs: [String: IconSpec] = [
    "a": IconSpec(
        bgTop: white(1.0),
        bgBottom: hex(0xE7ECF3),
        border: hexA(0xC6CFDC, 0.9),
        track: hex(0xE2E7EE),
        arcs: [hex(0x0072B2), hex(0xE69F00), hex(0x009E73)],
        hub: hex(0x2A62D6)
    ),
    "b": IconSpec(
        bgTop: hex(0x1C2A45),
        bgBottom: hex(0x090C12),
        border: white(0.10),
        track: white(0.14),
        arcs: [hex(0x4FA3E3), hex(0xF2B441), hex(0x35C795)],
        hub: .white
    ),
]

// ── 环形仪表几何（1024 空间） ──
// 三段彩弧共 270°，剩下的露出浅色轨道 = “已用约 75%”，跟总览页语义一致
let ringRadius: CGFloat = 232      // 描边中线半径
let ringWidth: CGFloat = 78
let arcLengths: [CGFloat] = [130, 86, 54]
let arcStart: CGFloat = 2          // 12 点偏右 2°，起笔不在正上方
let arcGap: CGFloat = 4
let hubRadius: CGFloat = 44

/// 从 12 点顺时针排的各段起止角度（度）
func arcSpans(gap: CGFloat) -> [(from: CGFloat, to: CGFloat)] {
    var d = arcStart
    return arcLengths.map { len in
        let s = (from: d, to: d + len)
        d += len + gap
        return s
    }
}

func render(px: Int, spec: IconSpec) -> CGImage? {
    let k = CGFloat(px) / Design.canvas
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: k, y: k)

    // 小尺寸下彩弧会糊成一团：加粗环、去掉弧间缝隙、放大轴心
    let small = px <= 64
    let width = ringWidth * (small ? 1.22 : 1)
    let hub = hubRadius * (small ? 1.2 : 1)
    let spans = arcSpans(gap: small ? 0 : arcGap)

    let tile = Design.tileRect
    let path = CGPath(roundedRect: tile, cornerWidth: Design.tileRadius,
                      cornerHeight: Design.tileRadius, transform: nil)

    // 底板：竖向渐变 + 一圈细描边
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [spec.bgTop.cgColor, spec.bgBottom.cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: Design.center.x, y: Design.canvas),
                           end: CGPoint(x: Design.center.x, y: 0), options: [])
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(spec.border.cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    let c = Design.center

    // 轨道
    ctx.setStrokeColor(spec.track.cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    ctx.addArc(center: c, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // 彩弧：角度按“从 12 点顺时针”定义，CG 是 y 朝上逆时针，所以取 90°-θ
    for (i, s) in spans.enumerated() {
        ctx.setStrokeColor(spec.arcs[i].cgColor)
        ctx.setLineWidth(width)
        ctx.addArc(center: c, radius: ringRadius,
                   startAngle: deg2rad(90 - s.from), endAngle: deg2rad(90 - s.to),
                   clockwise: true)
        ctx.strokePath()
    }

    // 轴心：让画面读作「仪表」而不只是一圈彩带
    ctx.setFillColor(spec.hub.cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))

    return ctx.makeImage()
}

// ── iconutil 要求的命名表 ──
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "icon.iconset"
let variant = args.count > 2 ? args[2] : "a"
guard let spec = specs[variant] else {
    FileHandle.standardError.write("未知变体 \(variant)，可选 a / b\n".data(using: .utf8)!)
    exit(2)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for s in sizes {
    guard let img = render(px: s.px, spec: spec) else {
        FileHandle.standardError.write("渲染失败 \(s.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG 编码失败 \(s.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let out = URL(fileURLWithPath: outDir).appendingPathComponent(s.name)
    do {
        try data.write(to: out, options: .atomic)
    } catch {
        FileHandle.standardError.write("写入失败 \(out.path)：\(error)\n".data(using: .utf8)!)
        exit(1)
    }
    print("    \(s.name)  \(s.px)px")
}
