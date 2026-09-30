#!/usr/bin/env swift
// ============================================================
// 生成 App 图标（可复现，不依赖任何设计工具）
//
// 主体：一环开口的霓虹管 + 环心一只桶。管在右上收成一个箭头，所以整枚读作
// 「转一圈把东西清掉」，而不只是一个圆。三层：
//   1) 深底圆角底板 + 左上氛围光 + 一道斜穿过去的光带
//   2) 图形自己的两层外发光（细的青、宽的紫）——霓虹管的光必须落在暗底上才成立
//   3) 图形本体：管身走冷→暖的色相渐变，里侧再压一条亮芯，底板外沿一圈冷白描边
//
// 形状与配色都不是这里随手定的：形状＝应用图标第 1 轮锁死的 13 号图案
// （环 64°→330°、R=250、线宽 50），配色＝第 3 轮投的那格（霓虹管+外发光）
// 从他给的参考图上实测出的两个端点。这两个值和皮肤目录里的色不是一套
// （aurora 是 #8E7BFF / #4FD1C5），刻意不跟皮肤联动：图标是品牌件，
// 换皮肤不该换掉 Dock 里那枚。
//
// 用法：
//   swift make_icon.swift [输出iconset目录]
//   iconutil -c icns -o AppIcon.icns <输出iconset目录>
//
//   ICON_NOGLOW=1 swift make_icon.swift …    撤掉两层外发光（走 09-25 那条「样稿禁加发光」）
// ============================================================

import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

let C: CGFloat = 1024            // 逻辑画布：下面所有尺寸都按 1024 表述
let SS: CGFloat = 4              // 超采样：先在 4096 上合成辉光，再逐级折半到各档
let CIF = CIContext(options: [.useSoftwareRenderer: true])

func srgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255,
                         CGFloat(v & 0xFF) / 255, a])!
}
/// 两个 #RRGGBB 按 t 线性混合（与 SVG 端点插值同口径）
func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> UInt32 {
    func ch(_ x: UInt32, _ sh: Int) -> CGFloat { CGFloat((x >> sh) & 0xFF) }
    func bl(_ sh: Int) -> UInt32 {
        let v = ch(a, sh) + (ch(b, sh) - ch(a, sh)) * t
        return UInt32(min(255, max(0, v.rounded())))
    }
    return bl(16) << 16 | bl(8) << 8 | bl(0)
}
func grad(_ from: [CGColor], _ locs: [CGFloat], _ a: CGPoint, _ b: CGPoint) -> CGGradient? {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: from as CFArray, locations: locs)
}

// ── 冻结的栅格 ───────────────────────────────────────────────
let X0: CGFloat = 112, SIDE: CGFloat = 800, RX: CGFloat = 180   // 底板：800 见方居中等比圆角
let CX = 512.0, CY = 512.0, R = 250.0, RING_W: CGFloat = 50

func ysvg(_ y: CGFloat) -> CGFloat { C - y }                    // SVG(下 y) → CG(上 y)
/// 罗盘角：0°=正上，顺时针
func pol(_ deg: CGFloat, _ r: CGFloat = R) -> CGPoint {
    let t = deg * .pi / 180
    return CGPoint(x: CX + r * sin(t), y: ysvg(CY - r * cos(t)))
}
/// 环：64°→330°，缺口朝上，右上那一头收成箭头
func ringPath() -> CGMutablePath {
    let p = CGMutablePath()
    var d: CGFloat = 64, first = true
    while d <= 330.0001 {
        let q = pol(d)
        if first { p.move(to: q); first = false } else { p.addLine(to: q) }
        d += 0.25
    }
    return p
}
let RING = ringPath()
let TRI: [CGPoint] = [CGPoint(x: 650.4, y: ysvg(444.5)), CGPoint(x: 738.3, y: ysvg(328.2)),
                      CGPoint(x: 796.2, y: ysvg(446.8))]
let HANDLE = CGRect(x: 480, y: ysvg(386), width: 64, height: 26)
let LID = CGRect(x: 408, y: ysvg(428), width: 208, height: 40)
let BODYQ: [CGPoint] = [CGPoint(x: 426, y: ysvg(446)), CGPoint(x: 598, y: ysvg(446)),
                        CGPoint(x: 578, y: ysvg(630)), CGPoint(x: 446, y: ysvg(630))]

func path(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
}

// ── 那一格的取值（投票页第 18 格 cell("glow","ref") 的原值）──
let HUE_0: UInt32 = 0x19F3F4, HUE_1: UInt32 = 0x8652E6
let PLATE_TOP: UInt32 = 0x11223A, PLATE_BOT: UInt32 = 0x061023
let EDGE: UInt32 = mix(0xFFFFFF, PLATE_TOP, 0.10)          // #E7E9EB
let CORE: UInt32 = mix(0xFFFFFF, HUE_0, 0.25)              // #C6FCFC
let RIM_END: UInt32 = mix(HUE_0, 0xFFFFFF, 0.40)           // #75F8F8
let HALO_0: UInt32 = mix(HUE_0, 0xFFFFFF, 0.55)            // #98FAFA
let SIGMA_TIGHT: CGFloat = 13, SIGMA_WIDE: CGFloat = 39
// CoreImage 的 inputRadius 与 SVG 的 stdDeviation 不是同一把尺：同一格同一行实测，
// 0.5 倍时外发光扩散 47pt 对上 SVG 的 48pt，1.0 倍会溢到 88pt（投票页的扫描表）。
let SIG: CGFloat = 0.5

let plateRect = CGRect(x: X0, y: ysvg(X0 + SIDE), width: SIDE, height: SIDE)
let platePath = CGPath(roundedRect: plateRect, cornerWidth: RX, cornerHeight: RX, transform: nil)

/// 元素自己的 objectBoundingBox → 渐变两端点（x1=0 y1=.1 → x2=1 y2=.9）
func hueEnds(_ b: CGRect) -> (CGPoint, CGPoint) {
    let bx = b.minX, by = C - b.maxY, bw = b.width, bh = b.height   // b 已是 CG 坐标
    return (CGPoint(x: bx, y: by + bh * 0.1), CGPoint(x: bx + bw, y: by + bh * 0.9))
}
let RING_BBOX = CGRect(x: 262, y: ysvg(762), width: 500, height: 466.5)

func fillHue(_ ctx: CGContext, _ clip: CGPath, _ bbox: CGRect, mask: Bool) {
    ctx.saveGState(); ctx.addPath(clip); ctx.clip()
    if mask {
        ctx.setFillColor(srgb(0xFFFFFF)); ctx.fill(bbox.insetBy(dx: -C, dy: -C))
    } else {
        let (p0, p1) = hueEnds(bbox)
        if let g = grad([srgb(HUE_0), srgb(HUE_1)], [0, 1], p0, p1) {
            ctx.drawLinearGradient(g, start: p0, end: p1,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }
    ctx.restoreGState()
}
func strokeRing(_ ctx: CGContext, _ w: CGFloat, mask: Bool) {
    ctx.saveGState()
    ctx.addPath(RING)
    ctx.setLineCap(.round); ctx.setLineWidth(w)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if mask {
        ctx.setFillColor(srgb(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: 0, width: C, height: C))
    } else {
        let (p0, p1) = hueEnds(RING_BBOX)
        if let g = grad([srgb(HUE_0), srgb(HUE_1)], [0, 1], p0, p1) {
            ctx.drawLinearGradient(g, start: p0, end: p1,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }
    ctx.restoreGState()
}

// ── 底板 + 氛围（左上光斑 / 斜光带），全部裁在板内 ─────────────
func drawBackdrop(_ ctx: CGContext) {
    ctx.saveGState(); ctx.addPath(platePath); ctx.clip()
    let p0 = CGPoint(x: X0, y: ysvg(X0)), p1 = CGPoint(x: X0 + 0.35 * SIDE, y: ysvg(X0 + SIDE))
    if let g = grad([srgb(PLATE_TOP), srgb(PLATE_BOT)], [0, 1], p0, p1) {
        ctx.drawLinearGradient(g, start: p0, end: p1,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    let hc = CGPoint(x: X0 + SIDE * 0.27, y: ysvg(X0 + SIDE * 0.24)), hr = SIDE * 0.34
    let hb = CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2)
    let gc = CGPoint(x: hb.minX + 0.32 * hb.width, y: hb.maxY - 0.29 * hb.height)
    if let g = grad([srgb(HALO_0, 0.55), srgb(HUE_0, 0)], [0, 1], gc, gc) {
        ctx.drawRadialGradient(g, startCenter: gc, startRadius: 0, endCenter: gc,
                               endRadius: 0.34 * hb.width,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    let band = path([CGPoint(x: X0, y: ysvg(X0 + SIDE * 0.63)),
                     CGPoint(x: X0 + SIDE, y: ysvg(X0 + SIDE * 0.44)),
                     CGPoint(x: X0 + SIDE, y: ysvg(X0 + SIDE * 0.65)),
                     CGPoint(x: X0, y: ysvg(X0 + SIDE * 0.86))])
    ctx.saveGState(); ctx.addPath(band); ctx.clip()
    let bp0 = CGPoint(x: X0, y: 0), bp1 = CGPoint(x: X0 + SIDE, y: 0)
    if let g = grad([srgb(HUE_1, 0), srgb(HUE_1, 0.30), srgb(HUE_1, 0)], [0, 0.5, 1], bp0, bp1) {
        ctx.drawLinearGradient(g, start: bp0, end: bp1,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

// ── 图形本体：一次画实色，一次画纯白遮罩（后者只用来喂辉光）────
func drawGlyph(_ ctx: CGContext, mask: Bool) {
    func ink(_ c: CGColor) -> CGColor { mask ? srgb(0xFFFFFF, CIColor(cgColor: c).alpha) : c }

    strokeRing(ctx, RING_W, mask: mask)
    for p in [path(TRI), path(BODYQ)] { fillHue(ctx, p, p.boundingBoxOfPath, mask: mask) }
    for r in [HANDLE, LID] {
        fillHue(ctx, CGPath(roundedRect: r, cornerWidth: r == HANDLE ? 9 : 12,
                            cornerHeight: r == HANDLE ? 9 : 12, transform: nil), r, mask: mask)
    }

    // 管子内壁那条亮芯：宽度不到管径一半，留出两侧渐变
    ctx.saveGState()
    ctx.addPath(RING); ctx.setLineCap(.round); ctx.setLineWidth(24)
    ctx.setStrokeColor(ink(srgb(CORE, 0.92))); ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setLineJoin(.round); ctx.setLineWidth(5)
    ctx.setStrokeColor(ink(srgb(CORE, 0.5)))
    for p in [path(TRI), path(BODYQ)] { ctx.addPath(p); ctx.strokePath() }
    for r in [HANDLE, LID] {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r == HANDLE ? 9 : 12,
                           cornerHeight: r == HANDLE ? 9 : 12, transform: nil))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func glyphMask(_ px: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: CGFloat(px) / C, y: CGFloat(px) / C)
    ctx.setAllowsAntialiasing(true)
    drawGlyph(ctx, mask: true)
    return ctx.makeImage()
}

func over(_ top: CIImage, _ bottom: CIImage) -> CIImage {
    let f = CIFilter(name: "CISourceOverCompositing")!
    f.setValue(top, forKey: "inputImage")
    f.setValue(bottom, forKey: "inputBackgroundImage")
    return f.outputImage ?? bottom
}

/// 遮罩 → 高斯 → 按颜色与不透明度重着色，得到一层外发光
func glowLayer(_ src: CIImage, _ sigma: CGFloat, _ color: UInt32, _ opacity: CGFloat) -> CIImage {
    let b = src.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": sigma])
    let c = CIColor(cgColor: srgb(color))
    return b.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: c.red, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: c.green, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: c.blue, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
}

func renderBig() -> CGImage? {
    let px = C * SS
    guard let ctx = CGContext(data: nil, width: Int(px), height: Int(px), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let mask = glyphMask(Int(px)) else { return nil }
    let k = px / C
    ctx.scaleBy(x: k, y: k)
    ctx.setAllowsAntialiasing(true)
    drawBackdrop(ctx)
    // 底板自贴一次不是笔误：source-over 叠自己会让半透明像素 α'=2α−α²，
    // 于是圆角外沿那一圈抗锯齿被叠实。投票页那四项实测数就是带着这一层量的，
    // 去掉它边缘会偏淡。
    if let base = ctx.makeImage() { ctx.draw(base, in: CGRect(x: 0, y: 0, width: C, height: C)) }

    let ciBase = CIImage(cgImage: ctx.makeImage()!)
    let ciMask = CIImage(cgImage: mask)
    var out = ciBase
    if ProcessInfo.processInfo.environment["ICON_NOGLOW"] == nil {
        out = over(glowLayer(ciMask, SIGMA_WIDE * SIG * k, HUE_1, 0.40), out)
        out = over(glowLayer(ciMask, SIGMA_TIGHT * SIG * k, HUE_0, 0.75), out)
    }
    out = over(ciMask, out)
    guard let cg = CIF.createCGImage(out.cropped(to: ciBase.extent), from: ciBase.extent) else { return nil }

    // 实色图形与冷白描边压在辉光之上，且用矢量重画一遍（遮罩只当辉光的原料）
    guard let final = CGContext(data: nil, width: Int(px), height: Int(px), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    final.draw(cg, in: CGRect(x: 0, y: 0, width: Int(px), height: Int(px)))
    final.scaleBy(x: k, y: k)
    drawGlyph(final, mask: false)

    final.saveGState()
    let rb = plateRect.insetBy(dx: 1, dy: 1)
    final.addPath(CGPath(roundedRect: rb, cornerWidth: RX - 1, cornerHeight: RX - 1, transform: nil))
    final.setLineWidth(2)
    let rp0 = CGPoint(x: rb.minX, y: rb.maxY), rp1 = CGPoint(x: rb.minX + 0.6 * rb.width, y: rb.minY)
    if let g = grad([srgb(EDGE, 0.85), srgb(EDGE, 0.10), srgb(RIM_END, 0.30)], [0, 0.55, 1], rp0, rp1) {
        final.replacePathWithStrokedPath(); final.clip()
        final.drawLinearGradient(g, start: rp0, end: rp1,
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    final.restoreGState()
    return final.makeImage()
}

// 覆盖率低于 TINY_ALPHA 的像素，颜色分量已经不可回收：预乘缓冲里它们只剩几个单位，
// 而写 PNG 要做 直 = 预乘 ÷ (α/255) 的还原，α=2 时等于把噪声放大 128 倍，
// 落进 icns 就是 16/32 档那几颗红/白噪点。所以在预乘空间里直接把它们抹成 0。
// 实测代价：十档合计 311 / 1,726,720 个像素被动，合成后亮度差最大 7/255。
let TINY_ALPHA: UInt8 = 8

func writePNG(_ img: CGImage, _ dst: String) {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let buf = ctx.data else { exit(1) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in stride(from: 0, to: w * h * 4, by: 4) where p[i + 3] < TINY_ALPHA {
        p[i] = 0; p[i + 1] = 0; p[i + 2] = 0
    }
    guard let clean = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL,
                                                    "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, clean, nil)
    if !CGImageDestinationFinalize(dest) { exit(1) }
}

/// 逐级折半（一次 `draw` 到任意小尺寸会出锯齿，Small 档就靠这条撑住）
func downsample(_ img: CGImage, _ to: Int) -> CGImage? {
    var cur = img
    var w = cur.width
    while w / 2 >= to {
        w /= 2
        guard let c = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(cur, in: CGRect(x: 0, y: 0, width: w, height: w))
        guard let n = c.makeImage() else { return nil }
        cur = n
    }
    guard let c = CGContext(data: nil, width: to, height: to, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.interpolationQuality = .high
    c.draw(cur, in: CGRect(x: 0, y: 0, width: to, height: to))
    return c.makeImage()
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
let outDir = args.count > 1 ? args[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
guard let big = renderBig() else {
    FileHandle.standardError.write("合成失败\n".data(using: .utf8)!); exit(1)
}
for s in sizes {
    guard let img = downsample(big, s.px) else {
        FileHandle.standardError.write("缩放失败 \(s.name)\n".data(using: .utf8)!); exit(1)
    }
    let out = URL(fileURLWithPath: outDir).appendingPathComponent(s.name).path
    writePNG(img, out)
    print("    \(s.name)  \(s.px)px")
}
print("    合成于 \(big.width)px 后逐级折半")
