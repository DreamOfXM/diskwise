# Privacy Policy / 隐私政策

**DiskWise** · 生效日期 / Effective: 2026-09-27

## English

DiskWise is a local disk-cleanup utility. **We do not collect, store, or transmit any of your
data.** There is no account, no analytics, no crash reporting, no advertising, and no telemetry
of any kind — the app has no network access at all.

Everything happens on your own Mac, at the moment you run the app:

- **What the app reads.** Directory listings and file metadata (size, modification time, symlink
  targets) for the locations the scan reaches, so it can show you what is using your disk. The
  direct-download build walks the whole volume from a whitelist of roots, which includes system
  areas and other users' home folders; the Mac App Store build is confined by the sandbox to the
  folder you grant once (your home) plus `/Applications`. It does not read the *contents* of your
  documents. One opt-in exception: the content probe (off by default). When you turn it on, the app
  reads the first 64 KB of crash-dump files it has identified, solely to tell which process wrote
  them; those file headers never leave your machine.
- **What the app writes.** Only its own data on your Mac: which appearance skin you picked, which
  language the interface uses, — in the Mac App Store version — a security-scoped bookmark
  recording which folder you granted access to, and a small local SQLite database of scan
  snapshots (sizes and file counts of recognized items, kept to the last 30 scans) so growth can
  be compared across scans. All of it lives on your machine and never leaves it.
- **Deletions.** DiskWise never deletes outright. Items you choose are moved to the macOS Trash
  through the system's own Trash mechanism, and emptying the Trash is a separate action you take.
  In the direct-download build the app asks Finder to empty it and Finder confirms with you first;
  in the Mac App Store build the sandbox does not allow that request at all, so the app only opens
  the Trash and you empty it yourself in Finder.
- **Feedback.** If you contact us by email, the messaging group, or a GitHub issue, you are doing
  so yourself through a third-party service; whatever you include in that message is governed by
  that service's policy, not by this app.

DiskWise requests macOS permissions only where the operating system requires them to deliver a
feature you asked for — for example, in the direct-download build, permission to send Finder the
"empty the Trash" command. The App Store build never asks for it: the sandbox refuses that command,
so there the app only opens the Trash window. Each grant can be revoked in System Settings.

Questions: open an issue at <https://github.com/DreamOfXM/diskwise/issues>.

## 中文

DiskWise 是一款本地磁盘清理工具。**我们不收集、不存储、不上传你的任何数据**：没有账号体系，
没有统计埋点，没有崩溃上报，没有广告，也没有遥测——这个 App 不具备联网能力。

所有处理都发生在你自己的 Mac 上、在你运行它的那一刻：

- **读什么。** 扫描走到的位置里的目录结构和文件元信息（大小、修改时间、符号链接指向），用来告诉你
  空间被什么占着。直链下载版会走整块盘能读的根（`/Library`、`/opt`、`/private`、`/usr/local`
  以及别人的家目录，都只算账不伸手）；Mac App Store 版被沙盒限在你点过一次授权的家目录和
  `/Applications`。它不读取文档的**内容**。唯一的例外是内容探针（默认关闭）：你打开它之后，
  App 只会读取已识别出的崩溃转储文件的头部 64 KB，用来判断是哪个进程写下的；
  这些文件头只留在本机，不会离开。
- **写什么。** 只写它自己在本机的数据：你选了哪套皮肤、界面用哪种语言，（Mac App Store 版）
  一条记录着你授权了哪个文件夹的安全书签，以及一个很小的本地 SQLite 快照库——记录已识别条目
  的体积与文件数、滚动保留最近 30 次扫描，用来对比增长。这些都在你的机器上，不会离开本机。
- **删除怎么做。** DiskWise 从不直接删除。你选中的项目通过系统自带的机制移入废纸篓；清空废纸篓
  是你另外发起的动作。直链下载版请访达执行，访达会让你确认后才动手；Mac App Store 版在沙盒里
  发不出这条指令（实测系统直接拒绝，连授权框都不弹），那一版只把废纸篓窗口打开，由你在访达里自己清空。
- **反馈。** 如果你通过邮件、群或 GitHub issue 联系我们，那是你主动通过第三方服务发起的，
  你在那条消息里写的内容由该服务的政策约束，与本 App 无关。

DiskWise 只在操作系统要求的地方申请权限：直链下载版清空废纸篓时要你放行「控制访达」，
Mac App Store 版则是启动时请你点选一次要授权的文件夹（那一版发不出控制访达的指令，系统直接拒）。
每一项都可以在「系统设置」里撤回。

有疑问请提 issue：<https://github.com/DreamOfXM/diskwise/issues>。
