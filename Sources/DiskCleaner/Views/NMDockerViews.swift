import SwiftUI
import DiskCleanerCore

// ── node_modules：按项目聚合，删了重装回来就行 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class NMModel: ObservableObject {
    @Published var items: [NMProject] = []
    @Published var scanning = false
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil

    var selected: [NMProject] { items.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func scan() {
        task?.cancel()
        scanning = true
        started = true
        items = []
        task = Task {
            let list = await findNodeModules()
            if !Task.isCancelled {
                self.items = list
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

struct NMView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: NMModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "shippingbox", title: L("依赖能重装，空间先拿回"),
                           subtitle: L("删了跑不起来？npm install 一把梭"))
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在全盘找 node_modules…"))
                    } else {
                        Text(LF("%1$@，共 %2$@", cnt(model.items.count, "个项目"), human(model.totalBytes)))
                    }
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 18)
            .padding(.bottom, 12)

            if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "shippingbox", title: L("没找到 node_modules"),
                           hint: L("这台机器大概不写前端"))
                    .frame(maxHeight: .infinity)
            } else {
                List($model.items) { $it in
                    ItemRow(selected: $it.selected,
                            name: URL(fileURLWithPath: it.project).lastPathComponent,
                            sub: nmSub(it),
                            sizeText: human(it.size),
                            fraction: Double(it.size) / Double(maxSize),
                            badge: it.partial ? ItemBadge(text: L("部分"), tone: .warn) : nil) {
                        ExplainLine(key: L("这是什么"), value: L("Node.js 项目的依赖文件夹，只在开发这个项目时用到"))
                        ExplainLine(key: L("删了会怎样"), value: L("这个项目暂时跑不起来；不影响源码与 package.json"))
                        ExplainLine(key: L("怎么恢复"), value: L("在项目目录执行 npm install（或 pnpm/yarn），按 package.json 原样装回"))
                        PathLine(path: it.project)
                    }
                    .themedRow()
                }
                .themedList()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     errorText: err) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("node_modules")
        .onAppear { if !model.started { model.scan() } }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@的依赖（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "个项目"),
                               human(model.selectedBytes))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.items.map(\.size).max() ?? 1) }

    private func nmSub(_ it: NMProject) -> String {
        [cnt(it.nmCount, "个包"), it.date, it.partial ? L("部分统计") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        // 删项目下的 node_modules（可能多个）
        for it in model.selected {
            let projName = URL(fileURLWithPath: it.project).lastPathComponent
            let nmURL = URL(fileURLWithPath: it.project).appendingPathComponent("node_modules")
            let targets = (try? FileManager.default.contentsOfDirectory(atPath: it.project)
                .filter { $0 == "node_modules" }
                .map { URL(fileURLWithPath: it.project).appendingPathComponent($0) }) ?? [nmURL]
            for t in targets {
                guard FileManager.default.fileExists(atPath: t.path) else { continue }
                do {
                    let dst = try trashItem(t)
                    store.record(TrashRecord(original: t, inTrash: dst, size: it.size,
                                             displayName: "\(projName)/node_modules"))
                    ok += 1
                } catch { errs.append(failLine(it.project, error)) }
            }
        }
        // 就地收尾：整个依赖目录都没了的项目从列表里消失，不必重扫全盘
        model.items.removeAll { !FileManager.default.fileExists(
            atPath: ($0.project as NSString).appendingPathComponent("node_modules")) }
        for i in model.items.indices { model.items[i].selected = false }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个 node_modules", failed: errs.count)
    }
}

// ── Docker：只读明细，不代删，只指路 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class DockerModel: ObservableObject {
    @Published var items: [DockerItem] = []
    @Published var scanning = false
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func scan() {
        task?.cancel()
        scanning = true
        started = true
        items = []
        task = Task {
            let list = await Task.detached { await scanDocker() }.value
            if !Task.isCancelled {
                self.items = list
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

/// Core 只给分类标识，措辞全在这里
private func dockerHead(_ it: DockerItem) -> String {
    switch it.kind {
    case .dfImages:      return L("镜像 · 合计")
    case .dfContainers:  return L("容器 · 合计")
    case .dfVolumes:     return L("卷 · 合计")
    case .dfCache:       return L("构建缓存 · 合计")
    case .image:         return it.title
    case .danglingImage: return LF("悬空镜像（%@）", it.title)
    case .rawDir:        return LF("Docker 数据 · %@", it.title)
    case .other:         return LF("%@ · 合计", it.title)
    }
}

private func dockerNote(_ it: DockerItem) -> String {
    switch it.kind {
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        return LF("共 %1$@ 个，活跃 %2$@ 个，可回收 %3$@",
                  it.total ?? "?", it.active ?? "?", it.reclaimable ?? "?")
    case .image, .danglingImage:
        return L("镜像存在 Docker 的虚拟盘里")
    case .rawDir:
        return L("Docker 未运行时的粗粒度分解")
    }
}

private func dockerHowTo(_ it: DockerItem) -> String {
    switch it.kind {
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        return L("打开 Docker Desktop 对应页面删除；本工具不代删（虚拟盘内无独立路径）")
    case .image, .danglingImage:
        return L("Docker Desktop → Images 里删除")
    case .rawDir:
        return L("更稳妥：在 Docker Desktop 里清理；这里删等于清空该子目录")
    }
}

struct DockerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: DockerModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "cube", title: L("鲸鱼肚子里看看"),
                           subtitle: L("只看不删——照指路去 Docker Desktop 里动手"))
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在问 Docker 都吃了啥…"))
                    } else {
                        Text(LF("共 %@", human(model.totalBytes)))
                    }
                    ThemeBadge(text: L("本页不设删除键"), tone: .neutral)
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 18)
            .padding(.bottom, 12)

            if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "cube", title: L("没发现 Docker 数据"),
                           hint: L("没装 Docker Desktop 就不会有"))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.items) { it in
                    DockerRow(item: it, fraction: Double(it.size) / Double(maxSize))
                        .themedRow()
                }
                .themedList()
            }
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(L("Docker 占用"))
        .onAppear { if !model.started { model.scan() } }
    }

    private var maxSize: Int64 { max(1, model.items.map(\.size).max() ?? 1) }
}

private struct DockerRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var item: DockerItem
    var fraction: Double

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Button {
                    withAnimation(reduceMotion ? nil : theme.animation) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron-down" : "chevron-right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.palette.inkTertiary)
                            .frame(width: 10)
                        Text(dockerHead(item))
                            .font(theme.bodyFont(.callout))
                            .foregroundStyle(theme.palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 10)
                Text(human(item.size))
                    .font(theme.numeric(.callout))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.ink)
            }
            ProportionBar(fraction: fraction, color: theme.palette.chart[5], height: 3)
                .padding(.leading, 16)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ExplainLine(key: L("说明"), value: dockerNote(item))
                    ExplainLine(key: L("怎么清"), value: dockerHowTo(item))
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(theme.cardShape().fill(theme.palette.surface))
        .overlay(theme.cardShape().stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
    }
}
