# DiskWise for AI agents — CLI 与 MCP 安全模型

`diskwise` 是 DiskWise 的命令行形态（直装版随 App 附带；App Store 沙盒版不带）。
它把 App 的清理能力开放给终端与 AI agent（Claude Code、Cursor、Codex……），
但安全模型原封不动，且对 agent **更严**：

> **它不能 `rm -rf`。** 唯一的删除路径是把东西移进废纸篓，且每次操作都可整单撤销。

## 安全模型

**四档判词**（与 App 同一知识库，`safety_db.json`，现 72 条）：

| tier | 含义 | agent 能动吗 | `--i-am-human` 能动吗 |
|---|---|---|---|
| `safe` | 删了没影响，会自动重建（DerivedData、pip 缓存…） | ✅ | ✅ |
| `redo` | 认得，删了要重新下载（模型权重、依赖仓库…） | ✅（须用户同意计划） | ✅ |
| `risky` | 删了就真没了（模拟器设备、聊天记录…） | ❌ | ❌（谁都不行） |
| `unknown` | 知识库不认识（没命中 ≠ 安全） | ❌ | ✅ |

**agent 额外的三道闸**（人用 App 时没有的）：

1. **只动认识的位置本体**：agent 点名的路径必须就是知识库条目（或其通配实例）。
   缓存目录里用户自己建的子文件夹会拒（`not_a_known_location`）——人可以动它
   （App 下钻页同款自由），agent 不行。
2. **两步确认**：`plan` 生成计划文件（**10 分钟有效**、最多 **200 项 / 200 GB**），
   `trash` 只认 plan_id、不收裸路径；执行时**逐项重跑判定管线并核对 inode**——
   计划生成之后路径被换成软链（`symlink`）或原地换过内容（`changed_since_plan`）
   都会被当场拦下。
3. **持久留痕**：每次执行追加一行 `operations.jsonl`（只追加、永不改写），
   `undo` 按日志整单恢复；废纸篓里已被清掉的项报 `gone_from_trash`，不影响其余。

判定管线（所有入口共用，顺序固定）：路径展开 → 保护路径（`~/Documents`、`/`…）
→ 范围（家目录、`/Applications`、`/tmp`、`/var/tmp` 之外不动）→ lstat（不存在 /
软链拒绝）→ 知识库判词 → 放行。MCP 模式下**不存在** `--i-am-human`。

## 命令

```
diskwise scan [--category all|dev|ai_models|apps] [--min 100MB] [--json]
diskwise explain <path> [--json]
diskwise plan <path>... [--i-am-human] [--json]
diskwise trash --plan <plan_id> [--json]     # 只认 plan_id
diskwise undo [<operation_id>] [--json]
diskwise history [--limit 20] [--json]
diskwise mcp                                 # stdio MCP server
diskwise --version
```

- stdout 只放结果（agent 解析它），日志走 stderr；`--json` 键为 snake_case、时间 ISO8601；
- 退出码：`0` 成功 · `1` 参数错误 · `2` 有项被拒（部分成功也是 2，明细在输出里）· `3` 计划过期或不存在；
- 大小参数十进制（`500MB`、`2GB`、纯字节），与 App 同口径。

状态目录：`~/Library/Application Support/DiskWise/agent/`（`plans/` 计划文件、
`operations.jsonl` 操作日志）。CLI 单写者假设：同一时刻只跑一个写操作。

## 接入 Claude Code

```sh
claude mcp add diskwise -- /Applications/DiskWise.app/Contents/MacOS/diskwise mcp
```

## 接入 Cursor

`~/.cursor/mcp.json`：

```json
{
  "mcpServers": {
    "diskwise": {
      "command": "/Applications/DiskWise.app/Contents/MacOS/diskwise",
      "args": ["mcp"]
    }
  }
}
```

## 接入 Codex

`~/.codex/config.toml`：

```toml
[mcp_servers.diskwise]
command = "/Applications/DiskWise.app/Contents/MacOS/diskwise"
args = ["mcp"]
```

Homebrew 用户：cask 提供 `diskwise` 命令（发新版起加入 `binary` 一行后），
上述配置里的路径可换成 `/opt/homebrew/bin/diskwise`。

## MCP 工具

| 工具 | 说明 |
|---|---|
| `scan_disk(category?, min_bytes?)` | 只读：扫知识库认识的位置并量体积 |
| `explain_path(path)` | 只读：一个路径的完整画像与拒绝原因 |
| `plan_cleanup(paths[])` | 只读：生成计划。**description 要求模型把摘要给用户看、取得同意后再执行** |
| `execute_cleanup(plan_id)` | 按计划移入废纸篓（可撤销，`destructiveHint: false`） |
| `undo_cleanup(operation_id?)` | 整单恢复 |
| `cleanup_history(limit?)` | 只读：最近操作 |

业务错误（被拒、过期、超限）以 `isError: true` 的结果返回并附下一步指引
（例如 `plan_expired` → 重新 `plan_cleanup`）。

## 一段真实对话（Claude Code + diskwise MCP）

> **我**：看看我的 Mac 哪里能清
>
> **assistant**（调 `scan_disk`）：
> 扫描结果（category=dev，min_bytes=100000000）：
> - 总共 30 处；agent 能动 23 处，合计约 57.7 GB；
> - 最大三项：OrbStack 虚拟机磁盘 19.7 GB（`may_lose_data`，不能动）、
>   Ollama 模型 17.7 GB（`redo`，能动能撤销）、iOS 模拟器运行时 16.6 GB
>   （系统区，`outside_allowed`）。
> 要清哪些？
>
> **我**：把 Ollama 和 oMLX 的模型清了吧
>
> **assistant**（调 `plan_cleanup`）：
> 计划已生成，两项合计 31.4 GB，进废纸篓（可随时撤销）：
> `~/.ollama/models` 17.7 GB · `~/.omlx/models` 13.7 GB。确认执行吗？
>
> **我**：可以
>
> **assistant**（调 `execute_cleanup`）：
> 已移入废纸篓，腾出 31.4 GB。后悔的话说一声，我用 undo_cleanup 原样放回。

## 维护备注

- 直装版打包：`build_app/build.sh` 会把 CLI 编进 `Contents/MacOS/diskwise`，
  **先单独签嵌套二进制、再签整包**（两个签名分支都如此），并在签名后冒烟
  `diskwise --version`；App Store 分支不拷贝 CLI。
- 发新版时 cask 需加一行：`binary "#{appdir}/DiskWise.app/Contents/MacOS/diskwise"`
  （连同 version / sha256 一起更新；当前未加，因为线上最后一个 DMG 里还没有这个二进制）。
- 词表：CLI/MCP 面向 agent 的解释字段走 `en.lproj/Localizable.strings` 查表，
  查不到回落中文原文；`DISKWISE_RESOURCES` 环境变量可覆盖资源目录（测试用）。
