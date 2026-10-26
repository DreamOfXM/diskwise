import Foundation
import Darwin

// ── 签名发现：引擎自管缓存不靠名单认，靠布局认 ──
//
// 知识库是词典，不是扫描名单：App 数据删了丢什么只有人知道，词条继续人工维护；
// 但引擎自管缓存的语义由布局本身保证——HuggingFace 布局的模型仓无论长在
// ~/.cache/huggingface 还是某个项目的 var/tts-engine/hf 里，删了都是「下次重下」。
// 这一层让发现不再随工具爆发而过期：新引擎、新项目、被 HF_HOME 挪走的缓存，
// 都按「长什么样」当场认出，不用等谁补词条。
//
// 契约不变：签名推导的 tier 封顶 redo、exact 恒为 false——agent 通道仍然
// 只动知识库认识的本体（redo 非 exact 走 not_a_known_location，与缓存目录里
// 用户自建文件夹同一档），人经 --i-am-human 照旧能带走。
// 本文件面向 agent 输出的字符串一律英文，与 AgentAPI 同一条 l10n 纪律。

/// 一类引擎自管缓存的布局签名。
public enum SignatureKind: String, Codable {
    /// huggingface_hub 布局的模型仓：目录下有 models--* 条目和 blobs/ 目录。
    /// HuggingFace 与 ModelScope 都用这一约定；模型仓本体删了由引擎重下。
    case engineModelCache = "engine_model_cache"
    /// 散装的模型权重文件（.safetensors / .gguf / .ggml），按目录聚合过阈值才算。
    case modelWeights = "model_weights"
    /// Electron/Squirrel 约定的更新器下载缓存：目录名以 -updater 结尾，
    /// 只在家目录的 Caches 树里认，别处同名不算。
    case updaterCache = "updater_cache"
}

/// 一次签名命中的完整描述。
public struct SignatureMatch {
    public let url: URL
    public let kind: SignatureKind
    /// 合成词条：英文四句。agentItem 的 en 查表查不到英文原文，原样透传。
    public let entry: SafetyEntry
    /// 这一类应出现在哪些 --category 里（.all 由调用方兜底，不列在这里）。
    public let categories: [AgentCategory]
}

/// 散装权重文件的聚合门槛：低于它的目录不值得作为一条账报出来。
public let signatureWeightsThreshold: Int64 = 100 * MB

/// 签名走查不进的目录：里面不会有引擎自管缓存，但会有几十万个小文件。
private let signaturePruneNames: Set<String> = [
    ".git", "node_modules", ".build", "DerivedData", ".Trash",
    ".venv", "venv", "__pycache__", ".pnpm-store", ".gradle",
]

/// 签名走查的最大深度：真实引擎缓存都在十层以内，再深只费时间。
private let signatureMaxDepth = 12

/// 合成词条：布局即语义，四句话由签名本身给出，不需要人工维护。
private func synthesizedEntry(_ kind: SignatureKind, path: String) -> SafetyEntry {
    switch kind {
    case .engineModelCache:
        return SafetyEntry(
            name: "Engine model cache (hub layout)",
            what: "A model cache managed by its engine (huggingface_hub layout: models--* entries plus blobs/), wherever the engine put it — home cache or inside a project",
            whatif: "Cached models are removed; nothing else is touched",
            rec: "No recovery needed: the engine re-downloads models the next time they are used",
            path: path, level: "warn", cost: "redo", grp: "dev", docs: nil,
            app: nil, tags: ["ai_models"], icon: nil)
    case .modelWeights:
        return SafetyEntry(
            name: "Model weight files (.safetensors/.gguf/.ggml)",
            what: "Loose model weight files aggregated per directory",
            whatif: "The weight files are removed; anything else in the directory stays",
            rec: "Re-download or re-export the weights if they are needed again",
            path: path, level: "warn", cost: "redo", grp: "dev", docs: nil,
            app: nil, tags: ["ai_models"], icon: nil)
    case .updaterCache:
        return SafetyEntry(
            name: "Updater download cache (*-updater)",
            what: "Download cache of an Electron-style auto-updater (directory name ends with -updater)",
            whatif: "Already-downloaded update packages are removed; the installed app is untouched",
            rec: "No recovery needed: the updater downloads a fresh package on the next update",
            path: path, level: "safe", cost: nil, grp: "general", docs: nil,
            app: nil, tags: nil, icon: nil)
    }
}

private func signatureCategories(_ kind: SignatureKind) -> [AgentCategory] {
    switch kind {
    case .engineModelCache, .modelWeights: return [.aiModels, .dev]
    case .updaterCache: return [.apps]
    }
}

/// pathExtension 不带点，这里也不带点——两边口径必须一致，带了点永远匹配不上。
private let weightExtensions: Set<String> = ["safetensors", "gguf", "ggml"]

/// 单个路径的签名判定（agentPipeline 的兜底与自检共用）。
/// 只看这一层目录的浅表：列一次目录、看名字、量权重文件，不递归。
public func signatureMatch(_ url: URL, minWeightsBytes: Int64 = signatureWeightsThreshold) -> SignatureMatch? {
    var st = stat()
    guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
    guard let kids = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }

    // 引擎模型仓：models--* 与 blobs/ 同层出现才算，两重信号压误报。
    let hasModelDirs = kids.contains { $0.hasPrefix("models--") }
    if hasModelDirs && kids.contains("blobs") {
        return SignatureMatch(url: url, kind: .engineModelCache,
                              entry: synthesizedEntry(.engineModelCache, path: url.path),
                              categories: signatureCategories(.engineModelCache))
    }

    // 更新器缓存：名字带 -updater 不够，还得真的住在 Caches 树里。
    if url.lastPathComponent.hasSuffix("-updater"),
       url.path.contains("/Caches/") {
        return SignatureMatch(url: url, kind: .updaterCache,
                              entry: synthesizedEntry(.updaterCache, path: url.path),
                              categories: signatureCategories(.updaterCache))
    }

    // 散装权重：这一层目录里的权重文件按 st_blocks 累加过线才算一条账。
    var weights: Int64 = 0
    for k in kids {
        guard weightExtensions.contains((k as NSString).pathExtension.lowercased()) else { continue }
        var fs = stat()
        guard lstat(url.appendingPathComponent(k).path, &fs) == 0 else { continue }
        weights += Int64(fs.st_blocks) * 512
    }
    if weights >= minWeightsBytes {
        return SignatureMatch(url: url, kind: .modelWeights,
                              entry: synthesizedEntry(.modelWeights, path: url.path),
                              categories: signatureCategories(.modelWeights))
    }
    return nil
}

/// 签名走查：从给定根（默认家目录 + HF 系环境变量指向的位置）广度优先找
/// 引擎自管缓存。命中即停（不再下钻），目录换卷不跟、读不动不报错。
public func signatureScan(roots: [URL]? = nil,
                          minWeightsBytes: Int64 = signatureWeightsThreshold) async -> [SignatureMatch] {
    var base: [URL] = []
    if let roots, !roots.isEmpty {
        base = roots
    } else {
        base = [homeDir()]
        // 引擎官方的重定位机制读进来：用户把缓存挪到外盘/项目里，固定路径
        // 词条追不上，环境变量是引擎自己留的地址。
        for key in ["HF_HOME", "HF_HUB_CACHE", "TRANSFORMERS_CACHE", "MODELSCOPE_CACHE"] {
            guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { continue }
            let u = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                base.append(u)
            }
        }
    }

    let device = deviceOf(base[0])
    var out: [SignatureMatch] = []
    var queue = [(url: URL, depth: Int)](base.filter { deviceOf($0) == device }.map { ($0, 0) })
    while !queue.isEmpty {
        let (dir, depth) = queue.removeFirst()
        if let m = signatureMatch(dir, minWeightsBytes: minWeightsBytes) {
            out.append(m)
            continue    // 命中即剪枝：模型仓里面的子模型仓还是同一笔账
        }
        guard depth < signatureMaxDepth,
              let kids = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
        for k in kids.sorted() {
            let child = dir.appendingPathComponent(k, isDirectory: true)
            var st = stat()
            guard lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard deviceOf(child) == device else { continue }    // 不顺挂载点爬进别人的盘
            let name = child.lastPathComponent
            if signaturePruneNames.contains(name) { continue }
            // 家目录下的 Library 只进 Caches 一层：CoreSimulator 一个目录就几十万条目，
            // 而引擎缓存不会住在 Library 深处（那些归知识库词条管）。
            if depth == 0, dir.path == homeDir().path, name == "Library" {
                let caches = child.appendingPathComponent("Caches", isDirectory: true)
                var isDir = ObjCBool(false)
                if FileManager.default.fileExists(atPath: caches.path, isDirectory: &isDir), isDir.boolValue {
                    queue.append((caches, depth + 1))
                }
                continue
            }
            queue.append((child, depth + 1))
        }
    }
    return out
}
