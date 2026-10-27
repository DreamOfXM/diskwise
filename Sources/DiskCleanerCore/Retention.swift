import Foundation
import SQLite3

// MARK: - 保留策略与修剪（PR-4）
//
// 设计出处：plans/design-diagnostic-dumps-velocity-provenance-2026-10-27.md §6，
// 评审修订 §3.1：预览数字来自纯计算即终稿；执行前逐项核对 dev/ino，
// 与预览不一致的跳过并报告（学 agent 通道 execute 的先例）。
// 不做自动修剪——「保留策略＋自动执行」就是隐形守护进程，违背无守护进程承诺。

/// 再生类别的保留策略。nil = 不启用（默认）。
public struct Retention: Equatable {
    public enum Kind: Equatable {
        case count(Int)
        case bytes(Int64)
    }
    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// 修剪名单里的一行。dev/ino 在执行时复核——预览和执行之间文件可能被换掉。
public struct TrimFile: Equatable {
    public let url: URL
    public let size: Int64
    public let dev: Int
    public let ino: Int

    public init(url: URL, size: Int64, dev: Int, ino: Int) {
        self.url = url
        self.size = size
        self.dev = dev
        self.ino = ino
    }
}

/// 纯计算出的修剪计划：预览即终稿，确认后不重算。
public struct TrimPlan: Equatable {
    public let keep: Int
    public let remove: [TrimFile]
    public let oldestKeptMtime: Date?

    public var removeBytes: Int64 { remove.reduce(0) { $0 + $1.size } }

    public init(keep: Int, remove: [TrimFile], oldestKeptMtime: Date?) {
        self.keep = keep
        self.remove = remove
        self.oldestKeptMtime = oldestKeptMtime
    }
}

/// 枚举可清理面里的 .dmp 文件，按 mtime 保留最新一份，其余进修剪名单。
/// 只看结构不读内容；执行方复核 dev/ino。
public func trimPlan(under dirs: [URL], retention: Retention) -> TrimPlan {
    let fm = FileManager.default
    struct Meta { let url: URL; let size: Int64; let mtime: Date; let dev: Int; let ino: Int }
    var metas: [Meta] = []
    for d in dirs {
        guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
        for n in names where (n as NSString).pathExtension.lowercased() == "dmp" {
            let u = d.appendingPathComponent(n)
            var st = stat()
            guard lstat(u.path, &st) == 0 else { continue }
            metas.append(Meta(url: u, size: Int64(clamping: st.st_size),
                              mtime: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)),
                              dev: Int(st.st_dev), ino: Int(st.st_ino)))
        }
    }
    metas.sort { $0.mtime > $1.mtime }   // 新的在前
    func keptCount() -> Int {
        switch retention.kind {
        case .count(let n): return min(max(n, 0), metas.count)
        case .bytes(let cap):
            var acc: Int64 = 0
            var c = 0
            for m in metas where acc < cap {
                acc += m.size
                c += 1
            }
            return c
        }
    }
    let keepCount = keptCount()
    let kept = metas.prefix(keepCount)
    let drop = metas.dropFirst(keepCount)
    return TrimPlan(keep: keepCount,
                    remove: drop.map { TrimFile(url: $0.url, size: $0.size, dev: $0.dev, ino: $0.ino) },
                    oldestKeptMtime: kept.last?.mtime)
}

// MARK: - 保留策略存取（UserDefaults 两个键：enabled + count）

public func crashRetention() -> Retention? {
    let d = UserDefaults.standard
    guard d.bool(forKey: "retention.crash-dumps.enabled") else { return nil }
    let n = d.integer(forKey: "retention.crash-dumps.count")
    return Retention(kind: .count(n > 0 ? n : 2_000))
}

public func setCrashRetention(_ r: Retention?) {
    let d = UserDefaults.standard
    guard let r, case .count(let n) = r.kind else {
        d.set(false, forKey: "retention.crash-dumps.enabled")
        return
    }
    d.set(true, forKey: "retention.crash-dumps.enabled")
    d.set(n, forKey: "retention.crash-dumps.count")
}

// MARK: - 修剪账本（整批撤销用，落在快照库里）

extension SnapshotStore {
    /// 记一批修剪。original/trash 成对入账，撤销时逐对搬回。
    public func recordTrim(batchID: String, at: Date, entryKey: String,
                    items: [(original: URL, trash: URL, bytes: Int64)]) {
        guard db != nil else { return }
        exec("BEGIN")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO trim_batches VALUES(?,?,?,?,?)",
                                 -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK"); return }
        sqlite3_bind_text(stmt, 1, batchID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, at.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, entryKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, Int64(items.count))
        sqlite3_bind_int64(stmt, 5, items.reduce(0) { $0 + $1.bytes })
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard sqlite3_prepare_v2(db, "INSERT INTO trim_items VALUES(?,?,?)",
                                 -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK"); return }
        for it in items {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, batchID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, it.original.path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, it.trash.path, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
    }

    /// 撤销一整批：把废纸篓里的原路搬回。搬不回的（用户已清空）跳过并计数。
    /// 返回 (restored, missing)。
    public func undoTrim(batchID: String) -> (restored: Int, missing: Int) {
        guard db != nil else { return (0, 0) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT original, trash FROM trim_items WHERE batchID = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        sqlite3_bind_text(stmt, 1, batchID, -1, SQLITE_TRANSIENT)
        var pairs: [(URL, URL)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            pairs.append((URL(fileURLWithPath: String(cString: sqlite3_column_text(stmt, 0))),
                          URL(fileURLWithPath: String(cString: sqlite3_column_text(stmt, 1)))))
        }
        sqlite3_finalize(stmt)
        let fm = FileManager.default
        var restored = 0
        var missing = 0
        for (original, trash) in pairs {
            guard fm.fileExists(atPath: trash.path) else { missing += 1; continue }
            try? fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: trash, to: original)) != nil {
                restored += 1
            } else {
                missing += 1
            }
        }
        if restored > 0 || missing >= pairs.count {
            exec("DELETE FROM trim_items WHERE batchID = '\(batchID)'")
            exec("DELETE FROM trim_batches WHERE batchID = '\(batchID)'")
        }
        return (restored, missing)
    }
}
