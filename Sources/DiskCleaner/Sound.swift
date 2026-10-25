import AppKit
import AVFoundation
import SwiftUI

// ── 界面上那几声 ────────────────────────────────────────────────────────────
//
// 整套声音**离线合成**：包里没有一条音频文件、运行时不联网。参数逐条照抄样稿
// `diskwise-v2.6-crystal.html` 的 `SFX_CONF`（2026-10-19 那一稿，用户听到的就是它）：
//
// - 咔哒：一小段带通白噪，指数衰减。`tick` 是悬停换段，`arm` 是上膛，
//   `snap` 的第一层是按下。
// - 正弦下滑（`sub`）：上膛、收拢、撤销、扫描结束各有一条。
// - 带通噪声扫频（`sweep`）：扫描开始、预览。
// - 一串上行的水珠（`ripple` → `plink`）：收拢那一下，像水被吸走；天亮和
//   响指的第三层现在也走这一条。
// - 四音和弦（`chord`）：落定之后「天亮」，130.81/196/261.63/392 Hz。
//
// **样稿里那条一直在响的背景床（`SFX_CONF.ambient`）在这套里没有。** 见下面
// 「与样稿不同」的第二、三条——它是被删掉的，不是没做过。
//
// 为什么自己合成、不挂音频资源：
// 1. 这几声的形状全在几个数里（频率、Q、包络），换成文件反而失去可调性；
// 2. 离线算一次只要几十毫秒，且能放在后台算——交互那一下只是往一条空闲轨上
//    递一块已经算好的 PCM。**一次点击不许为了出声再合成一遍**，那是掉帧的来路。
//
// 与样稿不同的四处：
// - 随机数用固定种子：同一台机器上每次「收拢」听起来完全一样，取证时声音不是变量。
// - 不做浏览器的「首次点击解锁」：桌面 App 没有那条限制，`warmUp` 在开机算完 PCM
//   之后就把渲染线程转起来，第一次点击不用去付 `engine.start()` 那一笔开机的钱。
// - **样稿那条循环背景床整条删了**。它写的是 `SFX_CONF.ambient`：粉噪过三道带通
//   （190 / 960 / 2400 Hz）+ 0.073 Hz 的慢起伏，App 一打开就铺上、一直响。用户
//   2026-10-24 连着说了两次——「背景声音一直跟那打枪一样一直不停，我们不是只有
//   点击回收时才有声音吗」，随后定的是「按你的方案只保留点击声」。所以这套里
//   **没有循环轨**：出声只跟着交互走，不点就不响。
//   记一句走过的弯：第一版没有删它，只把它的密度降下来（4.3 次/秒的尖锐瞬态 →
//   疏一倍、慢一倍）。他还是读成「打枪」，因为只要有一条不停的东西在响，那 4.3
//   次/秒就是内容本身，调疏密只是把枪声放慢。**这一层的毛病在"它不停"，不在"它太密"。**
// - **回收那一趟从头到尾不掺噪声**（同一条要求：「轻灵的水声，不要白噪音之类的」）。
//   原来带噪声的是四处：背景床（粉噪）、收拢那 13 颗（带通白噪）、天亮垫的那条
//   1.5 秒上扫、响指垫的那条 0.46 秒上扫。背景床整条删掉，其余三处换成 `plink`
//   （下滑的基频 + 二次分音 + 一条慢尾）。噪声的频谱摊在整段上，耳朵读到的是
//   空调和风，不是水。
//   还留噪声的只剩两类，都不在回收那一趟里：短促的「咔哒」（悬停、上膛、撤销、
//   扫描结束——它们报的是机械动作，几十毫秒，听不出「嘶」）和扫描/预览那两条扫频。
//   「有没有噪声」这一条按结构保证：整套里只有 `click`/`sweep` 读噪声样本，判据与
//   试过又反着走的那个频谱数都记在 `Synth.meter` 头上。

/// 一条可以播的声音。名字与样稿的 cue 表一一对应。
enum SoundCue: CaseIterable {
    case tick, tickStrong, arm, gather, snap, preview, dawn, undo, scanStart, scanEnd
}

final class Sound {
    static let shared = Sound()

    /// 主音量。样稿 `SFX_CONF.master`。
    private static let master: Float = 0.92

    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var buffers: [SoundCue: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: Synth.rate, channels: 1)!

    /// 合成队列。算完才把这些缓冲区交给主线程——`ready` 只在主线程写。
    private let queue = DispatchQueue(label: "diskwise.sound.synth", qos: .userInitiated)
    private var ready = false
    private var enabled = true

    private init() {
        engine.mainMixerNode.outputVolume = Self.master
        // 四条轨轮流用：响指（0.5 s）与收拢（0.45 s）会叠在一起，
        // 再加上「天亮」那条 3.4 s 的长和弦，四条足够，也不必为每一发新建节点。
        for _ in 0..<4 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            voices.append(node)
        }
    }

    /// 开机时喊一次：把十秒左右的 PCM 在后台算好。
    /// 算完不自动出声——出声只跟着点击走（见 `play`）。
    func prepare(enabled: Bool) {
        self.enabled = enabled && !SnapshotMode.active
        queue.async { [weak self] in
            guard let self else { return }
            var made: [SoundCue: AVAudioPCMBuffer] = [:]
            for cue in SoundCue.allCases {
                if let b = Synth.buffer(for: cue, format: self.format) { made[cue] = b }
            }
            DispatchQueue.main.async {
                self.buffers = made
                self.ready = true
                self.warmUp()
            }
            if ProcessInfo.processInfo.environment["DISKWISE_SOUND_METER"] != nil {
                var lines: [String] = []
                for cue in SoundCue.allCases {
                    if let b = made[cue] { lines.append(Synth.meter("\(cue)", b)) }
                }
                FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
            }
        }
    }

    /// 引擎预热。`SnapshotMode` 那一趟整套静音：连拍十几张图时每一页都响一声，
    /// 拍完耳朵里只剩这些声音，还挡着听别的。
    /// 这里只干一件事：把渲染线程先转起来。第一次点击不该去付 `engine.start()`
    /// 那一笔开机的钱——`fire` 里那句是兜底，不是主路。
    private func warmUp() {
        guard !SnapshotMode.active else { return }
        if !engine.isRunning {
            do { try engine.start() } catch {
                // 拿不到音频输出（没设备、被别的进程独占）时整套静默退场：
                // 界面上的开关照旧可点，只是没有声音。为此弹一个错误框不值得。
                return
            }
        }
    }

    /// 开关。关的时候把主音量压到 0 并停掉渲染线程：静音不该占着音频输出。
    func setEnabled(_ on: Bool) {
        enabled = on
        guard ready, !SnapshotMode.active else { return }
        engine.mainMixerNode.outputVolume = on ? Self.master : 0
        if on {
            if !engine.isRunning { try? engine.start() }
            play(.tickStrong)
        } else {
            engine.pause()
        }
    }

    /// 播一条。`delay` 只给那些要跟动效对拍的声音用（收拢 / 天亮）——
    /// 它们由主线程排一个定时，精度到毫秒级就够，不必去碰播放器节点的采样时钟。
    func play(_ cue: SoundCue, after delay: TimeInterval = 0) {
        guard enabled, !SnapshotMode.active else { return }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fire(cue)
            }
        } else {
            fire(cue)
        }
    }

    private func fire(_ cue: SoundCue) {
        guard ready, enabled, let buffer = buffers[cue] else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let node = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        // 这一条轨上一条还没放完就算了：声音叠到第五层只会糊成一团，
        // 而这里丢掉的是「上一声的尾巴」，不是这一下要报的事。
        node.stop()
        node.scheduleBuffer(buffer)
        node.play()
    }
}

// MARK: - 开关

/// 顶栏那颗「声音」。图标与那粒灯色小点照抄样稿：开着的时候点常亮，
/// 关掉之后只剩一个斜杠喇叭。没有悬停动画、没有脉冲——它挂在工具条上，
/// 而工具条每一次重画都是整条标题带的重排。
struct SoundToggle: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Button {
            prefs.setSound(!prefs.soundEnabled)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: prefs.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 11, weight: .medium))
                // 样稿 `.tb-right` 那三颗都是「图标 + 词」的胶囊，只有这颗在真机上退成了
                // 一个裸图标：静音状态下它画的是 `speaker.slash`，那支符号自己说的是
                // 「没声」，而人要点的是「有没有声」——差一个词就得先猜一次。
                Text(L("声音"))
                    .font(theme.bodyFont(.caption2))
                if prefs.soundEnabled {
                    Circle()
                        .fill(SweepRing.lamp(theme.palette.tint))
                        .frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(prefs.soundEnabled ? theme.palette.inkSecondary
                                                : theme.palette.inkTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("声音：扫描 / 上膛 / 收拢 / 天亮，各有一声"))
        .accessibilityLabel(L("声音"))
        .accessibilityValue(prefs.soundEnabled ? L("开") : L("关"))
    }
}

// MARK: - 合成

/// 离线合成器。纯函数 + 一块 `[Float]`，不碰 AVFoundation 之外的任何状态：
/// 这样同一份参数在测试里也能原样再算一遍。
enum Synth {
    /// 样稿那台 AudioContext 的采样率取 44.1 kHz。桌面输出 48 kHz 时
    /// `AVAudioEngine` 自己重采样，听感上没有区别。
    static let rate: Double = 44_100

    static func buffer(for cue: SoundCue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        pcm(samples(for: cue), format: format)
    }

    private static func pcm(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    // MARK: 边界

    /// 一次性量具（`DISKWISE_SOUND_METER`）。只有「安静帧」这一列还活着，它管**密度**：
    /// 一路水珠之间得有空，糊成一面墙的没有空。这一列是为 2026-10-24 那句「背景声音
    /// 一直跟那打枪一样一直不停」加的——它读到的正是"每秒好几下、中间没空"。注意它管不了
    /// 收拢那一串：13 颗按 75 ms 排开、每颗的尾就盖住下一颗的头，结构上不可能有空档，
    /// 那一列读 0% 不代表又是墙。
    ///
    /// **这一列量不出「有没有噪声」，别再往这儿加频谱判据。** 2026-10-24 试过九条对数等距带的
    /// 几何均值÷算术均值，指望「纯音只填一两条带、噪声摊满九条」，实测直接反过来：
    /// 收拢（13 颗纯水珠）0.654、背景床（删之前量的）0.519，而 1.7 秒纯带通噪声的扫描开始只 0.425、
    /// 16 ms 带通白噪的悬停 0.234。`plink` 自己就是宽的——基频头 30 ms 滑掉近一个八度、
    /// 挂着二次分音和一条五度慢尾，一串的基频又排到 640…2100 Hz，摊得比噪声还开；整段平均
    /// 把「时间上摊开」当成了「瞬时频谱摊开」。数既然反着走，留着只会指错路，已删。
    ///
    /// 「不掺噪声」这一条靠**结构**保证，不靠量：整套合成里只有 `click` 和 `sweep` 两个原语
    /// 读噪声样本，回收那一趟的三处（`gather`、`snap`、`dawn`）现在一条都不调它们，
    /// 只调 `plink`/`sub`/`chord`。剩下的噪声只出现在悬停、上膛、撤销、扫描结束那几个几十毫秒
    /// 的「咔哒」和扫描/预览的两条扫频里。听感归用户判，判不动的别替他写进注释。
    static func meter(_ name: String, _ buffer: AVAudioPCMBuffer) -> String {
        guard let ch = buffer.floatChannelData?[0] else { return "sound \(name): 空" }
        let n = Int(buffer.frameLength)
        var peak = 0.0, sum = 0.0
        for i in 0..<n { let v = Double(ch[i]); sum += v * v; peak = max(peak, abs(v)) }
        let rms = (sum / Double(max(1, n))).squareRoot()
        let frame = Int(rate * 0.01)
        let floor = peak * 0.02
        var quiet = 0, frames = 0, i = 0
        while i + frame <= n {
            var s = 0.0
            for j in i..<(i + frame) { let v = Double(ch[j]); s += v * v }
            if (s / Double(frame)).squareRoot() < floor { quiet += 1 }
            frames += 1
            i += frame
        }
        return String(format: "sound %@: 时长 %.2fs rms %.4f 峰值 %.4f 安静帧 %.0f%%",  // l10n-scan: skip
                      name, Double(n) / rate, rms, peak,
                      frames > 0 ? Double(quiet) / Double(frames) * 100 : 0)
    }

    /// 固定种子。见文件头注：这不是「随机」变好听，是让同一段动作每次都一样。
    private struct RNG {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
    }

    /// RBJ 双二阶。样稿用 WebAudio 的 `BiquadFilterNode`，同一条公式。
    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        static func bandpass(_ freq: Double, _ q: Double) -> Biquad {
            let w = 2 * Double.pi * clamped(freq) / rate
            let alpha = sin(w) / (2 * max(0.05, q))
            let a0 = 1 + alpha
            return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0,
                          a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
        }

        private static func clamped(_ f: Double) -> Double { min(rate * 0.45, max(20, f)) }

        /// 换系数、留状态。扫频时每 32 个样本重算一次系数，直接整体赋新值会把
        /// 滤波器记忆一起清掉——那样每 32 个样本就有一声「哒」，比扫频本身还响。
        mutating func retune(_ next: Biquad) {
            b0 = next.b0; b1 = next.b1; b2 = next.b2; a1 = next.a1; a2 = next.a2
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    // MARK: 各条 cue

    // 2026-10-22 实测过一遍「到底有没有声」：临时把 11 条缓冲区（10 条 cue +
    // 当时还在的背景床，见文件头）的 rms / 峰值打到 stderr，条条非零。峰值与下面传进去的 `peak`
    // 对不齐是预期的——RBJ 带通只放过 f0 附近 f0/Q 那一条，`click` 的 Q=9 会
    // 吃掉约 10 倍（`tick` 设计 0.050 → 实测 0.0051，`scanStart` 0.05 → 0.0050），
    // 而 `sub` 是纯正弦、不经滤波，所以 `snap` 实测 0.2846 几乎等于设计的 0.30。
    // 样稿那台 WebAudio 用的是同一条公式，衰减一样，所以两边响度关系没变。

    private static func samples(for cue: SoundCue) -> [Float] {
        let seconds: Double
        switch cue {
        case .tick: seconds = 0.06
        case .tickStrong: seconds = 0.08
        case .arm: seconds = 0.34
        case .gather: seconds = 1.02
        case .snap: seconds = 0.56
        case .preview: seconds = 0.52
        case .dawn: seconds = 3.76
        case .undo: seconds = 0.36
        case .scanStart: seconds = 1.82
        case .scanEnd: seconds = 0.36
        }
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        var rng = RNG()

        switch cue {
        case .tick:
            click(&out, at: 0, peak: 0.050, freq: 2050, dec: 0.035, q: 9, rng: &rng)
        case .tickStrong:
            click(&out, at: 0, peak: 0.085, freq: 2750, dec: 0.050, q: 9, rng: &rng)
        case .arm:
            click(&out, at: 0, peak: 0.130, freq: 3200, dec: 0.016, q: 10, rng: &rng)
            click(&out, at: 0.072, peak: 0.090, freq: 2150, dec: 0.026, q: 9, rng: &rng)
            sub(&out, at: 0, from: 148, to: 66, dur: 0.26, peak: 0.14)
        case .gather:
            ripple(&out, at: 0, count: 13, step: 0.075, jitter: 0.014,
                   from: 640, stepFreq: 118, spreadFreq: 150,
                   peak: 0.030, peakStep: 0.0022, dur: 0.13, rng: &rng)
            sub(&out, at: 0, from: 92, to: 148, dur: 0.34, peak: 0.10)
        case .snap:
            click(&out, at: 0, peak: 0.30, freq: 1450, dec: 0.022, q: 4, rng: &rng)
            sub(&out, at: 0, from: 215, to: 46, dur: 0.28, peak: 0.30)
            // 稿子这第三层是 0.46 秒的带通噪声上扫（「唰」）。双击扇形这一拍属于回收，
            // 而回收那一趟现在一颗噪声样本都不许有——换成两颗跟着下滑走的水珠。
            plink(&out, at: 0.03, freq: 1150, dur: 0.15, peak: 0.055)
            plink(&out, at: 0.15, freq: 1560, dur: 0.13, peak: 0.040)
        case .preview:
            sweep(&out, at: 0, from: 1900, to: 320, dur: 0.46, peak: 0.055, q: 2.2, rng: &rng)
            sub(&out, at: 0, from: 180, to: 96, dur: 0.32, peak: 0.09)
        case .dawn:
            chord(&out, at: 0, freqs: [130.81, 196.00, 261.63, 392.00],
                  peak: 0.105, attack: 0.62, spread: 0.06, release: 3.4)
            // 原来垫在和弦底下的是一条 1.5 秒的带通噪声上扫。用户 2026-10-24 要的是
            // 「轻灵的水声，不要白噪音之类的」，这一条正是他说的那种东西。换成一串
            // 慢速上行的水珠：步距 0.16 秒，比收拢那 13 颗疏一倍，落在和弦还在抬起的
            // 那 0.62 秒里——最后几滴水追上去，不是底噪。
            ripple(&out, at: 0.10, count: 7, step: 0.16, jitter: 0.05,
                   from: 900, stepFreq: 145, spreadFreq: 190,
                   peak: 0.014, peakStep: 0.0018, dur: 0.22, rng: &rng)
        case .undo:
            sub(&out, at: 0, from: 330, to: 118, dur: 0.30, peak: 0.13)
            click(&out, at: 0.02, peak: 0.05, freq: 1650, dec: 0.05, q: 8, rng: &rng)
        case .scanStart:
            sweep(&out, at: 0, from: 170, to: 2700, dur: 1.7, peak: 0.05, q: 2.4, rng: &rng)
        case .scanEnd:
            sub(&out, at: 0, from: 126, to: 74, dur: 0.30, peak: 0.13)
            click(&out, at: 0, peak: 0.10, freq: 2450, dec: 0.032, q: 9, rng: &rng)
        }
        return out
    }

    /// 悬停与上膛的「咔」：带通白噪 + 指数衰减。样稿里那截白噪从一个随机
    /// 偏移开始读，这里用固定种子的新噪声——听感一样，取证可复现。
    private static func click(_ out: inout [Float], at t: Double, peak: Double, freq: Double,
                              dec: Double, q: Double, rng: inout RNG) {
        var filter = Biquad.bandpass(freq, q)
        let start = Int(t * rate)
        let n = Int(dec * rate)
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let envelope = peak * pow(0.0001 / peak, u)
            let value = filter.process(rng.unit()) * envelope
            let index = start + i
            if index >= 0 && index < out.count { out[index] += Float(value) }
        }
    }

    /// 正弦下滑。频率按指数走（WebAudio 的 `exponentialRampToValueAtTime`），
    /// 相位逐样本积分——直接拿当前频率去算 sin 会在换频时听到相位跳变。
    private static func sub(_ out: inout [Float], at t: Double, from f1: Double,
                            to f2: Double, dur: Double, peak: Double) {
        let start = Int(t * rate)
        let n = Int(dur * rate)
        let attack = min(0.014, dur * 0.5)
        var phase = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let f = f1 * pow(max(30, f2) / f1, u)
            phase += 2 * Double.pi * f / rate
            let tt = Double(i) / rate
            let envelope: Double
            if tt < attack {
                envelope = 0.0001 * pow(peak / 0.0001, tt / attack)
            } else {
                envelope = peak * pow(0.0001 / peak, (tt - attack) / max(0.001, dur - attack))
            }
            let value = sin(phase) * envelope
            let index = start + i
            if index >= 0 && index < out.count { out[index] += Float(value) }
        }
    }

    /// 带通噪声扫频。源是「棕噪」：功率随频率下降，比白噪厚，扫上去像一阵风
    /// 而不是一条嘶声。包络在 72% 处到顶，最后 30% 收到听不见。
    private static func sweep(_ out: inout [Float], at t: Double, from f1: Double,
                              to f2: Double, dur: Double, peak: Double, q: Double,
                              rng: inout RNG) {
        let start = Int(t * rate)
        let total = dur * 1.02
        let n = Int(total * rate)
        var filter = Biquad.bandpass(f1, q)
        var brown = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            if i % 32 == 0 {
                filter.retune(Biquad.bandpass(f1 * pow(f2 / f1, u), q))
            }
            let w = rng.unit()
            brown = (brown + 0.02 * w) / 1.02
            let noise = brown * 3.2
            let tt = Double(i) / rate
            let envelope: Double
            if tt < dur * 0.72 {
                envelope = 0.0001 * pow(peak / 0.0001, tt / max(0.001, dur * 0.72))
            } else {
                envelope = peak * pow(0.0001 / peak,
                                      (tt - dur * 0.72) / max(0.001, dur * 0.30))
            }
            let value = filter.process(noise) * envelope
            let index = start + i
            if index >= 0 && index < out.count { out[index] += Float(value) }
        }
    }

    /// 落定之后那枚和弦。四个正弦、依次张开、一起收到 3.4 秒。
    /// 高次分音按 `peak / (i + 1.4)` 压下去——四音等响会变成一声刺耳的叠音。
    private static func chord(_ out: inout [Float], at t: Double, freqs: [Double],
                              peak: Double, attack: Double, spread: Double, release: Double) {
        let start = Int(t * rate)
        for (i, freq) in freqs.enumerated() {
            let level = max(0.0002, peak / (Double(i) + 1.4))
            let open = attack + Double(i) * spread
            let n = Int(release * rate)
            var phase = 0.0
            for j in 0..<n {
                let tt = Double(j) / rate
                let envelope: Double
                if tt < open {
                    envelope = 0.0001 * pow(level / 0.0001, tt / max(0.001, open))
                } else {
                    envelope = level * pow(0.0001 / level,
                                           (tt - open) / max(0.001, release - open))
                }
                phase += 2 * Double.pi * freq / rate
                let value = sin(phase) * envelope
                let index = start + j
                if index >= 0 && index < out.count { out[index] += Float(value) }
            }
        }
    }

    /// 收拢：十三颗细小的水珠，一颗比一颗高一点、响一点，像一串水被吸走。
    ///
    /// 稿子这一条走的是带通白噪（`click`），听感是「咔咔」的沙沙——那是一串小撞击，
    /// 不是水。换成 `plink`：同一串上行轮廓、同一套间隔与抖动，只是每一颗改由
    /// 下滑的基频发声。播放的起点也从 `gatherAt` 挪到了 `releaseAt`——水珠真正离开
    /// 带面那一格，声音才跟着离开。
    private static func ripple(_ out: inout [Float], at t: Double, count: Int,
                               step: Double, jitter: Double, from: Double,
                               stepFreq: Double, spreadFreq: Double,
                               peak: Double, peakStep: Double, dur: Double,
                               rng: inout RNG) {
        for i in 0..<count {
            let at = t + Double(i) * step + rng.unit() * jitter
            let level = peak + Double(i) * peakStep
            let freq = from + Double(i) * stepFreq + rng.unit() * spreadFreq
            plink(&out, at: at, freq: freq, dur: dur, peak: level)
        }
    }

    /// 一颗水珠。三个分音全由振荡器算出来，一个噪声样本都不掺。
    ///
    /// 基频在头几十毫秒里往下滑一个八度（`0.50 + 0.50·e^(−t/30ms)`）——那一下「掉」
    /// 就是入水感，也是水声和「哔」的区别；二次分音跟着走、压到 0.30，底下再垫一条
    /// 五度左右的慢尾当腔体。
    ///
    /// 起手 4 ms 线性抬起：从 0 直接跳进正弦会在 t=0 留一个台阶，那个台阶就是一记
    /// 宽带「哒」——这一条存在的理由恰恰是不再有那种东西。
    private static func plink(_ out: inout [Float], at t: Double, freq: Double,
                              dur: Double, peak: Double) {
        let start = Int(t * rate)
        let n = Int(dur * rate)
        let attack = 0.004
        var ph1 = 0.0, ph2 = 0.0, ph3 = 0.0
        for i in 0..<n {
            let tt = Double(i) / rate
            let f = max(40, freq * (0.50 + 0.50 * exp(-tt / 0.030)))
            ph1 += 2 * Double.pi * f / rate
            ph2 += 2 * Double.pi * (f * 2.01) / rate
            ph3 += 2 * Double.pi * (f * 0.67) / rate
            let body = exp(-tt / (dur * 0.30)) + exp(-tt / (dur * 0.55)) * 0.26
            let swell = tt < attack ? tt / attack : 1
            let value = (sin(ph1) + sin(ph2) * 0.30 + sin(ph3) * 0.22)
                * body * swell * peak
            let index = start + i
            if index >= 0 && index < out.count { out[index] += Float(value) }
        }
    }
}
