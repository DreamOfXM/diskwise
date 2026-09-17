#!/usr/bin/env swift
// ============================================================
// 生成 App 图标（可复现，不依赖任何设计工具）
//
// 主体：一把斜着的扫帚 —— 柄在左上、刷头在右下，正把灰点往右下角外推。
// 扫帚是「清理」这件事最不含糊的符号，比环、比弧线都不会被读错。
// 三层：
//   1) macOS 圆角底板（深底冷光 / 浅底磨砂两个变体）
//   2) 刷头后面一道擦干净的光痕 + 被推走的浮灰
//   3) 扫帚本体：渐变柄 → 亮色箍 → 五束刷毛（小尺寸并成三束）
//
// 配色取自皮肤代码：a 用「极光玻璃」那组（深底冷光），
// b 用「晨雾 + 薄荷」（浅底）。
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
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

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

// ── 扫帚本体几何：先在局部坐标里竖着画（y 轴朝上，刷头朝 -y），再整体旋转 ──
enum Broom {
    static let pivot = CGPoint(x: 500, y: 492)   // 旋转中心：刷箍附近
    static let tilt: CGFloat = 35 * .pi / 180    // 逆时针 → 柄朝左上、刷头朝右下

    static let handleTop: CGFloat = 336          // 柄顶
    static let handleW: CGFloat = 54
    static let ferruleTop: CGFloat = 66          // 箍：柄与刷毛之间
    static let ferruleBot: CGFloat = 8
    static let ferruleW: CGFloat = 208
    static let fanTop: CGFloat = 8               // 刷毛束上沿（贴着箍）
    static let fanTip: CGFloat = -200            // 刷毛梢
    static let fanHalfTop: CGFloat = 96          // 上沿半宽
    static let fanHalfTip: CGFloat = 122         // 刷梢半宽（往外炸开）

    /// 局部坐标 → 画布坐标（与 ctx.rotate(by: tilt) 同向：逆时针）
    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let s = sin(tilt), co = cos(tilt)
        return CGPoint(x: pivot.x + x * co - y * s, y: pivot.y + x * s + y * co)
    }
}

struct IconSpec {
    var bgTop: NSColor
    var bgBottom: NSColor
    var border: NSColor
    var glowA: NSColor          // 底板氛围光（左上）
    var glowB: NSColor          // 底板氛围光（右下）
    var handle: [NSColor]       // 柄渐变（顶 → 底）
    var ferrule: NSColor        // 箍
    var tuft: [NSColor]         // 刷毛渐变（根 → 梢）
    var halo: NSColor           // 刷头光晕
    var gleam: NSColor          // 擦干净的光痕
    var dust: NSColor           // 灰点
    var haze: NSColor           // 被推出去的浮灰
    var gloss: CGFloat          // 底板顶部高光（>0 视为深底）
}

let specs: [String: IconSpec] = [
    // a：深底冷光 —— 出厂默认
    "a": IconSpec(
        bgTop: hex(0x1D2650),
        bgBottom: hex(0x05070F),
        border: white(0.13),
        glowA: hexA(0x8E7BFF, 0.24),
        glowB: hexA(0x4FD1C5, 0.16),
        handle: [hex(0x9C8BFF), hex(0x3E63E0)],
        ferrule: hex(0xEAF6FF),
        tuft: [hex(0x5FE3C6), hex(0xBDF6E7)],
        halo: hexA(0x49DCC0, 0.40),
        gleam: white(0.07),
        dust: hexA(0xC3CEE6, 1.0),
        haze: hexA(0x9AA6C4, 0.15),
        gloss: 0.10
    ),
    // b：浅底，跟着晨雾 / 薄荷走
    "b": IconSpec(
        bgTop: white(1.0),
        bgBottom: hex(0xE0E8F2),
        border: hexA(0xC3CDDC, 0.95),
        glowA: hexA(0x8E7BFF, 0.10),
        glowB: hexA(0x4FD1C5, 0.14),
        handle: [hex(0x5B86E8), hex(0x2A62D6)],
        ferrule: hex(0x1B2A44),
        tuft: [hex(0x0E8F79), hex(0x4FC7AC)],
        halo: hexA(0x0E8F79, 0.22),
        gleam: hexA(0x0E8F79, 0.16),
        dust: hexA(0x8A96AB, 1.0),
        haze: hexA(0x8A96AB, 0.10),
        gloss: 0.0
    ),
]

func render(px: Int, spec: IconSpec) -> CGImage? {
    let k = CGFloat(px) / Design.canvas
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: k, y: k)

    let c = Design.center
    let small = px <= 64
    let tile = CGPath(roundedRect: Design.tileRect,
                      cornerWidth: Design.tileRadius, cornerHeight: Design.tileRadius,
                      transform: nil)
    func radial(_ at: CGPoint, _ from: NSColor, _ to: NSColor, _ r0: CGFloat, _ r1: CGFloat) {
        guard let g = CGGradient(colorsSpace: srgb, colors: [from.cgColor, to.cgColor] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: at, startRadius: r0, endCenter: at, endRadius: r1,
                               options: [])
    }
    func linearC(_ from: NSColor, _ to: NSColor, _ a: CGPoint, _ b: CGPoint) {
        guard let g = CGGradient(colorsSpace: srgb, colors: [from.cgColor, to.cgColor] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [])
    }

    // ── 1 底板 ──
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    linearC(spec.bgTop, spec.bgBottom, CGPoint(x: c.x, y: Design.canvas), CGPoint(x: c.x, y: 0))
    radial(CGPoint(x: c.x - 250, y: c.y + 210), spec.glowA, spec.glowA.withAlphaComponent(0), 0, 470)
    radial(CGPoint(x: c.x + 260, y: c.y - 240), spec.glowB, spec.glowB.withAlphaComponent(0), 0, 460)
    if spec.gloss > 0 {
        linearC(white(spec.gloss), white(0), CGPoint(x: c.x, y: Design.tileRect.maxY),
                CGPoint(x: c.x, y: c.y))
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(spec.border.cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // 刷头在画布上的位置（局部 (0,-100) 处）
    let headC = Broom.P(0, -100)

    // ── 2 被推走的浮灰：堆在刷梢正前方，越远越小越淡 ──
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    radial(Broom.P(30, -340), spec.haze, spec.haze.withAlphaComponent(0), 0, 320)
    let motes: [(x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)] = [
        (96, -292, 16, 0.95), (-52, -306, 12, 0.72), (168, -344, 9, 0.55),
        (34, -378, 7, 0.42), (226, -286, 6, 0.30), (-118, -262, 8, 0.22),
    ]
    for m in motes {
        let p = Broom.P(m.x, m.y), r = m.r
        ctx.setFillColor(spec.dust.withAlphaComponent(spec.dust.alphaComponent * m.a).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
    ctx.restoreGState()

    // ── 3 扫帚 ──
    // 刷头光晕先铺，让刷毛像是自己发亮
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    radial(headC, spec.halo, spec.halo.withAlphaComponent(0), 0, 250)
    ctx.restoreGState()

    // 局部坐标系：原点在 pivot，+y 朝柄顶，-y 朝刷梢
    func local(_ body: () -> Void) {
        ctx.saveGState()
        ctx.addPath(tile); ctx.clip()
        ctx.translateBy(x: Broom.pivot.x, y: Broom.pivot.y)
        ctx.rotate(by: Broom.tilt)
        body()
        ctx.restoreGState()
    }

    // 柄：圆头长条，顶到底一段渐变
    local {
        let r = CGRect(x: -Broom.handleW / 2, y: Broom.ferruleTop - 6,
                       width: Broom.handleW, height: Broom.handleTop - Broom.ferruleTop + 6)
        let p = CGPath(roundedRect: r, cornerWidth: Broom.handleW / 2,
                       cornerHeight: Broom.handleW / 2, transform: nil)
        ctx.addPath(p); ctx.clip()
        linearC(spec.handle[0], spec.handle[1], CGPoint(x: 0, y: Broom.handleTop),
                CGPoint(x: 0, y: Broom.ferruleTop))
    }
    // 柄上高光：靠左半边一条细亮线，做出圆柱感
    local {
        let r = CGRect(x: -Broom.handleW / 2 + 8, y: Broom.ferruleTop + 24,
                       width: 11, height: Broom.handleTop - Broom.ferruleTop - 40)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
        ctx.clip()
        ctx.setFillColor(white(spec.gloss > 0 ? 0.30 : 0.45).cgColor)
        ctx.fill(r)
    }

    // 刷毛：根部在箍下连成一片，往梢部各自外扩、分开、收圆头
    let bundles = small ? 4 : 5
    local {
        for i in 0..<bundles {
            let f0 = CGFloat(i) / CGFloat(bundles), f1 = CGFloat(i + 1) / CGFloat(bundles)
            let rootL = lerp(-Broom.fanHalfTop, Broom.fanHalfTop, f0)
            let rootR = lerp(-Broom.fanHalfTop, Broom.fanHalfTop, f1)
            let splay = Broom.fanHalfTip / Broom.fanHalfTop
            let tipC = (rootL + rootR) / 2 * splay
            let tipHalf = (rootR - rootL) / 2 * (small ? 0.96 : 0.97)
            var tuft = CGMutablePath()
            tuft.move(to: CGPoint(x: rootL, y: Broom.fanTop))
            tuft.addLine(to: CGPoint(x: rootR, y: Broom.fanTop))
            tuft.addLine(to: CGPoint(x: tipC + tipHalf, y: Broom.fanTip + 14))
            tuft.addQuadCurve(to: CGPoint(x: tipC - tipHalf, y: Broom.fanTip + 14),
                              control: CGPoint(x: tipC, y: Broom.fanTip - 16))
            tuft.closeSubpath()
            ctx.saveGState()
            ctx.addPath(tuft); ctx.clip()
            linearC(spec.tuft[0], spec.tuft[1], CGPoint(x: 0, y: Broom.fanTop),
                    CGPoint(x: 0, y: Broom.fanTip))
            ctx.restoreGState()
        }
    }

    // 箍：压住刷毛根部的亮色金属圈，比刷毛宽一点点
    local {
        let r = CGRect(x: -Broom.ferruleW / 2, y: Broom.ferruleBot,
                       width: Broom.ferruleW, height: Broom.ferruleTop - Broom.ferruleBot)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(spec.ferrule.cgColor)
        ctx.fillPath()
    }

    // 刷梢前缘的一团柔光：让「正在扫」这件事更明确（不能带边界，否则成一块亮斑）
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    if spec.gloss > 0 { ctx.setBlendMode(.plusLighter) }
    radial(Broom.P(0, Broom.fanTip - 6), spec.gleam, spec.gleam.withAlphaComponent(0), 0, 210)
    ctx.restoreGState()

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
