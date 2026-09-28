import SwiftUI
import Combine
import DiskCleanerCore
import AppKit

// ── 空间总览：磁盘用量 + 主目录一级热点 ──
// 这一屏是磁盘清理类产品的门面，所以给了环形仪表：
// 一眼看清"整块盘被谁吃了"，比一根进度条有力得多。

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class OverviewModel: ObservableObject {
    @Published var usage: VolumeUsage? = nil
    @Published var hotspots: [(name: String, path: String, size: Int64)] = []
    /// 排在列表封顶之后、但确实量到了的目录。列表不画满一屏，点开设的那行全在里面。
    @Published private(set) var restHotspots: [(name: String, path: String, size: Int64)] = []
    /// 一行都没摊到的那部分：单项低于下限的目录数与合计。没有这两个数，
    /// 「其他已统计」那块弧就有一截是账外之地——环形加起来等于盘，列表却对不上。
    @Published private(set) var unlistedCount = 0
    @Published private(set) var unlistedBytes: Int64 = 0
    @Published var scanning = false
    /// 已经量完的目录数。环形要等全部量完才谈得上「未扫描」，所以这个数得露出来。
    @Published private(set) var done = 0
    @Published private(set) var pending = 0
    /// 扫过的目录合计占多少。环形的「未扫描」= 已用 − 这个数，整张图的口径全靠它。
    @Published private(set) var covered: Int64 = 0
    /// 这趟扫描里打不开的目录，按「缺哪种权限」分开。合并进一块就说不清哪块能要回来。
    @Published private(set) var needFDA: [String] = []
    @Published private(set) var needAdmin: [String] = []
    /// 正在量的目录名。列表必须「动起来」：一趟整盘扫描里最慢的根能跑几分钟，
    /// 只在有目录量完时才刷新，画面就会长时间一片空白，看着像点了没反应。
    @Published private(set) var measuring: [String] = []
    /// 这个进程实测有没有「完全磁盘访问权限」。授权是在系统设置里点的，macOS 要 App
    /// 退出重开才落到进程上，所以「扫描里报了几处 EPERM」不能当授权状态用——
    /// 那样会对着已经勾过的人说「点这个按钮去开」。每轮扫描开始时重测一次。
    @Published private(set) var hasFDA = false
    /// 整块盘按 APFS 卷拆开的账。nil = 这台机器拆不出（演示树、非 APFS），
    /// 那时「没量到的地方」只能整体归成一块，不硬编明细。
    @Published private(set) var split: VolumeSplit? = nil
    @Published private(set) var started = false
    /// 行内摊开的下一级，按父路径缓存。行视图会随滚动和导航重建，不缓存的话
    /// 每次滚回来都要重走一遍几十 G 的子树——那看着就像 App 卡死了。
    @Published private(set) var childRows: [String: [(name: String, path: String, size: Int64)]] = [:]
    @Published private(set) var childBusy: Set<String> = []
    private var childTasks: [String: Task<Void, Never>] = [:]
    private var task: Task<Void, Never>? = nil

    /// 小于这个数不进列表：家目录一级有上百个点目录，绝大多数是几 KB 的配置夹。
    static let sizeFloor: Int64 = 100 * MB
    /// 列表封顶。再长就没人逐行扫了，多出来的体积并进环形的「其他已统计」。
    static let listCap = 20
    /// 单行摊开后最多列几格下级。再往下就没人在读了，剩下的报一个合并数。
    static let childCap = 12

    // MARK: 环上的「本次移入废纸篓」账

    /// 被本工具搬进废纸篓、还没让位的那些字节（源路径 + 当时量到的大小）。
    /// 由视图从 `store.trashHistory` 整串推进来：模型摸不到 store，而这条账环形每帧都要读。
    /// 它是 @Published：删一刀之后环要跟着挪账，靠别的字段顺带重画是靠不住的。
    @Published private(set) var moved: [(original: String, bytes: Int64)] = []

    /// 每条弧的**水位线**：`[路径: 量完它那一刻已有几笔记录]`。序号在水位线之前的那些
    /// 已经作废（新尺寸本来就不含它们），之后的照常扣。用集合记「量过了」会把**量完之后**
    /// 新搬走的那些一起作废掉——清完一轮再点重新扫描，环上就再也长不出废纸篓那条弧。
    private var voidedUpTo: [String: Int] = [:]

    /// 这一轮量过的全部路径，含没进列表的那些（低于 `sizeFloor` 的也算「量到过」）。
    /// 归位要靠它：不传全，从一个小目录里清掉的几百 G 就归不进任何弧。
    private var targetPaths: [String] = []

    private var cachedLedger: RingLedger?

    /// 删完一刀（`store.record` 之后）、撤销一次、或清空废纸篓之后，把整条历史重新推一遍。
    /// 不增量记账：撤销链本来就是「历史短了」，重新归一次位弧就自己回滚，
    /// 模型里不会留下第二本跟 store 对不上的账。
    /// 内容没变就不发变更：这一串是每帧对照着推的，回回都发布会让整页白重画一次。
    func setMoved(_ records: [(original: String, bytes: Int64)]) {
        let same = records.count == moved.count && zip(records, moved).allSatisfy {
            $0.original == $1.original && $0.bytes == $1.bytes
        }
        guard !same else { return }
        moved = records
        // 撤销/清空历史会让整串变短，水位线得跟着退：不退的话，下一笔新记录（序号落在
        // 旧水位线之后）会被当成「量过了」而凭空作废。
        for key in voidedUpTo.keys { voidedUpTo[key] = min(voidedUpTo[key]!, records.count) }
        cachedLedger = nil
        // 搬走之后重归一次缓存账：已经不在原处的那几处不许再算进「还能腾出」，
        // 不然主按钮上的数会比它真能搬走的大，第二下按下去才发现差了一截。
        rebuildCacheTargets()
    }

    /// 那条「本次移入废纸篓」的弧有多大、每条热点弧被搬走了多少。
    ///
    /// 缓存是为了每帧重算的环形：一趟重复文件清理能留下几百条记录，每帧拿它们
    /// 跟几十个路径重比一遍是白烧 CPU。列表一变（扫描中名次会重排）就作废。
    var movedLedger: RingLedger {
        if let cachedLedger { return cachedLedger }
        let l = ringMoveLedger(records: moved,
                               topPaths: Array(hotspots.prefix(3)).map { $0.path },
                               otherPaths: targetPaths,
                               voidedUpTo: voidedUpTo)
        cachedLedger = l
        return l
    }

    /// 交给环形的两条扣减，钳在对应那条弧此刻的体积以内。
    ///
    /// 为什么会超：一轮扫描跑到一半被停掉，有的弧已经重新量过（搬走的字节早就不在里面了），
    /// 账本却还记着那一笔。不钳就是 Core 那道守卫直接不拆——「其他已统计」和「没量到」
    /// 两条弧当场消失，环形画成一张缺角的图，那比数字偏一点严重得多。
    var ringDeduction: (top: Int64, rest: Int64) {
        let led = movedLedger
        let topSum = Array(hotspots.prefix(3)).reduce(Int64(0)) { $0 + $1.size }
        return (min(led.topOut, topSum), min(led.restOut, max(0, covered - topSum)))
    }

    /// 某条热点弧此刻画多大：量到的减去已经从这条弧上搬走的。
    /// 搬走不等于腾出——磁盘「已用」一个字节都没少，所以这些字节只能在弧之间挪家。
    func arcSize(of path: String) -> Int64 {
        let size = (hotspots + restHotspots).first { $0.path == path }?.size ?? 0
        return max(0, size - movedLedger.out(of: path))
    }

    /// 没进列表的那些小目录，此刻还在原处的合计。
    ///
    /// 尾巴那句对账用它而不是 `unlistedBytes`：后者是这一轮量到的原始数，而
    /// 「其他已统计」那条弧已经减掉了搬走的部分——从一个小目录里清掉几百 G 时，
    /// 按原始数加就会加出一个比弧还大的三段。
    var unlistedNet: Int64 {
        let listed = Set((hotspots + restHotspots).map { $0.path })
        var gone: Int64 = 0
        for (path, bytes) in movedLedger.perOther where !listed.contains(path) { gone += bytes }
        return max(0, unlistedBytes - gone)
    }

    /// 这一行底下被搬走了多少。行上那句「已移入废纸篓 X」用它，跟弧上减掉的是同一个数。
    func movedOut(of path: String) -> Int64 { movedLedger.out(of: path) }

    /// 这条弧动得了多少 = 它名下**知识库点名为安全、且此刻还在原处**的那几处缓存。
    ///
    /// 只认知识库这一条来源，不认「这目录没进保护名单所以整段算能清」。后者在真机上量出来是：
    /// 家目录 161 项里 151 项通过，招牌画面于是许诺「125.9 GB 动得了」，而那一按下去搬的是
    /// 27 GB 的私人备份、`~/.qoder`、几个正在跑的工程目录。**行上给不给删除键**和
    /// **工具替不替你点齐**是两件事：前者是人一个个挑，后者是产品许的诺，只能按白名单许。
    /// 少报的代价是这一屏再补几轮知识库；错报的代价是用户的东西没了。
    func reclaimable(of path: String) -> Int64 {
        min(arcSize(of: path), cacheTargets[path]?.reduce(Int64(0)) { $0 + $1.size } ?? 0)
    }

    /// 某一处**子目录**名下动得了多少：把每一桶里落在它名下的那几处加起来。
    ///
    /// `reclaimable(of:)` 的键只有列表里那几行（弧对应的目录），而 `~/Library/Caches`
    /// 住在 `~/Library` 那一桶里。直接拿它去查会得到 0，于是父行写着「12.0 GB 可回收」、
    /// 它名下每一行都写着「只能看」——2026-09-26 实拍摊开的 `~/Library` 那一屏到的正是这个。
    /// 桶里的目标过 `dropNested`（父项已计就不重复加子项），跨桶相加因此不会双算。
    func reclaimableUnder(_ path: String) -> Int64 {
        var sum: Int64 = 0
        for ts in cacheTargets.values {
            for t in ts where t.path == path || t.path.hasPrefix(path + "/") { sum += t.size }
        }
        return sum
    }

    /// 这条弧上点名要搬走的那几处。`take` 只搬这里列出来的，一处不多。
    func reclaimTargets(of path: String) -> [ReclaimTarget] {
        cacheTargets[path] ?? []
    }

    // MARK: 缓存可回收账（来自缓存页那本知识库，同一趟体积统计）

    /// 「其他已统计」那条弧的归账键。它不对应某一个目录，所以不能用路径当键。
    /// 值住在 Core（`reclaimRestKey`）：它和 `reclaimBucket` 是一对约定，自检要钉得住。
    static let restBucketKey = reclaimRestKey

    /// 按弧归好的缓存可回收目标。键是弧对应的目录路径，`restBucketKey` 收其余的。
    private(set) var cacheTargets: [String: [ReclaimTarget]] = [:]

    /// 「其他已统计」那条弧名下、列表里真的有一行的那些行（第 4 名往后）。
    private var restRows: [String] {
        Array(hotspots.dropFirst(3).map { $0.path } + restHotspots.map { $0.path })
    }

    /// 那条弧上点名要搬走的每一处：列表里第 4 名往后的每一行名下知识库判安全的那几处，
    /// 加上没落进任何一行的那几处（`__rest__` 桶）。
    ///
    /// 这里曾有过第二条来源——「整段就能搬走的行记那一行本身」。它在演示树上看着对
    /// （`~/.npm`、`~/.m2` 确实能整段搬），搬到真机上就把用户的备份工程一并计进了承诺，
    /// 所以删掉：这条弧的数与下面列表尾巴那句「本工具动得了」现在同源于知识库，一处不多。
    func restReclaimTargets() -> [ReclaimTarget] {
        var t: [ReclaimTarget] = []
        for p in restRows { t.append(contentsOf: cacheTargets[p] ?? []) }
        t.append(contentsOf: cacheTargets[Self.restBucketKey] ?? [])
        return t
    }

    /// 那条弧动得了多少：点名要搬的合计，钳在弧此刻的体积以内（理由同 `reclaimable(of:)`）。
    func restReclaimable(_ arc: Int64) -> Int64 {
        min(max(0, arc), restReclaimTargets().reduce(0) { $0 + $1.size })
    }

    /// 应用缓存与开发缓存两台模型。环形认的是「知识库里量出来的那几处」，
    /// 不分页——少接一台，一键腾出的数就会少掉整个开发工具那一坨。
    /// 强引用不成环：两台模型都不回头指总览，而三方都由 `ScanStore` 持有。
    private var cachesModels: [CachesModel] = []
    private var cachesSubs: [AnyCancellable] = []

    /// 由 `ScanStore` 在构造时接线：缓存页每落地一处体积，这边重归一次账。
    /// 订阅而不是轮询：体积是一条条异步量完的，靠定时刷会出现「弧上刚亮起来、数还是旧的」。
    func bind(caches: [CachesModel]) {
        cachesModels = caches
        cachesSubs = caches.map { model in
            model.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.objectWillChange.send()
                    self?.rebuildCacheTargets()
                }
        }
    }

    /// 重新归一次缓存可回收账。扫描收尾、缓存体积落地、真搬走过东西，都要重跑这一趟。
    ///
    /// 三条规矩：
    /// 1. 只认知识库标 `safe` 的条目。`warn` 那些（整机备份、Docker 数据、废纸篓本身）
    ///    留给缓存页逐条勾着清，不进这颗一键按钮——那一按要搬十几处，不能拿它们赌。
    /// 2. 父项已计入就不重复加子项（`~/Library/Caches` 套着 `Homebrew` 是同一段字节）。
    /// 3. 按**列表里每一行**归，不只按前三名归——不然列表尾巴那句「能进废纸篓 / 只能看」
    ///    只能按「整处搬不搬得走」算，跟圆心上那个数当场打架。没落进任何一行的归到
    ///    `restBucketKey`，仍然算在「其他已统计」那条弧头上，一分不丢。
    func rebuildCacheTargets() {
        let fm = FileManager.default
        let rows = (hotspots + restHotspots).map { $0.path }
        var hits: [ReclaimTarget] = []
        for it in cachesModels.flatMap(\.items) {
            guard it.entry.level != "warn" else { continue }
            for (p, sz) in it.pathSizes where sz > 0 {
                guard isDeletable(URL(fileURLWithPath: p)) else { continue }
                guard fm.fileExists(atPath: p) else { continue }   // 已经搬走的不许再报
                hits.append(ReclaimTarget(path: p, size: sz))
            }
        }
        var map: [String: [ReclaimTarget]] = [:]
        for p in dropNested(hits.map { $0.path }) {
            let size = hits.first { $0.path == p }?.size ?? 0
            let key = reclaimBucket(of: p, in: rows) ?? Self.restBucketKey
            map[key, default: []].append(ReclaimTarget(path: p, size: size))
        }
        cacheTargets = map
    }

    // MARK: 两段式确认（第一下上膛，第二下才真搬）

    /// 上了膛的那条弧，nil = 没上膛。状态在模型而不在视图的 @State：
    /// 挂在视图上，人切走一趟再回来计时器就蒸发了，弧上却还亮着亮沿假装「等你确认」。
    @Published private(set) var armedPath: String?

    private var armTask: Task<Void, Never>?

    /// 第一下：给这条弧上膛，并起 3.2 秒倒计时。换弧上膛先解除旧的。
    func arm(_ path: String) {
        disarm()
        armedPath = path
        armTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.disarm()
        }
    }

    /// 解除上膛：第二下搬完、点了别处、3.2 秒到点、重扫、切页都走这里。
    func disarm() {
        armTask?.cancel()
        armTask = nil
        armedPath = nil
    }

    /// 只刷磁盘余量——可用空间随时在变，进页面就该是新的；
    /// 热点体积要遍历整棵家目录，不能跟着一起重跑。
    func refreshUsage() { readVolume() }

    /// 盘容量和卷账一起读：环形用的是容器数，明细用的是分卷数，
    /// 两者不同源就会对不上账（自检卡的正是「五块加起来等于已用」）。
    /// 卷账走 `usedPhysical`：diskutil 报的是每个卷此刻真占掉的格子，
    /// 而界面上的「已用」是系统口径（可清除算可用），拿后者去减卷账会凭空少 10 GB。
    private func readVolume() {
        let u = volumeUsage()
        usage = u
        split = u.flatMap { volumeSplit(diskUsed: $0.usedPhysical) }
    }

    func refresh(scope: ScanScope) {
        task?.cancel()
        dropChildren()
        disarm()
        readVolume()
        scanning = true
        started = true
        hasFDA = fullDiskAccessGranted()
        hotspots = []
        restHotspots = []
        // 水位线**不清零**：新一轮开跑那一刻，每条弧上最可信的尺寸仍然是上一次量到的那个，
        // 而它已经把旧账扣干净了。当场抹掉水位线等于让那些旧账复活，扫描途中那一截
        // 字节会被扣两遍（弧画小、废纸篓弧画大）。每条弧量完自己刷新自己的。
        cachedLedger = nil
        unlistedCount = 0
        unlistedBytes = 0
        covered = 0
        done = 0
        measuring = []
        needFDA = []
        needAdmin = []
        task = Task {
            let targets = hotspotTargets(scope)
            pending = targets.count
            targetPaths = targets.map { $0.path }
            var sized: [(name: String, path: String, size: Int64)] = []
            var total: Int64 = 0
            var blame = DirScan()
            await withTaskGroup(of: (Int, DirScan).self) { group in
                for (i, t) in targets.enumerated() {
                    group.addTask {
                        await self.enterMeasuring(t.name)
                        let r = await dirSizeReport(URL(fileURLWithPath: t.path))
                        await self.exitMeasuring(t.name)
                        return (i, r)
                    }
                }
                // 组按完成顺序回，不是提交顺序——所以子任务必须把下标带回来。
                for await (i, r) in group {
                    if Task.isCancelled { break }
                    let t = targets[i]
                    pending -= 1
                    done += 1
                    total += r.bytes
                    covered = total
                    // 这一处的账现在是新量的了：量之前就已经搬走的那些当场作废，否则同一截
                    // 字节要扣两遍；量完之后新搬走的仍然要扣（见 Core 的 `voidedUpTo`）。
                    voidedUpTo[t.path] = moved.count
                    cachedLedger = nil
                    blame.merge(r)
                    // 不设上限：这两串只被数个数拿去报「多少处读不动」。
                    // 掐到 60 条就等于对着 187 处说「有 60 处」，是个假数。
                    needFDA = blame.needFullDiskAccess
                    needAdmin = blame.needAdmin
                    if r.bytes > Self.sizeFloor {
                        sized.append((t.name, t.path, r.bytes))
                        sized.sort { $0.size > $1.size }
                        hotspots = Array(sized.prefix(Self.listCap))
                        restHotspots = Array(sized.dropFirst(Self.listCap))
                    }
                    // 截图模式：热缓存下一趟整扫描不到半秒，「量到一半」那一帧根本截不到。
                    // 这里只把**回填的节拍**拉开，数字一个都不改——弧该长多大还长多大，
                    // 光束该停在哪还停在哪，只是慢到快门跟得上。平时这个开关永远是关的。
                    if SnapshotMode.slowScanFill {
                        try? await Task.sleep(nanoseconds: 260_000_000)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            scanning = false
            measuring = []
            // 环形加起来等于整块盘，列表这一头也必须能对上：摊到几行、剩下多少，
            // 当场说清。不然「其他已统计」那块弧里就有一截是谁都没报过的数。
            unlistedBytes = max(0, total - sized.reduce(Int64(0)) { $0 + $1.size })
            unlistedCount = max(0, targets.count - sized.count)
            // 「还能腾出多少」这个数不能只靠整段可搬：一台真机上大头在缓存里。
            // 量体积走的是缓存页同一本知识库、同一趟统计（`load` 自带只跑一次的闸），
            // 一处一处量回来之后，环形那道金弧和主按钮的数才有凭据。
            rebuildCacheTargets()
            cachesModels.forEach { $0.load() }
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
        measuring = []
    }

    func enterMeasuring(_ name: String) {
        guard !measuring.contains(name) else { return }
        measuring.append(name)
    }

    func exitMeasuring(_ name: String) {
        measuring.removeAll { $0 == name }
    }

    // MARK: 量下一级

    /// 量某一行的下一级。量过就直接回缓存，反复点不会重走子树。
    func measureChildren(of path: String) {
        guard childRows[path] == nil, childBusy.insert(path).inserted else { return }
        childTasks[path] = Task { [weak self] in
            let rows = await childDirSizes(URL(fileURLWithPath: path),
                                           limit: OverviewModel.childCap)
            // 中途重扫过：这趟是被掐断的，只量到几格，不能当成完整答案挂上去。
            guard !Task.isCancelled, let self else { return }
            self.childRows[path] = rows
            self.childBusy.remove(path)
            self.childTasks[path] = nil
        }
    }

    /// 重扫把摊开的下级一起作废：盘的账会走样，隔着一轮扫描还挂着旧数字，
    /// 等于让人拿上一次的账做今天的决定。
    private func dropChildren() {
        childTasks.values.forEach { $0.cancel() }
        childTasks = [:]
        childRows = [:]
        childBusy = []
    }

    /// 整盘比用户区多扫的那几处，用显示名（演示树会剥掉假家目录前缀）。
    var extraScanRoots: [String] {
        systemScanRoots().filter { $0.lastPathComponent != "Applications" }
            .map { systemRootName($0) }
    }

    /// 扫描对象 = 家目录一级（点目录算在内）+ /Applications + 范围内的系统根。
    ///
    /// 点目录必须算：开发机上最能吃盘的往往就是 ~/.omlx、~/.ollama 这类模型仓库，
    /// 只扫可见目录等于把整机最大的一块藏起来——实测一台机器上因此少报了 42GB，
    /// 而当时列表第一名只有 39.7GB。
    ///
    /// 顺序是「便宜的排前面」，不是随手写的：并发跑的是系统自己那几条工作线程，
    /// 谁先提交谁先占住一条。/Library、/private 这种整棵系统目录一跑就是几分钟，
    /// 放在队首会把线程全占满，家目录里几百毫秒就完事的小目录反而排不上，
    /// 实测整盘档因此出现「已量完 0 / 163」卡两分钟、列表一片空白。
    ///
    /// 去重按 `seen` 走，先到先得：演示树把 /Applications 挂在假家目录底下，
    /// 同一个 path 进两遍不是重复一行那么简单——列表以 path 作 ForEach 的 id，
    /// 第二条会占住行高却什么都不画，环形还会把它算两遍。
    private func hotspotTargets(_ scope: ScanScope) -> [(name: String, path: String)] {
        var out: [(name: String, path: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ path: String) {
            guard seen.insert(URL(fileURLWithPath: path).standardizedFileURL.path).inserted
            else { return }
            out.append((name, path))
        }
        let home = homePath()
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for k in kids.sorted() {
                // 废纸篓不进热点列表，跟别的扫描任务同一套规矩（见 ScanJobs）：
                // 环形上它搬走的字节有自己那条弧，列表里再量它一次就是把同一块字节记两遍。
                if k == ".Trash" { continue }
                let p = (home as NSString).appendingPathComponent(k)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    add("~/\(k)", p)
                }
            }
        }
        add("/Applications", applicationsDir())
        if scope == .disk {
            for r in systemScanRoots() where r.lastPathComponent != "Applications" {
                add(systemRootName(r), r.path)
            }
        }
        return out
    }

    /// 系统根的显示名用真实路径。演示树里 `<假家目录>/Library` 要显示成 `/Library`，
    /// 截图里的名字才跟真机一致。
    private func systemRootName(_ url: URL) -> String {
        guard homeIsDemo else { return url.path }
        let home = homePath()
        guard url.path.hasPrefix(home + "/") else { return url.path }
        return String(url.path.dropFirst(home.count))
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: OverviewModel

    /// 此刻摊开在哪一段账上（值是 `GaugeSegment.armKey`）。nil = 没下钻，环画满幅。
    ///
    /// 这一页原本三段：环旁边这本账、下面「没量到的地方」、再下面「最占地方的文件夹」。
    /// 同一批目录在三个地方各说一遍，而下面那两段讲的其实就是这本账里两段的下一级——
    /// 于是把那两段搬进它们各自对应的那一行，整页只剩一段，下钻就地完成。
    /// 键取 `armKey` 不取路径：「其他已统计」「没量到」这两条弧没有路径。
    @State private var drillKey: String? = nil
    /// 鼠标停在面包屑那两个字上（决定那支 `←` 显不显形）。跟 `hovKey` 同一条纪律：
    /// 值真变了才写，AppKit 的 enter 不保证只来一次。
    @State private var crumbHover = false
    /// 点动不了的弧时当场说清为什么。静默吞掉一次点击是最坏的结局：
    /// 人会以为是画面坏了，而不是「这一段这个工具不碰」。
    @State private var arcNote: String?
    /// 鼠标此刻停在哪一段上（键是 `GaugeSegment.label`）。环和右边那列账目读同一个值，
    /// 所以样稿里 `link('.seg','.row')` 那套双向点亮在真机上是一起动的：
    /// 戳弧 → 那一行亮、其余退后；戳行 → 那条弧弹出来、其余压暗。
    @State private var hovKey: String?
    /// 悬停键唯一的写入口：**值真变了才写**。`@State` 写回同一个值也会把整页标脏，
    /// 而 AppKit 的 enter 事件不保证只来一次（重排、重挂都会再放一次）。
    /// 这一道守卫挡的是多余的那几次重画，挡不住自激环——那是身份问题，见 `GaugeSegment`。
    private func setHover(_ key: String?) {
        if hovKey != key { hovKey = key }
    }

    /// 「本次移入废纸篓」那条虚线弧。它不落在这屏里——那些字节已经在废纸篓，
    /// 要真让位得去废纸篓页交给访达，所以点它跳的是**另一页**。
    private static let trashAnchor = "overview.gotoTrash"
    /// 「其他已统计」那条弧名下、还在封顶列表里的那些行（第 4 到第 20 行）。
    private var restGroupRows: [(name: String, path: String, size: Int64)] {
        Array(model.hotspots.dropFirst(3))
    }

    /// 摊开/收起某一段的明细。**一次只摊一段**：两段同时摊着的话，这一列读不出
    /// 「现在看的是谁」，而这一屏刚撤掉下面那两段列表，靠的就是这一段一段地摊。
    private func setDrill(_ key: String?) {
        withAnimation(reduceMotion ? nil : theme.animation) {
            drillKey = (drillKey == key) ? nil : key
        }
    }

    /// 只摊开、不来回翻：截图钩子（`DISKWISE_DRILL` / `DISKWISE_JUMP`）要的是「这一处摊开的样子」，
    /// 拿 toggle 去点它会随上一次的落点翻成收起，拍出来就是一张没有明细的图。
    private func openDrill(_ key: String) {
        guard drillKey != key else { return }
        withAnimation(reduceMotion ? nil : theme.animation) { drillKey = key }
    }

    /// 一个具体目录该摊在哪一行上。前三名各自是一条弧，键就是路径；
    /// 第 4 名往后全住在「其他已统计」那一行名下，摊它们得先摊开那一行。
    private func openChildDrill(_ path: String) {
        guard model.hotspots.prefix(3).contains(where: { $0.path == path }) else {
            openDrill(SegmentDrill.restGroup.key)
            return
        }
        model.measureChildren(of: path)
        openDrill(path)
    }

    /// 行首那个 `▸`。摊开某一段的下一级时顺手把量这趟派出去——`measureChildren`
    /// 自己认缓存，反复点不会重走子树。
    private func toggleDrill(_ seg: GaugeSegment) {
        if case .children(let path)? = seg.drill, drillKey != seg.armKey {
            model.measureChildren(of: path)
        }
        setDrill(seg.armKey)
    }

    /// 环与账之间那道间距（样稿 `.hero` 的 gap）。
    static let heroGap: CGFloat = 24
    /// 右边这本账**想占**的那一档：条子按满幅 232 画、行首那三颗记号与行尾那簇数都在
    /// 原位。环按它给自己留地方——留够了环才拿得到满幅那一档 420。
    static let ledgerIdeal: CGFloat = 430
    /// 右边这本账**压不动**的那一档。上下两界都是 2026-09-28 在同一屏（900×700，窗口能拖
    /// 到的最窄）实拍出来的：
    /// - 侧栏拖到 280、这一列只剩 292 时，「各段之和 96.0 GB」那行灯色数被推到窗口边上，
    ///   主钮右沿离窗口只剩 1 pt（`planB-side280`，中英两张里只有中文这张越界）。
    /// - 默认侧栏（ideal 232）下这一列是 336，六行的数加底部分母全在窗内（右余 26 pt）。
    /// 取 312 ＝ 压不动那一档再加 20 pt 余量，而不是照抄「舒服」那一档 336：差的那 24 pt
    /// 是从窗口里买回来的余量。默认最小窗（内容宽 620）下 336 这一档会让环**正好**落在 260，
    /// 与弧上那六枚数的闸门齐平——侧栏往外拖 1 pt 就同时丢弧数和盘心那两行口径。
    /// 按 312 实测：侧栏 232→256 环仍是 260（`cliff312/side256-*`，弧上有数、盘心两行在），
    /// 拖满 280 才落到闸门外（环 236，读数整个交给右边那一列，账不越界）。
    static let ledgerFloor: CGFloat = 312
    /// 环这一档怎么算。**它不再是一个常量，而是「内容宽 − 间距 − 账要的那一档」**：
    /// 写死 420 的那一版，窗口一窄就是整列数被推出窗口边硬切
    /// （2026-09-28 实拍：`39.7 GB` 只剩 `39.7 G`、「停止」只剩「停」）。
    /// 缺的那一截先从环身上扣；扣到 260 之后**继续扣**，扣到账的压不动那一档为止——
    /// 260 当死线的那一版，侧栏一拖宽就是右边丢数（见 `ledgerFloor`）。
    /// 兜底 132：参照盘就是这一档，它是这条渲染链上验证过能画出来的最小盘。
    ///
    /// - 上限 420：量出来的，不是凑的。样稿 `A-sweep.html` 的环外沿 412 CSS px、窗口
    ///   1180 px，占比 0.349；本机窗口 1278 pt 折算过来是 446。取 420 是被窗口高度 707
    ///   卡住的——再大整块英雄卡就顶到页头。上一版写 340（占比 0.266），实拍下来环缩成
    ///   画面里的一个小圆、旁边一列字撑满，「这一圈 = 整块盘」这句招牌话当场不成立。
    /// - 260：`SweepRing` 里弧上那六枚数要求 `diameter >= 260`（`Components.swift` 的
    ///   `arcLabel` 闸门），收到它以下弧上就没数了——名字、数、占比全在右边那一列。
    /// - 参照盘 132：样稿 `r05-drill` 里 `.card.recede .ring` 就是 132 CSS px，
    ///   窗口 1278 pt 折算过来一比一。它还要留得住圆心那枚「可用」的数（0.21 倍直径
    ///   ＝27.7 pt，比旁边账目行的 17 pt 大），再小就退化成一个装饰饼图了。
    ///   下钻时这本账摊到了下一级，宽度全给它，环不参与分摊。
    private func ringDiameter(_ avail: CGFloat) -> CGFloat {
        if ringIsReference { return 132 }
        let keepLabelsAt = min(260, max(132, avail - Self.heroGap - Self.ledgerFloor))
        return min(420, max(keepLabelsAt, avail - Self.heroGap - Self.ledgerIdeal))
    }
    /// 环上只有一处按直径等比的东西撑不住小盘：弧上那六枚数。带厚 19 pt、那段弧的
    /// 弧长十几 px，11 pt 的数会叠成一片字。参照盘不承担读数，数全在右边那一列。
    private var ringIsReference: Bool { drillKey != nil }
    /// 环上「其他已统计」那块弧的数，用列表这一头的段复述时要用同一个数。
    /// nil = 还没量完或分段算术不成立，那时不画分界线也不写对账。
    /// 扣减必须跟 `ringAccount` 同源：两处各算一遍，分界线上那个数就跟弧对不上了。
    private var restArcValue: Int64? {
        guard let u = model.usage else { return nil }
        let topSum = model.hotspots.prefix(3).reduce(Int64(0)) { $0 + $1.size }
        let ded = model.ringDeduction
        guard let s = ringSplit(covered: model.covered, used: u.used, topSum: topSum,
                                movedOutTop: ded.top, movedOutRest: ded.rest),
              s.restMeasured > 0 else { return nil }
        return s.restMeasured
    }
    private var darkSkin: Bool { (theme.scheme ?? colorScheme) == .dark }

    // MARK: 弧上那一下点击（两段式确认的状态机入口）

    /// 点一条弧，或点环旁对应的那一行账目。规矩跟原型一致：
    /// 动得了的弧要**点两下**，中间那一下只是上膛；动不了的那一下就把话说清。
    private func tapArc(_ seg: GaugeSegment) {
        // 第二下：同一条弧还亮着，就真搬。认的是 `armKey` 不是 `path`——
        // 「其他已统计」那条弧没有路径，拿路径当键的话它永远上不了膛。
        if let armed = model.armedPath, armed == seg.armKey, seg.reclaim > 0 {
            model.disarm()
            take(seg)
            return
        }
        // 上膛期间点别的弧：先解除，再按那条弧自己的规矩办事。
        model.disarm()
        guard seg.reclaim > 0 else {
            arcNote = refuseNote(for: seg)
            // 指着某个具体目录的弧不就地摊：那句「为什么动不了」写在环形底下，
            // 摊开下级会把这句顶出视野。没有目录可摊的那几条弧（其他已统计 / 没量到）
            // 反过来——就地摊开就是答案，明细本来在这一本的哪一段名下已经说清了。
            if seg.path == nil {
                if seg.drill != nil { setDrill(seg.armKey) }
                else if seg.jumpTo == Self.trashAnchor { store.jumpTo = .trash }
            }
            return
        }
        arcNote = nil
        model.arm(seg.armKey)
    }

    /// 为什么这一段动不了。三种原因得用三句话说，揉成一句「动不了」等于没说。
    private func refuseNote(for seg: GaugeSegment) -> String {
        if let hint = seg.hint { return hint }
        guard let path = seg.path else {
            return LF("%@：这一圈里的账，不是一个能整个搬走的位置。", seg.label)
        }
        let url = URL(fileURLWithPath: path)
        if isProtected(url) {
            return LF("%@ 是受保护的位置，整个搬走会伤到系统或你自己的资料。里面的东西能清——去别的清理页挑。", seg.label)
        }
        return LF("%@ 不在本工具动手的范围内（家目录与应用程序之外）。", seg.label)
    }

    /// 圆心那行副读（样稿 `.mid .now`）：鼠标停在谁身上，就把「是谁 · 占多少 · 我收得走多少」
    /// 写在盘心。眼睛此刻在环上，让人扭头去右边那列字里找同名的那一行就是惩罚读图的人。
    ///
    /// 只有两行，而且第二行是固定长度的短句：**不拿 `sub` 当这句话**。`sub` 是给右边那列
    /// 宽行写的整句解释（「密封系统卷等，任何清理工具都动不了」），塞进内孔就折成三行、
    /// 末行压到环带上把弧上的数盖住。动不了的那一段为什么动不了，此刻就在它旁边被点亮的那一行里。
    ///
    /// 两处中文都写成裸字面量、不放进 `\(...)`：对账脚本扫不到插值里的词条，会把它判成死键。
    private func centerNowLine(_ seg: GaugeSegment) -> String {
        if seg.reclaim > 0 {
            let can = LF("%1$@ 可回收", seg.reclaimShown)
            // 整段都动得了就不把同一个数念两遍：屏幕上「6.3 GB · 6.3 GB 可回收」读起来像
            // 出了 bug，而它想说的只是「这一段 6.3 全收得走」。比的是**印出来的**那两个字符串，
            // 不是字节——差一个字节但都显示成 6.3 的话，人看见的还是重复。
            return seg.label + "\n"
                + (seg.sizeShown == seg.reclaimShown
                    ? can : seg.sizeShown + " · " + can)
        }
        return seg.label + "\n" + L("这一段没有可回收的东西")
    }

    /// 第二下：把这条弧上点名的那几处搬进废纸篓，一处一次 `trashItem`。
    ///
    /// 只搬 `targets` 里列出来的那些——它们每一处都过了知识库 `safe` + 还在原处两道筛。
    /// 以前这里还有一条「弧上没点名就整处搬走」的路，配上「没进保护名单就算能搬」的判定，
    /// 一键按钮于是会把用户的备份目录整段拖走，所以整条拿掉。
    /// 不一次性标记：任何一处失败都得当场看见是哪一处、为什么，
    /// 不然人就只剩「软件把我东西弄丢了」这一种解释。
    private func take(_ seg: GaugeSegment) {
        takeTargets(seg)
    }

    /// 一处一处搬，成功了几处、搬走多少字节、第一处失败为什么，三样都要留到最后那句话里。
    ///
    /// 「已移入废纸篓 12 处（8.4 GB），另有 3 处没搬动」这种句子必须是**真数**：
    /// 那句「还能腾出 22 GB」是按钮许的愿，搬完对不上而原因没说，这一屏就再没人信了。
    private func takeTargets(_ seg: GaugeSegment) {
        var ok = 0, bytes: Int64 = 0, failed = 0
        var why = ""
        for t in seg.targets {
            do {
                let moved = try trashItem(t.url)
                store.record(TrashRecord(original: t.url, inTrash: moved,
                                         size: t.size,
                                         displayName: t.url.lastPathComponent))
                ok += 1
                bytes += t.size
            } catch {
                failed += 1
                if why.isEmpty { why = failReason(error) }   // 只留第一处的原因，句子才不失控
            }
        }
        var line = LF("已把「%1$@」名下的 %2$@移入废纸篓（%3$@）。这些字节还占着盘，去废纸篓页交给访达清空才真让位。",
                      seg.label, cnt(ok, "处"), human(bytes))
        if failed > 0 {
            // 系统给的那句原因自带句号（「你没有许可。」），照搬进模板就是「许可。。」。
            let cause = why.hasSuffix("。") || why.hasSuffix(".") ? String(why.dropLast()) : why
            line += why.isEmpty ? LF("另有 %1$d 处没搬动。", failed)
                                : LF("另有 %1$d 处没搬动，第一处的原因是：%2$@。", failed, cause)
        }
        store.notice = line
    }

    /// 把 store 那本废纸篓账推给模型：环形每一帧都要读它，模型自己摸不到 store。
    ///
    /// 整串重推、不做增量：撤销链的形状就是「历史短了一截」，重新归一次位弧自己就回滚，
    /// 模型里不会留下第二本跟 store 对不上的账。
    private func syncMovedLedger() {
        model.setMoved(store.trashHistory.map { ($0.original.path, $0.size) })
    }

    /// 页面左右内边距。`pagePadding()` 里那个 20 在这里要参与算术（环按内容宽算），
    /// 所以这一屏不复用它：两处各写一个 20，改一处就会把账挤出窗口边。
    static let pagePad: CGFloat = 20

    private var scrollContent: some View {
        // ScrollView 在 macOS 13 会把**内容的理想宽**当成自己的宽报上去：900 pt 窗里
        // 内容列只有 664，它却按 ~716 排版，于是行尾那列数和页头那颗「重新扫描」
        // 一起被推出窗口边（2026-09-28 实拍）。所以先把它钉在外层给的那一档上——
        // 环的尺寸从这一档算，算完不会再回头改变这一档（上一版直接量 ScrollView，
        // 量到的就是它自己撑出来的宽，实测每轮 +3.5 pt 不收口）。
        GeometryReader { gate in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.metric.sectionGap) {
                    // 整页只剩这一段：环形旁边这本账，加上它自己摊开的下一级。
                    // 「没量到的地方」和「最占地方的文件夹」从前是它下面的另两段，
                    // 讲的却就是这本账里两段的明细——搬进它们各自那一行之后整段删掉。
                    if let u = model.usage {
                        heroCard(u, avail: gate.size.width - 2 * Self.pagePad)
                            .padding(.horizontal, Self.pagePad)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(width: gate.size.width, alignment: .leading)
            }
            .frame(width: gate.size.width, height: gate.size.height, alignment: .topLeading)
        }
    }

    var body: some View {
        // 页头钉在滚动区外面：它是这一屏的标题，滚走了就没人知道自己在哪页。
        // 下面仍然只有一个 ScrollView——macOS 13 的 ScrollView 会把内容的完整高度
        // 当成自己的理想尺寸报上去，套两层就会把 detail 列顶成一千六百多点。
        VStack(spacing: 0) {
            PageHeader(symbol: "internaldrive", title: L("空间总览"),
                       subtitle: L("先看清，再下手——每一行点开，就是它名下具体是哪几个目录"),
                       variant: .display) {
                ScanControl(scanning: model.scanning, kind: .primary,
                            rescan: { model.refresh(scope: store.scope) },
                            stop: { model.stop() })
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 2)

            // 演示树必须占满一条视线，不能只靠覆盖率那行末尾的小字：假家目录配真盘
            // 容量、或者配一块 96 GB 的假盘，缩略图里跟真机一模一样，挑图的人（包括
            // 我自己）就会拿一张假账去说「这才几十 G」。
            if demoDisclosed {
                HStack(spacing: 8) {
                    Image(systemName: "theatermask.and.paintbrush")
                        .font(.system(size: 12))
                    Text(L("演示数据：这一屏的目录、文件和整块盘的容量都是造的，不是你机器上的真实账。"))
                        .font(theme.bodyFont(.caption))
                    Spacer(minLength: 8)
                }
                .foregroundStyle(theme.palette.warnFG)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(theme.controlShape().fill(theme.palette.warnBG))
                .pagePadding()
            }

            scrollContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncMovedLedger()
            model.started ? model.refreshUsage() : model.refresh(scope: store.scope)
        }
        // 搬进废纸篓、撤销、清空之后环形要挪账。整条历史重新推一遍（见 `syncMovedLedger`）。
        .onChange(of: store.trashHistory) { _ in syncMovedLedger() }
        // 重扫一轮就把下钻收回：模型的 `dropChildren()` 同时作废了摊开出来的下级账，
        // 键还留着的话那一格会空摊着，看着像「扫到一半把东西弄丢了」。
        .onChange(of: model.scanning) { go in if go { setDrill(nil) } }
        // 切走这一页就解除上膛：弧都不在眼前了，还留着「等你确认」那道白边，
        // 回来时人会以为自己上一刀点到了一半。悬停指针与那句「为什么动不了」同理，
        // 都是当前这一屏的事，带不进下一页。
        .onDisappear {
            model.disarm()
            setHover(nil)
            arcNote = nil
        }
        .onChange(of: store.overviewDrill) { name in
            guard let name else { return }
            store.overviewDrill = nil
            guard let hit = (model.hotspots + model.restHotspots).first(where: { $0.name == name })
            else { return }
            openChildDrill(hit.path)
        }
        .onChange(of: store.overviewRing) { token in
            guard let token else { return }
            // 「扫描途中」那一帧：重跑一趟，让光束有东西可钉。
            if token == "rescan" {
                store.overviewRing = nil
                model.refresh(scope: store.scope)
                return
            }
            // 钩子动了哪一条弧、为什么没动，全部报到 stderr：拍出来一张和静图零差异的
            // 「拒绝解释」时，这一行是唯一能分清「界面没画」还是「画在了折出去的地方」的东西。
            @MainActor func say(_ what: String) {
                store.overviewRing = nil
                FileHandle.standardError.write("    · ring \(token): \(what)\n".data(using: .utf8)!)
            }
            guard let u = model.usage else { return say("还没有账，这一钩子跳过了") }  // l10n-scan: skip
            store.overviewRing = nil
            let segs = ringAccount(u).segs
            // 挑哪条弧不写死名字：演示树会改，而这一钩子要验的是「动得了的弧点两下」
            // 这件事本身，不是某一条弧。
            let hit = token == "refuse"
                ? segs.first { $0.path != nil && $0.reclaim == 0 } ?? segs.first { $0.path == nil }
                : segs.first { $0.reclaim > 0 }
            guard let hit else { return say("环上没有符合条件的弧") }   // l10n-scan: skip
            say("按的是「\(hit.label)」，reclaim \(hit.reclaim)")       // l10n-scan: skip
            tapArc(hit)
        }
        .onChange(of: store.overviewJump) { token in
            guard let token else { return }
            store.overviewJump = nil
            // 走的是账目行行首那颗 `▸` 完全相同的路径，截图验的就是这条真链路。
            switch token {
            // `restnote` 是旧名：那句对账不再躺在列表尾巴，它就在「其他已统计」摊开之后
            // 的最后一段上，两个口令现在指同一处。
            case "rest", "restnote": openDrill(SegmentDrill.restGroup.key)
            case "gap": openDrill(SegmentDrill.gapRows.key)
            default: openChildDrill(token)
            }
        }
        // 截图连拍要「摊开 → 再收回去」两拍都在一段里跑完，而收起在真机上是再点同一行，
        // 这一路没有键鼠点不到它。这里走的就是那颗行首 `▸` 的同一个 `setDrill`。
        .onChange(of: store.overviewCollapsePulse) { _ in setDrill(nil) }
    }

    /// `avail` = 这一屏给英雄卡的那一档宽度（已经扣掉页面左右内边距）。环的尺寸由它算，
    /// 见 `ringDiameter(_:)`。
    private func heroCard(_ u: VolumeUsage, avail: CGFloat) -> some View {
        let acct = ringAccount(u)
        // 截图旋钮 DISKWISE_HOVER=<第几段>：真机的悬停是鼠标进来的，静态图里没有鼠标，
        // 没有这个钩子这一条响应就只能靠嘴说它存在。
        let hovLabel = hovKey ?? SnapshotMode.ringHover.flatMap { i in
            acct.segs.indices.contains(i) ? acct.segs[i].label : nil
        }
        let hov = acct.segs.first { $0.label == hovLabel }
        let ring = ringDiameter(avail)
        // 卡片只装招牌那一屏（环 + 右侧这本账）。样稿里 `.acct` 那根账带子是主行的
        // **兄弟节点**，不在窗口卡里面：Ring 是「画面」，账带子是「画面下的图注」。
        // 上一版把四样东西全塞进同一张卡，于是卡的边界把招牌画面和它的说明切成了
        // 一个盒子，环再怎么放大都仍像表单里的一行——尊贵感首先来自「这块是单独一幅」。
        return VStack(alignment: .leading, spacing: 16) {
            ThemedCard(chromeless: true) {
                HStack(alignment: ringIsReference ? .top : .center,
                       spacing: ringIsReference ? 18 : Self.heroGap) {
                    VStack(alignment: .center, spacing: 10) {
                        // 环按 `ringDiameter(avail)` 画成一个**定宽**的方格，右边那一列
                        // 拿走剩下的。为什么不交给布局系统分摊：它分摊的时候不按两边的
                        // 下限收口——2026-09-28 给账目列写了 `minWidth: 350`，结果环反而
                        // 从 317 长到 342、账被挤到 300，那列数照样出界。
                        // `avail` 是 `scrollContent` 里钉住的那一档（ScrollView 自己会按
                        // 内容的理想宽长，量它等于量自己，实测每轮 +3.5 pt 不收口）。
                        Color.clear
                            .frame(width: ring, height: ring)
                            .overlay {
                                GeometryReader { g in
                                    SweepRing(segments: acct.segs,
                                              centerTop: centerTop(acct),
                                              centerValue: centerValue(acct),
                                              // 盘心躺不下那两行口径的两档，都撤掉它：
                                              // 参照盘内孔只有 93 pt；收到 260 以下那一档实测
                                              // 「整块盘 96.0 GB · 已用 80.0 GB」折成三行、孤字「GB」
                                              // 掉在中间（2026-09-28 实拍：最小窗 + 侧栏拖满，环 236，
                                              // `cliff312/side280-zh`；上一版按 336 压账时环 220 同形）。
                                              // 260 与弧上那六枚数走同一道闸：盘小到这个数，读数的活
                                              // 就整个交给右边那一列。这两个数不是被删了：卡片底下
                                              // `coverageLine` 那一行从头到尾都在写整块盘 / 可用 / 已用。
                                              centerCap: (ringIsReference || ring < 260) ? "" : centerCap(acct),
                                              diameter: g.size.width,
                                              select: { tapArc($0) },
                                              armed: model.armedPath,
                                              tapCenter: { model.disarm(); arcNote = nil },
                                              scanning: model.scanning,
                                              scanProgress: scanFraction(u),
                                              hovered: hovLabel,
                                              onHover: { v in setHover(v) },
                                              // 上了膛的那几秒这句要让位：圆心的 `cap` 那时写的正是
                                              // 「再点一次才移进废纸篓」，两句话叠着念就是四行字压到环带上。
                                              // 参照盘也让位——眼睛此刻在右边那列明细上，盘心那两行小字
                                              // 在 93 pt 的内孔里只会糊成一团，而它说的名字就在被点亮的行上。
                                              centerNow: ringIsReference || model.armedPath != nil
                                                  ? nil : hov.map(centerNowLine))
                                }
                            }
                        // 环上刚点出来的那句话，钉在环的正下方。上膛那一版跟着 `armedPath`
                        // 走而不是跟着 @State：3.2 秒到点自己解除，这句也得跟着消失，
                        // 不然弧都暗下去了话还挂着。
                        //
                        // 从前这句跟在整张卡片的下面：默认那扇 700 pt 高的窗里它落在
                        // 807 pt 处，而「点一条动不了的弧，当场把话说清」是这一屏唯一的
                        // 反馈——2026-09-28 实拍：1280x800 的 `-refused` 与静图零差异，
                        // 换成 1500 高才看见那句话。眼睛在环上，话就得落在环底下。
                        if let fb = arcFeedback(acct) {
                            Group {
                                if fb.urgent {
                                    callout(text: fb.text)
                                } else {
                                    Text(fb.text)
                                        .font(theme.bodyFont(.caption))
                                        .foregroundStyle(theme.palette.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: ring, alignment: .leading)
                        }
                    }
                    // 摊开之后明细会把这一列顶得很高，环跟着被拉到中间就成了
                    // 「一个悬在半空的小饼」。钉在顶上，它才读得出是自己下面这本账的缩略。
                    .frame(maxHeight: .infinity, alignment: ringIsReference ? .top : .center)

                    heroColumn(acct, hovLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            // 覆盖范围必须写在画面里：环形那块灰是「没量过」，不点明的话
            // 只会读成「我的盘没东西可清了」，而这是本页最容易误导人的一处。
            Text(scopeNote)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if model.started && model.done > 0 {
                coverageLine(u)
            }
        }
    }

    /// 此刻摊开着的那一段账（nil = 没摊开）。按 `armKey` 现查，不留下指针：
    /// 段每帧都是新构造的，攥着上一帧那份就是拿旧账做今天的决定。
    private func drilledSegment(_ acct: RingAccount) -> GaugeSegment? {
        guard let key = drillKey else { return nil }
        return acct.segs.first { $0.armKey == key }
    }

    /// 摊开之后「现在看的是谁」写在账目列顶端。**返回挂在上级名自己身上**：
    /// 上一级此刻就是「整圈」，所以点「空间总览」二字就收回去，鼠标进来才显出那支 `←`。
    /// 单独造一颗返回钮是糊弄——它不在任何人会去点的位置上。
    private func drillCrumb(_ seg: GaugeSegment) -> some View {
        HStack(spacing: 7) {
            Button { setDrill(seg.armKey) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(crumbHover ? 1 : 0)
                        .animation(theme.animation, value: crumbHover)
                        // 槽位常驻 12 pt：只切透明度的话那两个字会横移，看着像字在抖。
                        .frame(width: 12, alignment: .trailing)
                    Text(L("空间总览"))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(crumbHover ? theme.palette.ink : theme.palette.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { v in if crumbHover != v { crumbHover = v } }
            .accessibilityLabel(L("收起明细，回到整圈"))

            Text("›")
                .font(theme.numeric(size: 12))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(seg.label)
                // 段名是这一屏此刻的标题，但它不能抢导语那句「几处多少 GB 动得了」——
                // 导语才是被先读的那一句。所以给 13 pt 中等字重，不给 display 字号。
                .font(theme.prose(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
        }
    }

    /// 环右边那一列：面包屑（摊开时）、一句导语、这一圈的账、一个动作、一句防误删的话。
    /// 顺序就是读的顺序——先说能动多少，再说是谁，再给按钮。
    ///
    /// 这一列是整页**唯一**的清单：环形旁边这本账之外不再有第二段列表，
    /// 每一段的下一级都摊在自己那一行下面。
    private func heroColumn(_ acct: RingAccount, _ hovLabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let d = drilledSegment(acct) {
                drillCrumb(d)
            }

            lede(acct)

            VStack(alignment: .leading, spacing: 0) {
                // 逐行画分隔线（样稿 `.row+.row::before`），第一行不画。
                // 上一版靠 3pt 的行距把六行分开：没有线的时候那六行是六片浮着的字，
                // 有了线才读得出「这是一本账的六笔」。
                ForEach(Array(acct.segs.enumerated()), id: \.offset) { idx, seg in
                    let open = drillKey == seg.armKey
                    RingLedgerRow(seg: seg,
                                  fraction: Double(seg.value) / Double(max(1, acct.total)),
                                  armed: model.armedPath != nil
                                    && (model.armedPath == SweepRing.armAll || model.armedPath == seg.armKey),
                                  lit: hovLabel == seg.label,
                                  dim: hovLabel != nil && hovLabel != seg.label,
                                  showRule: idx > 0,
                                  onHover: { v in setHover(v ? seg.label : nil) },
                                  tap: { tapArc(seg) },
                                  expanded: open,
                                  onExpand: seg.drill == nil ? nil : { toggleDrill(seg) },
                                  onGrant: (seg.drill == .gapRows && canGrantFDA)
                                    ? { openFullDiskAccessPane() } : nil,
                                  onReveal: (open && seg.path != nil)
                                    ? { NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: seg.path!)]) } : nil,
                                  onDeepDive: (open && seg.path != nil)
                                    ? { store.bigScanDir = URL(fileURLWithPath: seg.path!)
                                        store.jumpTo = .big } : nil)
                    if open {
                        drillPanel(seg)
                            .padding(.top, 2)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                }
                // 一行都没量完时，把正在量的那几处摆出来。不然切完范围就是几分钟的
                // 空白清单，看着像点了没反应——路径要「陆续加载」，人才知道它在干活。
                // 这一屏只剩这一列，它就住这一列。
                ForEach(model.measuring.prefix(6), id: \.self) { name in
                    MeasuringRow(name: name, showRule: true)
                }
                // 那句「各段之和」是这一列的分母，坐在最后一行的数下面才对得上账。
                // 它以前躺在整张卡的最底下，跟右边那列数隔着主按钮和废纸篓两行——
                // 带子在的时候还能靠那条彩带把六行串起来看，带子撤了就只剩一句孤话。
                Text(lampRun(LF("各段之和 %1$@", human(acct.total)), human(acct.total),
                             SweepRing.lamp(theme.palette.tint),
                             base: theme.palette.inkTertiary))
                    .font(theme.bodyFont(.caption))
                    .monospacedDigit()
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 9)
            }

            VStack(alignment: .leading, spacing: 9) {
                takeAllButton(acct)
                trashTray(acct)
            }

            if model.armedPath == nil && acct.reclaimable > 0 {
                Text(L("点一段两次才收走那一段（防误删）；点动不了的段只会告诉你它为什么动不了。"))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 导语：这一圈被分成四笔账，一次说完。
    ///
    /// 「没量到的另算」这句不能省。以前把量到的和没量到的混在一句「共用了多少」里，
    /// 人就把那 16.4 当成「清不动的东西」，而它下一秒就会缩。
    private func lede(_ acct: RingAccount) -> some View {
        let n = acct.places
        let text: String
        // 样稿 `.lede b` 只染一个数：能动走的那几 G。其余三个读数保持原样，
        // 全句才有唯一一处重音——所以这里传的是 `human(reclaimable)`，不是「所有数字」。
        var run = ""
        if model.scanning {
            text = LF("正在量这一圈：已量完 %1$d/%2$d 处，量完才谈得上能动多少。",
                      model.done, model.done + model.pending)
        } else if n == 0 {
            text = L("这一圈里没有本工具动得了的地方——下面每一段都点名说了为什么动不了。")
        } else {
            run = human(acct.reclaimable)
            text = LF("%1$d 处 %2$@ 动得了；已量到的其余 %3$@ 先不动，没量到的 %4$@ 另算。",
                      n, run, acct.measuredIdleShown, acct.untouchedShown)
        }
        // 15 pt 是样稿 `.lede` 的字号。上一版走 `.callout`（macOS 上 11 pt），
        // 这句「整圈怎么分成四笔账」比它下面那列账的正文还小一档，层级是倒的。
        //
        // 被点的这个数样稿写的是 `--lamp-hot` 并加一档字重（不是行里那个 `--lamp`）：
        // 全页只有这一处用近白的暖金，它才是「这一屏第一句该被读到的东西」。
        return Text(lampRun(text, run, SweepRing.lampHot(theme.palette.tint),
                            base: theme.palette.inkSecondary,
                            font: theme.prose(size: 15, weight: .medium)))
            .font(theme.prose(size: 15))
            // 样稿 `.lede` 有 `max-width:46ch`：导语排两行，下面那列账排满一列宽。
            // 不限宽的话这一句会拉成一行 60 字，右边那列的宽度优势当场没了。
            // 46ch 在 15 px 的 SF 上是 382 px，取整到 400 pt。
            .frame(maxWidth: 400, alignment: .leading)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 主按钮：把这一圈里所有动得了的一次收走。仍是两下——第一下整圈上膛，
    /// 第二下才真搬；收完它自己变灰，不留一颗按了没反应的按钮在原地请人再按一次。
    private func takeAllButton(_ acct: RingAccount) -> some View {
        let armedAll = model.armedPath == SweepRing.armAll
        let can = acct.reclaimable
        return ThemeButton(
            kind: .lamp,
            title: can > 0
                ? (armedAll ? LF("再点一次，把 %1$@ 移进废纸篓", human(can))
                            : LF("把可回收的 %1$@ 移进废纸篓", human(can)))
                : L("这一圈里没有可回收的"),
            isDisabled: can <= 0
        ) {
            if armedAll {
                model.disarm()
                takeAll(acct)
            } else {
                arcNote = nil
                model.arm(SweepRing.armAll)
            }
        }
        .accessibilityHint(L("第一下只是选中，第二下才真的移进废纸篓"))
    }

    /// 废纸篓那一格：搬进来的已经占着盘，进度条说的是「这堆里已经收了多少」。
    /// 「清空」不在这页按——真要字节让位得去废纸篓页交给访达，所以这颗是指路牌。
    private func trashTray(_ acct: RingAccount) -> some View {
        let has = acct.inBin > 0
        let frac = fraction(acct.inBin, of: acct.reclaimable + acct.inBin)
        let lampColor = SweepRing.lamp(theme.palette.tint)
        return HStack(spacing: 9) {
            Text(L("废纸篓"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ringGrey.opacity(darkSkin ? 0.13 : 0.18))
                    // 斜纹填充，不是实心条：样稿写的是 `repeating-linear-gradient(115deg, …)`。
                    // 实心进度条在说「已经完成」，而这 4 px 说的是「收进来的还占着盘、
                    // 只是换了个格子住」——纹就是这两态的区别，抹平了就只剩颜色在说。
                    Canvas { ctx, size in
                        let w = size.width * frac
                        var x: CGFloat = -size.height
                        while x < w {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height * 0.6, y: 0))
                            ctx.stroke(p, with: .color(lampColor.opacity(0.8)), lineWidth: 2)
                            x += 6
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 4)
            Text(LF("%1$@ / %2$@", human(acct.inBin),
                    human(acct.reclaimable + acct.inBin)))
                .font(theme.numeric(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(has ? SweepRing.lampHot(theme.palette.tint)
                                     : theme.palette.inkTertiary)
                .fixedSize()
            Button { store.jumpTo = .trash } label: {
                Text(L("去清空"))
                    .font(theme.prose(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.inkSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .overlay(Capsule().stroke(theme.palette.separator, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!has)
            .opacity(has ? 1 : 0.32)
        }
    }

    private func fraction(_ v: Int64, of total: Int64) -> CGFloat {
        total <= 0 ? 0 : CGFloat(max(0, v)) / CGFloat(total)
    }

    /// 第二下：把这一圈里动得了的挨个搬进废纸篓。
    ///
    /// 一条一条走 `trashItem`，不是「一次性标记」：任何一处失败都得当场看见是
    /// 哪一处、为什么，不然人就只剩「软件把我东西弄丢了」这一种解释。
    private func takeAll(_ acct: RingAccount) {
        for seg in acct.hot { take(seg) }
    }

    // MARK: 就地摊开的明细：这一页唯一的下一级

    /// 摊开某一行之后，那一行名下画什么。三种载荷的数都已经在页面上算好了，
    /// 这里只说「点开是哪一种」——所以下钻既不跳页，也不需要第二段列表。
    @ViewBuilder
    private func drillPanel(_ seg: GaugeSegment) -> some View {
        switch seg.drill {
        case .children(let path)?: childrenPanel(seg.label, path: path)
        case .restGroup?:         restGroupPanel()
        case .gapRows?:           gapPanel()
        case nil:                 EmptyView()
        }
    }

    /// 第一种载荷：某个目录的下一级。量这一趟是点开时才派出去的（`toggleDrill`），
    /// 量过走缓存；正在量时先给一行话——那几秒空着，看着就像「点开啥也没有」。
    private func childrenPanel(_ title: String, path: String) -> some View {
        let rows = model.childRows[path] ?? []
        let busy = model.childBusy.contains(path)
        let whole = model.arcSize(of: path)
        let rest = max(0, whole - rows.reduce(Int64(0)) { $0 + $1.size })
        // 整列连尾巴那句一起过一次统一分档，钉在父行那个数上：这一列 ＋ 那句 = 上面
        // 那一行。逐行 `human()` 会各飘 0.1，那句对账就永远加不回来。
        let texts = addableHumanColumn(rows.map { $0.size } + [rest], total: whole)
        return VStack(alignment: .leading, spacing: 5) {
            if busy && rows.isEmpty {
                busyLine(LF("正在量「%@」的下一级", title))
            }
            ForEach(Array(rows.enumerated()), id: \.element.path) { i, c in
                DrillRow(icon: .path(URL(fileURLWithPath: c.path)),
                         name: c.name, path: c.path, sizeText: texts[i],
                         reclaim: min(c.size, model.reclaimableUnder(c.path)),
                         ruler: whole,
                         fraction: Double(c.size) / Double(max(1, rows.first?.size ?? 1)))
            }
            if !busy {
                if rows.isEmpty {
                    tailLine(rest > MB
                        ? L("这一层的空间全在它自己的文件里，没有读得出的子目录。用行尾那颗「访达显示」去盘上看。")
                        : L("这一层没有读得出的子目录。"))
                } else if rest > MB {
                    tailLine(LF("这一层自己的文件、加上排在 %1$d 名之后的子目录，合计 %2$@，没逐行列出。",
                                OverviewModel.childCap, texts[rows.count]))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 第二种载荷：「其他已统计」那条弧名下的位置。弧上画的是第 4 名往后的**合计**，
    /// 这一头逐行点名，最后那句把没点到的补齐——几段相加就是弧上那个数。
    ///
    /// 这一堆从前摊在页面底下另一张列表里，隔着一次滚动，于是「大头你一直找不到」：
    /// 弧上有 221.9 GB，屏幕上只看得见 21.2 GB，剩下 200 GB 停在上方没人框它。
    /// 现在它就在自己那条弧对应的那一行底下，对账就地完成。
    private func restGroupPanel() -> some View {
        // 第 4 名到列表封顶，再接封顶之外那些（两处各自按大小排，拼起来仍是降序）。
        let rows = restGroupRows + model.restHotspots
        let nets = rows.map { model.arcSize(of: $0.path) }
        let listed = nets.reduce(Int64(0), +)
        let small = model.unlistedNet
        let total = restArcValue ?? listed + small
        // 尾巴那句里「这几处」那个数取**印出来的这几行**之和（`sumShown`），不拿字节加：
        // 人核对的是屏幕上这一列，差的那 0.1 要记在「每行都各自四舍五入过」上。
        let texts = addableHumanColumn(nets + [small], total: total)
        let listedText = sumShown(Array(texts.prefix(rows.count))) ?? human(listed)
        var parts: [String] = []
        if !rows.isEmpty {
            parts.append(LF("这里这 %1$d 处 %2$@", rows.count, listedText))
        }
        if rows.isEmpty || small > 0 {
            parts.append(LF("%1$d 处不到 %2$@ 的小目录 %3$@", model.unlistedCount,
                            human(OverviewModel.sizeFloor), texts[rows.count]))
        }
        let note = parts.isEmpty ? nil
            : LF("环形上「其他已统计」那条弧 %1$@，就是这几段相加：%2$@。",
                 human(total), parts.joined(separator: " ＋ "))
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.element.path) { i, r in
                DrillRow(icon: .path(URL(fileURLWithPath: r.path)),
                         name: r.name, path: r.path, sizeText: texts[i],
                         reclaim: model.reclaimable(of: r.path),
                         ruler: total,
                         fraction: Double(nets[i]) / Double(max(1, nets.first ?? 1)))
            }
            if !model.scanning, let note {
                tailLine(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 第三种载荷：「没量到」那块灰弧的卷账。整块盘的账拆到能命名的每一卷，
    /// 各写一句为什么在这块弧上、动不动得了。只报一个总数等于没回答。
    @ViewBuilder
    private func gapPanel() -> some View {
        if let u = model.usage {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(gapRows(u).enumerated()), id: \.offset) { _, row in
                    // 图形跟另外两种载荷同一格：这一屏摊出来的每一行都有那一格，
                    // 只有「没量到」那几行没有，读起来就像那几行不属于这张表。
                    HStack(alignment: .top, spacing: 10) {
                        RowIconView(icon: .symbol(row.symbol))
                            .frame(width: rowIconSide, height: rowIconSide)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.title)
                                    .font(theme.bodyFont(.caption))
                                    .foregroundStyle(theme.palette.ink)
                                Text(row.tag)
                                    .font(theme.bodyFont(.caption2))
                                    .foregroundStyle(row.actionable
                                                     ? theme.palette.tint : theme.palette.inkTertiary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(row.actionable
                                                                ? theme.palette.tintSoft
                                                                : theme.palette.surfaceAlt))
                                Spacer(minLength: 8)
                                Text(human(row.bytes))
                                    .font(theme.numeric(size: 13))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.palette.inkSecondary)
                                    .fixedSize()
                            }
                            Text(row.reason)
                                .font(theme.bodyFont(.caption2))
                                .foregroundStyle(theme.palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.leading, drillIndent - rowIconSide - 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(text)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
        .padding(.leading, drillIndent)
    }

    /// 明细尾巴那句对账。它必须和上面那几行**同缩进**：差一截的话这句就悬在
    /// 列表外面，读不出它说的是哪一组。
    private func tailLine(_ text: String) -> some View {
        Text(text)
            .font(theme.bodyFont(.caption2))
            .foregroundStyle(theme.palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
            .padding(.leading, drillIndent)
    }

    // MARK: 圆心那三行

    /// 圆心那句问话。第一眼要回答的是「这块盘现在什么情况」，不是「本工具能清多少」：
    /// 后者是导语和按钮的话。把它顶在圆心，快满的机器只留下一个比已用小三十倍的数，
    /// 人一眼读成「我这盘挺空」——正好读反。
    /// 扫描和上膛那两态仍然抢圆心，因为它们说的是此刻这件事，不是盘的常态。
    private func centerTop(_ acct: RingAccount) -> String {
        if model.scanning { return L("正在量") }
        if model.armedPath != nil { return L("确认移入废纸篓") }
        return L("可用")
    }

    private func centerValue(_ acct: RingAccount) -> String {
        if model.scanning { return human(model.covered) }
        if let armed = model.armedPath {
            // 上膛那一刻圆心写的是**这一按真会搬走的量**，不是那条弧的体积：
            // 「确认移入废纸篓 23.2 GB」而它名下只有 13 GB 收得走，那一按下去数对不上。
            if armed == SweepRing.armAll { return human(acct.reclaimable) }
            return acct.segs.first { $0.armKey == armed }?.reclaimShown ?? human(0)
        }
        return acct.availableShown
    }

    /// 那个数的口径。圆心只放一个数，就必须当场说清它是**从哪儿到哪儿**：
    /// 「可用 14.9」不配「整块盘 494.4 · 已用 479.5」这半句，就只是一个让人安心的数。
    /// 第二行留给出完力之后的样子——「还能腾出」没消失，只是从招牌降成承诺。
    private func centerCap(_ acct: RingAccount) -> String {
        if model.scanning {
            return LF("已量 %1$d/%2$d 处 · 这一圈还没量完",
                      model.done, model.done + model.pending)
        }
        if model.armedPath != nil {
            return L("再点一次才移进废纸篓 · 3 秒不点自动取消")
        }
        let head = LF("整块盘 %1$@ · 已用 %2$@", acct.totalShown, acct.usedShown)
        // 还能搬走的 + 已经在废纸篓还没让位的，加回可用才是「走完这一步之后」。
        // 一笔都没有时不写这句空话，只把这一圈的结论留下。
        return head + "\n" + (acct.reclaimable + acct.inBin > 0
            ? LF("全部清空后可用 %1$@", acct.afterClearShown)
            : L("这一圈里没有本工具动得了的东西"))
    }

    /// 扫描期间那道光停在哪儿：按**量到的字节**走，不是按时间编一段动画。
    /// 环是按字节长的，所以光束永远钉在「量到的边界」上——它慢下来就是真慢下来。
    private func scanFraction(_ u: VolumeUsage) -> Double {
        min(1, max(0, Double(model.covered) / Double(max(1, u.used))))
    }

    /// 环上刚点出来的那句话。上膛那一版跟着 `armedPath` 走而不是跟着 @State：
    /// 3.2 秒到点自己解除，这句也得跟着消失，不然弧都暗下去了话还挂着。
    ///
    /// 数与名字都从 `acct` 上按 `armKey` 查，不再拿 `armedPath` 当路径去 `arcSize`：
    /// 「其他已统计」那条弧的键不是路径，且它真能搬走的只是名下点名的几处。
    private func arcFeedback(_ acct: RingAccount) -> (text: String, urgent: Bool)? {
        if let armed = model.armedPath {
            if armed == SweepRing.armAll {
                return (LF("已选中这一圈里动得了的全部 %1$d 处、共 %2$@。再点一次按钮才移进废纸篓；3 秒不点自动取消，移进去之后还能在废纸篓页找回。",
                           acct.places, human(acct.reclaimable)), true)
            }
            guard let seg = acct.segs.first(where: { $0.armKey == armed }) else { return nil }
            let what = LF("把它名下点名的 %1$@、共 %2$@ 移进废纸篓",
                          cnt(seg.targets.count, "处"), seg.reclaimShown)
            return (LF("已选中「%1$@」：%2$@。再点一次那一段确认；3 秒不点自动取消，移进去之后还能在废纸篓页找回。",
                       seg.label, what), true)
        }
        if let note = arcNote { return (note, false) }
        return nil
    }

    /// 这一行要把整块盘的账一路减到底：494 = 可用 128 + 已用 366，已用 = 量到 320 + 量不到 46。
    /// 只报「已量到 320.6，占已用 85%」不够——人手里记的是「我这盘 500 G」，
    /// 看到 320 就以为我们说整块盘只有 320，那一瞬间工具就变成在骗人。
    /// 可用必须写成「空闲 + 可清除」两段：只报那个跟系统对齐的大数，等于把
    /// 10 GB 还占着盘的东西说成空的。差额去哪了不在这里逐块说，点开「没量到」那一格点名。
    /// 可清除是 0 时不再写这一项：环形上本来就不画 0 字节的弧（见 `ringAccount`），
    /// 句子却照抄模板就会拍出一张「系统可清除 0 B」的图——那是在演示一个不存在的东西。
    private func coverageLine(_ u: VolumeUsage) -> some View {
        let pct = Int((Double(model.covered) / Double(max(1, u.used)) * 100).rounded())
        // 「已用 = 量到 + 量不到」是这一句自己许的账，所以三个数由**印出来的字**互相加减，
        // 不各拿字节四舍五入（那样三项能差出 0.1）。已用那格还跟圆心共用同一条算法。
        let availT = human(u.available), usedT = diffShown(human(u.total), availT) ?? human(u.used)
        let gapT = human(max(0, u.used - model.covered))
        let tail = LF("已用 %1$@。已用里这一轮量到 %2$@（%3$d%%），剩下的 %4$@ 点开「没量到」那一行逐块点名。",
                      usedT, diffShown(usedT, gapT) ?? human(model.covered), pct, gapT)
        let text: String
        if u.purgeable > 0 {
            text = LF("整块盘 %1$@：可用 %2$@（空闲 %3$@ ＋ 系统可清除 %4$@），",
                      human(u.total), availT, human(u.free), human(u.purgeable)) + tail
        } else {
            text = LF("整块盘 %1$@：可用 %2$@（全是空闲），",
                      human(u.total), availT) + tail
        }
        return Text(text)
            .font(theme.bodyFont(.caption))
            .foregroundStyle(theme.palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 「没量到」那一格的卷账

    /// 一行差额：名字、多大、为什么是这么个去向、这个工具动得了动不了。
    private struct GapRow {
        let title: String
        let tag: String
        var reason: String
        let bytes: Int64
        /// 这一块有没有能要回来的部分——决定画不画那颗「去授权」。
        let actionable: Bool
        /// 行首那一格。这几块都没有路径可查（不是盘上的某个文件夹），走类别符号那一档。
        let symbol: String
    }

    /// 这一格能不能靠「去授权」要回来——决定画不画那颗按钮。
    ///
    /// 判据是实测探针（`model.hasFDA`），不是扫描里报了几处 EPERM：系统设置里勾完，
    /// macOS 要 App 退出重开才把授权落到进程上，而这趟扫描往往正是重开之前跑的。
    /// 只数 EPERM 就会对着已经勾过的人说「再点那颗去授权」，那是把人往回踢。
    private var canGrantFDA: Bool {
        !HomeAccess.runsSandboxed && !model.hasFDA && !model.needFDA.isEmpty
    }

    /// 环形上那块「没量到的地方」灰的去向。
    ///
    /// 不能只报一个总数：470 GB 已用里没量到的三百多 G，绝大部分既不是「扫不动」也不是
    /// 「没东西可清」，而是这台盘的账本来就不在用户区——只读系统卷、VM 卷、引导分区，
    /// 加上真正能追回来的那部分（打不开的目录、没扫到的位置）。揉成一块灰，
    /// 用户只会读成「我的盘白清了」，那是这一屏最容易误导人的一处。
    private func gapRows(_ u: VolumeUsage) -> [GapRow] {
        let dataVolume = model.split?.dataVolume ?? u.used
        // 「系统可清除」此刻在环形上单列成一条弧、在数字上归进了「可用」，
        // 但它物理上就躺在数据卷的 CapacityInUse 里。不减掉的话，同一块 10 GB
        // 会在「没量到的地方」和「可清除」各报一次。拆不出卷账时不知道它落在哪一
        // 卷，那就宁可不减，也不凭猜想挪账。
        let purgeableInData: Int64 = model.split == nil ? 0 : u.purgeable
        let first = GapRow(title: model.split == nil ? L("没量到的部分") : L("数据卷里没量到的部分"),
                           tag: gapFirstRowTag,
                           reason: gapFirstRowReason,
                           bytes: max(0, dataVolume - min(model.covered, dataVolume) - purgeableInData),
                           actionable: canGrantFDA || HomeAccess.runsSandboxed,
                           symbol: "questionmark.folder")
        var rows = [first]
        if let s = model.split {
            rows.append(GapRow(
                title: L("macOS 系统卷"), tag: L("删不动"),
                reason: L("只读、签名封存，由 SIP 看着。任何清理工具都动不了它，真要瘦只能等系统更新自己整理。"),
                bytes: s.sealedSystem, actionable: false, symbol: "lock.rectangle.on.rectangle"))
            rows.append(GapRow(
                title: L("虚拟内存与休眠镜像"), tag: L("系统自己收回"),
                reason: L("内存吃紧时 macOS 借硬盘喘息，深度休眠前还会把整份内存写下来。关掉占内存的应用就会缩，不该由工具去删。"),
                bytes: s.virtualMemory, actionable: false, symbol: "memorychip"))
            rows.append(GapRow(
                title: L("启动与恢复分区"), tag: L("删不动"),
                reason: L("开不了机时才用得上，属于固件的地盘。恢复卷平时不挂载，也一起算在这一行。"),
                bytes: s.bootAndRecovery, actionable: false, symbol: "arrow.counterclockwise.circle"))
            rows.append(GapRow(
                title: L("卷之间的未归属占用"), tag: L("对不到目录"),
                reason: L("APFS 容器自己的元数据，加上各卷共享的那点取整差。这一坨对不到具体文件夹，只能整体看着。"),
                bytes: s.unattributed, actionable: false, symbol: "circle.dashed"))
        }
        return rows.filter { $0.bytes > 0 }
    }

    /// 第一行那颗标签：三种真实状态各有各的说法，不能一律写「授权能补一部分」。
    private var gapFirstRowTag: String {
        if HomeAccess.runsSandboxed { return L("授权能补一部分") }
        if model.needFDA.isEmpty { return L("对不到目录") }
        return canGrantFDA ? L("授权能补一部分") : L("已授权仍读不到")
    }

    /// 第一行怎么说：能拆卷账时这一格确定是「你的文件」，拆不出时不能这么断言，
    /// 里面还混着系统自己的分区。沙盒版不提「切整盘」——那颗开关在沙盒里根本不存在。
    private var gapFirstRowReason: String {
        var text: String
        if HomeAccess.runsSandboxed {
            text = L("沙盒只放行了你授权过的目录，其余位置量不到。这不是盘上的死账：授权范围里的东西量到之后都能进废纸篓。")
        } else if model.split == nil {
            text = demoDisclosed
                ? L("演示树只画得出这一块。真机上这里会按卷点名：系统卷、虚拟内存、引导分区各占多少，一眼分清哪些能追回来。")
                : L("这一轮没扫到、或目录打不开的都归在这里。这台机器的分卷账拆不出来，所以没法替你把系统分区单独挑出去。")
        } else {
            // 剩余里混着两种东西：补授权就能量到、量到之后能删的；以及只有 root 读得动、
            // 任何清理工具都删不动的。混成一句「都能进废纸篓」是吹牛。
            text = L("这一轮量不到的都归在这里：要么是读不动的目录，要么是盘上对不到具体文件夹的账。")
        }
        // 读不动的那几处按探针分开说。已经勾过的人还让他去勾，比不提示更糟——
        // 他会认定这个工具量不动自己的盘。
        if !model.needFDA.isEmpty {
            text += " " + (HomeAccess.runsSandboxed
                ? LF("沙盒读不到的目录 %1$d 处。", model.needFDA.count)
                : canGrantFDA
                    ? LF("其中 %1$d 处缺「完全磁盘访问权限」：点「没量到」那一行行尾的「去授权」，勾完要退出这个 App 再打开才生效，然后重扫一轮。",
                         model.needFDA.count)
                    : LF("完全磁盘访问权限已经开着，其中 %1$d 处仍然读不到——那是系统自己看着的位置，重启或提权都换不回来。",
                         model.needFDA.count))
        }
        if !model.needAdmin.isEmpty {
            text += " " + LF("另有 %1$d 处只有管理员能读，工具不提权，也就量不出它们多大。",
                             model.needAdmin.count)
        }
        return text
    }

    private func openFullDiskAccessPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private var scopeNote: String {
        if HomeAccess.runsSandboxed {
            return L("覆盖范围：你授权过的目录。系统区在沙盒里读不到，所以单列为「没量到的地方」。")
        }
        // 把扫了哪几处点名念出来：只说「整块盘上普通用户可读的位置」，
        // 用户就不知道这一趟到底走过了哪些地方、剩下的差额是谁的。
        return LF("覆盖范围：家目录（含隐藏项）与 /Applications，另外 %1$d 处盘上普通用户读得动的位置（%2$@）。剩下的「没量到」是密封系统卷、引导与恢复分区，和只有 root 读得动的系统数据——那几块任何清理工具都动不了。",
                  model.extraScanRoots.count, model.extraScanRoots.joined(separator: "、"))
    }

    private func callout(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.warnFG)
            Text(text)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.warnFG)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.controlShape().fill(theme.palette.warnBG))
    }

    /// 环形这一屏的账本：弧、以及从同一批数派生出的四句话。
    ///
    /// 只算一次。导语、圆心、主按钮、废纸篓那条进度共用「还能腾出多少」——各算各的
    /// 话收走一处就会有一处停在旧数上，而这一屏最容易塌的就是同屏两个数打架。
    /// 恒等式：reclaimable + measuredIdle + untouched + inBin + free + purgeable == total。
    private struct RingAccount {
        var segs: [GaugeSegment] = []
        /// 弧上还搬得走的总和
        var reclaimable: Int64 = 0
        /// 量到了、但这一屏动不了的（前三名剩下的 + 其他已统计剩下的）
        var measuredIdle: Int64 = 0
        /// 这一轮压根没量到的
        var untouched: Int64 = 0
        /// 已经搬进废纸篓、还没让位的
        var inBin: Int64 = 0
        var free: Int64 = 0
        var purgeable: Int64 = 0
        var total: Int64 = 0
        /// 圆心那个「可用」：跟下面那行对账、跟系统设置 ▸ 储存空间同一个口径。
        var available: Int64 { free + purgeable }
        /// 「已用」= 整块盘 − 上面那个可用。两处必须共用一次减法，否则同一屏两本账。
        var used: Int64 { total - available }
        /// 走完这一步之后系统会写多少可用：还能搬走的 + 已经在废纸篓还没让位的。
        var afterClear: Int64 { available + reclaimable + inBin }

        // ── 屏幕上那几串字：格内加减法一律拿**印出来的字**算，不拿字节 ──────────
        // 实拍那一屏印的是「可用 14.2」「可回收 18.6」「全部清空后可用 32.7」：
        // 真值各自偏低（14.1x ＋ 18.5x = 32.7x），字节加法一步没错，错在屏幕上
        // 那三串字加不起来。差 0.1 要记在「每项都各自四舍五入过」上，不能记成两个口径。
        var totalShown: String { human(total) }
        var availableShown: String { human(available) }
        var usedShown: String { diffShown(totalShown, availableShown) ?? human(used) }
        /// 导语里「没量到的另算」那个数：拿**那一行印出来的字**，不拿字节现算。
        /// 这一列是按最大余数分到「各行相加 = 整块盘」上的，哪一行都可能比裸 `human()`
        /// 多或少 0.1；导语自己 `human()` 一次，同一屏就会长出两个数。
        /// 2026-09-28 实拍命中：搬走一项后「本次移入废纸篓」进了列、拿走那份余数，
        /// 导语印 32.6 而「没量到」那行印 32.7。
        var untouchedShown: String {
            segs.first { $0.drill == .gapRows }?.sizeShown ?? human(untouched)
        }
        /// 导语里「已量到的其余先不动」那个数：从**印出来的**整盘往下减，减到只剩这一笔。
        /// 导语那三个数自己就得加得起来（动得了 + 其余 + 没量到 + 已在废纸篓 + 可用 = 整盘），
        /// 各拿字节 `human()` 一次就会差 0.1 —— 2026-09-28 实拍：右边那列印的是
        /// 13.4 + 6.3 + 5.1 + 24.3 − 10.4 = 38.7，而导语印 38.6。
        var measuredIdleShown: String {
            var left: String? = usedShown
            for p in [untouchedShown, human(inBin), human(reclaimable)] {
                left = left.flatMap { diffShown($0, p) }
            }
            return left ?? human(measuredIdle)
        }
        var afterClearShown: String {
            sumShown([availableShown, human(reclaimable), human(inBin)]) ?? human(afterClear)
        }
        /// 动得了的那几段
        var hot: [GaugeSegment] { segs.filter { $0.reclaim > 0 } }
        /// 导语里那个「几处」：按**点名下过单的位置**数，不按弧数。
        /// `~/Library` 名下十几处缓存算十几处——一句「3 处 22 GB 动得了」配一张要点
        /// 十几下的清单，那个 3 就是假数。动得了的弧必然带着点名的处（数就是从它们来的），
        /// 所以这里只数 `targets`，不再给「整段算一处」留口子。
        var places: Int {
            hot.reduce(0) { $0 + $1.targets.count }
        }
    }

    /// 环上灰弧的底色。样稿的灰从来不是中性灰：`.seg.dust` 写的是
    /// `rgba(150,164,182,.30)`——一条**蓝灰**。深皮这一圈底下垫着金色余晖，
    /// 正文 ink 透上去读出来是芥末（实拍量到蓝道比红道低 47，样稿只低 19）。
    /// 把蓝道抬回去，灰才读成灰；透明度按 247/164 补回亮度，灰阶三档的落差原样不动。
    private var ringGrey: Color {
        darkSkin ? Color(red: 150 / 255, green: 164 / 255, blue: 182 / 255) : theme.palette.ink
    }

    /// 环形分段 = 前 3 大热点 + 其余量到的 + 这一轮没量到的 + 可清除 + 空闲，加起来正好等于整块盘。
    ///
    /// 上色只有一条规矩：**彩色只给动得了的弧**。前三名一人一色的六色数据系列铺满一圈，
    /// 读出来是「这盘被六样东西吃掉了」，而这一屏要回答的只有一件事——哪儿能腾出手来。
    /// 所以动得了的那几段共用主色（灯芯渐变），量到动不了的、没量到的都是灰两档（深皮是蓝灰），
    /// 系统可清除用洗淡的主色（有色、但按不动），废纸篓是主色加虚线。
    ///
    /// 「没量到的」必须单列。以前把「排在列表 5-20 名」和「压根没扫」揉成一块灰色
    /// 「其他已用」，实测一台机器上那块占 70%，于是用户自然要问「怎么才列出这么点」——
    /// 因为图上根本分不清是没扫到，还是扫了觉得不值一提。
    ///
    /// 「其他已统计」这块弧要能在下面的列表里逐段对上：它 = 第 4 名到列表封顶 + 展开的
    /// 其余若干处 + 没到下限的那些小目录，列表尾巴当场把这三段报出来。以前这块弧按
    /// 「用户区」的账画、列表按「整盘」的账列，两个口径同屏，谁也对不上谁——那是这一屏
    /// 最快塌掉的地方，所以范围开关整个撤掉了。
    ///
    /// 除了「空闲」和「系统可清除」，每一块弧都带着自己那一段的明细：点下去就地摊开，
    /// 要么是这个目录的下一级，要么是「其他已统计」名下的那些位置，要么是「没量到」的卷账。
    /// 环形上凭空出现一块说不清是谁的弧，就是这一屏最不该留下的缺口。
    private func ringAccount(_ u: VolumeUsage) -> RingAccount {
        let dark = darkSkin
        let top = Array(model.hotspots.prefix(3))
        // 交给 Core 的 topSum 必须是**这一轮量到的原始数**：`ringSplit` 用
        // 「covered − topSum」算出其余量到的，这里换成净数就等于把搬走的那几 G
        // 又还给「其他已统计」，同一截字节被算两遍，整圈当场对不上已用。
        let topSum = top.reduce(Int64(0)) { $0 + $1.size }
        let netTopSum = top.reduce(Int64(0)) { $0 + model.arcSize(of: $1.path) }
        let ded = model.ringDeduction
        // 三档不上色的底：动得了的段用主色，其余只能靠灰的深浅分层。
        //
        // 这三档必须**分得开**，而且必须**比金色暗**。上一版 blocked 0.17 / unmeasured 0.45 /
        // 空闲用 separator，实拍逐段量出来是 (71,68,62)、(70,65,55)、(58,52,44)——三档灰差不到 12，
        // 眼睛读成「一坨等大的灰」，也就是默认饼图。原型敢让空闲段几乎不画，
        // 是因为它把「一整块盘」这个形状交给轨道去闭合。
        // 0.10 / 0.22 是照着轨道 0.035 这条底线排的，三档每一步都看得见，
        // 而最亮那档也还不到金色的一半。
        // 深皮换成 `ringGrey` 之后透明度按 247/164≈1.5 乘上来补回亮度，分层原样不动：
        // 实拍带中圈灰弧 L 77.6（金色那档 215），而红道减蓝道从 ink 版的 +47 收到 +23
        // （样稿同位 +20）——环带上的芥末味就是这么没的。
        // 2026-09-25 用 measure_ring.py 在**同名槽位**上重量了一遍，三档全都比样稿暗
        // 20~34 个灰阶：我这边 (63,61,53) / (82,84,80) / (51,48,35)，样稿带中圈
        // mix(其他已统计) (97,89,77)、dust(没量到) (93,90,88)、free(空余) (71,60,47)。
        // 于是整圈只剩那一条金弧看得见，「这一圈 = 整块盘」当场不成立——
        // 样稿那张图首先是一块**亮**的盘，其次才是金。
        // 分层也不再按「越亮越要紧」排：样稿的 mix 与 dust 一样亮（差 4 个灰阶），
        // 把它们分开的是色温，R−B 一个 +20 一个 +5。所以这里暖＝量到了、冷＝没量到，
        // 空闲单独压到 L≈62 当这条带的地板（它比轨道亮，但一眼读得出「没画东西」）。
        // 差多少按当天的实测比补：样稿带中圈 / 我这边 = 97/86、93/84、71/61，
        // 于是 0.23→0.26、0.40→0.44、0.09→0.105。透明度到像素不是线性的（底下还压着
        // 轨道和卡面），所以补完必须再量一遍，不能当算完了。
        let warm = darkSkin ? Color(red: 247 / 255, green: 246 / 255, blue: 243 / 255)
                            : theme.palette.ink
        let blocked = warm.opacity(dark ? 0.26 : 0.09)       // 量到了，动不了：暖白那一档
        let unmeasured = ringGrey.opacity(dark ? 0.44 : 0.16) // 压根没量到：冷灰那一档
        let freeArc = warm.opacity(dark ? 0.105 : 0.025)      // ≈ 轨道，几乎不画但要闭合整圈
        var out: [GaugeSegment] = []
        // 分段算术由 Core 的纯函数把关（自检钉的是「四块加起来等于已用」）；
        // 不成立就两块都不画，宁可留一块大的「没量到」也不画一张对不上的图。
        let split = ringSplit(covered: model.covered, used: u.used, topSum: topSum,
                              movedOutTop: ded.top, movedOutRest: ded.rest)
        // 先把每条弧动得了多少全算出来，再一次性定「可回收」那一列印成什么样：
        // 各行各自四舍五入会各自往上飘，屏幕上就成了「12.0 + 6.3 + 4.2 = 22.5」而圆心写
        // 22.4。这一列必须加得起来，因为它和圆心那个数是同一笔账。
        let topCan = top.map { model.reclaimable(of: $0.path) }
        let restCan = split.map { model.restReclaimable($0.restMeasured) } ?? 0
        let canParts = topCan + [restCan]
        let canTexts = addableHuman(canParts, total: canParts.reduce(Int64(0), +))
        let restText = canTexts[topCan.count]
        var reclaim: Int64 = 0
        for (i, h) in top.enumerated() {
            // 弧上画的是「还在原处的」，不是「这一轮量到的」：搬走 5G 之后弧就该小 5G，
            // 而下面列表里那一行报的是同一个数。两个口径同屏是这一屏最快塌掉的地方。
            let size = model.arcSize(of: h.path)
            let can = topCan[i]
            reclaim += can
            out.append(GaugeSegment(
                label: h.name, value: size,
                color: can > 0 ? SweepRing.lamp(theme.palette.tint) : blocked,
                tone: can > 0 ? .hot : .neutral,
                sub: hotArcNote(can: can, text: canTexts[i],
                                movedOut: model.movedOut(of: h.path)),
                path: h.path, reclaim: can, reclaimText: canTexts[i],
                targets: model.reclaimTargets(of: h.path),
                drill: .children(h.path)))
        }
        let topReclaim = reclaim
        var restReclaim: Int64 = 0
        var restMeasured: Int64 = 0
        var untouched: Int64 = 0
        var trash: Int64 = 0
        if let s = split {
            restMeasured = s.restMeasured
            untouched = s.untouched
            trash = s.trash
            if s.restMeasured > 0 {
                // 这条弧以前恒记 0，于是它明明占着一整段角度却总是灰的。可缓存并不因为
                // 「没挤进前三名」就变成不能清的东西：真机上这条弧名下能清出好几 G，
                // 弧上却写着「动不了」，而缓存页下一秒就把它们列成可勾——招牌画面报的数
                // 比自家另一页小，那就是错。
                let can = restCan
                restReclaim = can
                reclaim += can
                out.append(GaugeSegment(
                    label: L("其他已统计"), value: s.restMeasured,
                    color: can > 0 ? SweepRing.lamp(theme.palette.tint) : blocked,
                    tone: can > 0 ? .hot : .neutral,
                    sub: can > 0 ? LF("%1$@ 可回收 · 这一条弧是第 4 名往后的那些位置",
                                      restText)
                                 : L("第 4 名往后，点开这一行就是它们的名字"),
                    reclaim: can, reclaimText: restText,
                    targets: model.restReclaimTargets(), drill: .restGroup))
            }
            if s.trash > 0 {
                // 虚线：这些字节还占着盘，只是换了地方。画成实线就是在说「已经腾出来了」，
                // 而真正让位要等用户在废纸篓页交给访达。
                out.append(GaugeSegment(label: L("本次移入废纸篓"), value: s.trash,
                                        color: SweepRing.lamp(theme.palette.tint)
                                            .opacity(dark ? 0.62 : 0.48),
                                        tone: .moved,
                                        sub: L("还占着盘 · 去废纸篓页才让位"),
                                        jumpTo: Self.trashAnchor, dashed: true,
                                        hint: L("去废纸篓页：这些字节还占着盘，在那里交给访达清空才真让位")))
            }
            if s.untouched > 0 {
                // 正在扫的时候这块不是结论，是进度：叫成「没量到的地方」会让人以为
                // 这一坨永远清不动，而它下一秒就会缩。
                out.append(GaugeSegment(label: model.scanning ? L("还没量到") : L("没量到"),
                                        value: s.untouched, color: unmeasured, tone: .neutral,
                                        sub: L("密封系统卷等，任何清理工具都动不了"),
                                        drill: .gapRows))
            }
        }
        // 系统记作可用、此刻却还占着盘的那一块（快照、缓存）。必须单列：
        // 「可用」跟系统设置对齐之后，环形里就得有一块弧代表它，
        // 否则前 3 ＋ 其他 ＋ 整盘 ＋ 量不到 ＋ 可用加起来不等于整块盘，图又成了装饰。
        if u.purgeable > 0 {
            out.append(GaugeSegment(label: L("系统可清除"), value: u.purgeable,
                                    color: SweepRing.lamp(theme.palette.tint)
                                        .opacity(dark ? 0.26 : 0.20),
                                    tone: .washed,
                                    sub: L("系统随时自己腾，不用这个工具动手")))
        }
        // 这条弧叫「空闲」不叫「可用」：上面那个「可用」是系统口径（含可清除），
        // 两条弧一个代表空闲、一个代表可清除，加起来才等于那个可用。
        out.append(GaugeSegment(label: L("空闲"), value: u.free,
                                color: freeArc, tone: .neutral,
                                sub: L("已经空着的地方")))
        // 这一列右边明写着「各段之和 494.4 GB」——那是一句算术承诺：各行印出来的数
        // 必须真加得出它。逐行 `human()` 做不到，2026-09-25 真机实拍那一列加成 494.5。
        // 交给 Core 把整列统一到总数的单位、按最大余数分掉那几格；传 `u.total` 而不是
        // 各行之和，是在这里顺手验一次那条恒等式——不成立就整列退回逐行 `human()`，
        // 宁可各说各的，也不许凑出一列加得起来的假账。
        let sizeTexts = addableHumanColumn(out.map { $0.value }, total: u.total)
        for i in out.indices { out[i].sizeText = sizeTexts[i] }
        return RingAccount(segs: out, reclaimable: reclaim,
                           measuredIdle: max(0, netTopSum - topReclaim)
                                        + max(0, restMeasured - restReclaim),
                           untouched: untouched, inBin: trash,
                           free: u.free, purgeable: u.purgeable, total: u.total)
    }

    /// 前几名各自那一行小字。三种情况三句话说，别拿一句套三种：
    /// 一分都没动的说「还剩多少能搬」，搬走过一部分的要额外报已经少了一截，
    /// 而整个目录搬不走的**不能写成「0 B 可回收」**——那是把「这里头有能清的东西、
    /// 只是不按整个目录清」说成了「这里没东西」，而下面那列恰恰列着它的缓存。
    ///
    /// `text` 是外面按「这一列加起来要等于圆心总数」分配好的那个字符串，不在这里现算
    /// `human(can)`——各行独立四舍五入会飘出 0.1，那一列就和圆心对不上了。
    private func hotArcNote(can: Int64, text: String, movedOut: Int64) -> String {
        if can <= 0 { return L("不整体搬走 · 点开这一行看明细") }
        if movedOut > 0 {
            return LF("%1$@ 可回收 · 已搬走 %2$@", text, human(movedOut))
        }
        return LF("%1$@ 可回收", text)
    }

}

// MARK: - 摊开后的下一级行

/// 明细往右缩进多少：跟上方账目行的**名字**对齐在同一条竖线上（行内边距 8 +
/// 展开槽 12 + 间距 12 + 色块 8 + 间距 12）。明细行、条子、尾巴那句对账共用这一个数——
/// 差一截的话那句对账就悬在列表外面，读不出它说的是哪一组。
private let drillIndent: CGFloat = 52

/// 摊开后的一行明细。行解剖跟账目行同一副：图形在名字左边、名字在上、条子在下、
/// 数在右肩，只有真动得了的那一档给灯色。
///
/// 那个数由调用方整列过一次 `addableHumanColumn` 再传进来，不在这里 `human()`：
/// 这一列底下明写着「合计 x GB」那句对账，各行独立四舍五入会各自往上飘，
/// 那句就永远加不回来——同一屏两本账是这一页塌过的每一次的形状。
private struct DrillRow: View {
    @Environment(\.theme) private var theme
    /// 行首那一格：这一行的下一级就是一个真实目录，走同一套三档判图（归属 App →
    /// 品牌标 → 系统通用图）。原先这一列只有文字，24 格里 24 个名字，认不出谁是谁的。
    var icon: RowIcon
    var name: String
    var path: String
    var sizeText: String
    /// 这一格名下真能搬走的。判据跟环形、账目列同一个口径（知识库白名单），
    /// 不是「整处搬不搬得走」——后者会让明细说「只能看」而同一列写着「3.1 GB 可回收」。
    var reclaim: Int64
    /// 这一**列**的尺：父行那个数（右侧那一列就是按它统一分档的）。
    ///
    /// 不传的话两把尺并排印：2026-09-26 实拍「其他已统计」摊开那一屏，一行印的是
    /// 「943.7 MB 可回收　0.9 GB」——读起来像可回收的比整处还多。取整列那把尺之后
    /// 小到不足一个刻度的写成「< 0.1 GB」，跟左边那一列同一套规矩。
    var ruler: Int64
    var fraction: Double

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RowIconView(icon: icon)
                .frame(width: rowIconSide, height: rowIconSide)
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 条子定宽、不铺满：贴到行尾的长条会被读成分隔线，
                // 而这一列上面那六行的条子就是这个宽度，两档尺没意义。
                ProportionBar(fraction: fraction,
                              color: reclaim > 0 ? SweepRing.lamp(theme.palette.tint)
                                                 : theme.palette.inkTertiary,
                              track: theme.palette.surfaceAlt,
                              height: 3, trackWidth: 232)
            }
            Spacer(minLength: 10)
            // 动不了的必须当场说「只能看」。一列全是数、没有这一句，
            // 人就只剩「按下去大概能删」这一种预期，而那正是错的那种。
            Text(reclaim > 0 ? LF("%1$@ 可回收", human(reclaim, inRulerOf: ruler)) : L("只能看"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(reclaim > 0 ? SweepRing.lamp(theme.palette.tint)
                                             : theme.palette.inkTertiary)
                .fixedSize()
            SizeNumber(shown: sizeText, size: 15,
                       color: reclaim > 0 ? theme.palette.ink : theme.palette.inkSecondary)
            ThemeButton(kind: .ghost, title: L("访达显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .help(LF("在访达里打开 %@", path))
        }
        .padding(.vertical, 3)
        // 图形落在名字左边那一格，缩进要让出图形位（26 + 间距 10）：
        // 名字仍跟上面账目行的名字在同一条竖线上，尾巴那句对账也才对得上这一列。
        .padding(.leading, drillIndent - rowIconSide - 10)
    }
}

// MARK: - 正在量的占位行

/// 还没量完的目录先占一行，路径立刻出现在这一列里。
///
/// 体积要等整棵树走完才报得出来，一趟整盘扫描里最慢的那几处能跑几分钟。
/// 没有占位行的话，切完范围就是几分钟的空白——那看着跟「点了没反应」
/// 一模一样，而这一屏的全部卖点恰恰是「它在老老实实扫」。
private struct MeasuringRow: View {
    @Environment(\.theme) private var theme
    var name: String
    /// 首行不画分段线（样稿 `.row+.row::before`，第一行没有）。
    var showRule: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            // 行首那道空槽是账目列的展开记号位。占位行没有下一级可摊，
            // 空着也要占：不占的话这一列的名字会随扫描进度左右跳。
            Color.clear.frame(width: 12, height: 12)
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.inkTertiary)
                .frame(width: 8)
            Text(name)
                .font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(L("正在量"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if showRule {
                Rectangle().fill(theme.palette.separator.opacity(0.7))
                    .frame(height: 1).padding(.horizontal, 8)
            }
        }
    }
}
