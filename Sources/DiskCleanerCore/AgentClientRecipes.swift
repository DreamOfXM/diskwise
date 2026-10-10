import Foundation

// ── 八家 MCP 客户端各自的接法形状 ─────────────────────────────────────────
//
// 为什么这段代码值得单独存在：页面上那一行可复制的东西是**发给别人终端的指令**，
// 形状错了就等于我们对外发了一条跑不通的命令。而「形状」只有客户端自己说了算——
// `claude mcp add` 是 Claude Code 的方言，OpenCode 要的是数组形的 `command`，
// Zed 的键叫 `context_servers` 不叫 `agent_servers`。把这些收进一个枚举、
// 每段都有断言钉着，比在视图里散着八条字符串强。
//
// 住 Core 的理由和 AgentLedger 一样：SelfTest 只连得到这边。这里一律不出现中文
// ——「放在哪儿」那句说明是界面层文案（见 Sources/DiskCleaner/Views/AgentPageView.swift），
// 混进来只会让词表多一堆屏幕上看不见、翻错了也没人发现的词条。
//
// 共同的只有两样：这个二进制的绝对路径（运行时实测，见 `agentCLILocation`）和参数
// `mcp`。片段一律现拼，不写死 /Applications——装到别处的人照抄就错了。
//
// 出处：各家 2026-10-10 当天的官方文档（见 docs/AGENTS-CLI.md 末尾那条口径），
// 其中 Claude Code / Qoder / OpenCode 三家在本机真握手过（Connected）。

/// 一段能直接粘出去的东西。
public struct AgentSnippet: Equatable {
    /// 决定界面用哪种块画它：单行命令还是多行配置。
    public enum Kind: Equatable {
        case shell
        case json
        case toml
    }

    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// 我们逐个核对过形状的客户端。`allCases` 的顺序就是界面上那排胶囊的顺序。
///
/// 列了八家不等于只有八家能用：任何支持本地 stdio MCP 的客户端都接得动，因为这
/// 八家之外没有第二种协议。列出来的是**我们敢直接给片段**的那些；别家的用户照
/// 自己客户端的文档填这两个值即可，接不上是客户端侧的问题，欢迎开 issue 或提 PR。
public enum AgentClient: String, CaseIterable, Equatable {
    case claudeCode
    case codex
    case qoder
    case cursor
    case openCode
    case zed
    case zcode
    case claudeDesktop

    /// 界面上的名字。专名不进词表——翻成「克劳德代码」只会让人认不出自己在用啥。
    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .qoder: return "Qoder"
        case .cursor: return "Cursor"
        case .openCode: return "OpenCode"
        case .zed: return "Zed"
        case .zcode: return "ZCode"
        case .claudeDesktop: return "Claude Desktop"
        }
    }

    /// 这一家要粘的东西。可能多段（Qoder 命令行与 IDE 两种接法都给）。
    public func snippets(cliPath: String) -> [AgentSnippet] {
        let q = agentQuotedForShell(cliPath)
        let j = agentJSONString(cliPath)
        switch self {
        case .claudeCode:
            return [AgentSnippet(.shell, "claude mcp add diskwise -- \(q) mcp")]
        case .codex:
            return [
                AgentSnippet(.shell, "codex mcp add diskwise -- \(q) mcp"),
                AgentSnippet(.toml, """
                [mcp_servers.diskwise]
                command = \(j)
                args = ["mcp"]
                """),
            ]
        case .qoder:
            return [
                AgentSnippet(.shell, "qoder mcp add diskwise -- \(q) mcp"),
                AgentSnippet(.json, agentMcpServersJSON(pathJSON: j, type: nil)),
            ]
        case .cursor:
            return [AgentSnippet(.json, agentMcpServersJSON(pathJSON: j, type: "stdio"))]
        case .openCode:
            return [AgentSnippet(.json, """
            {
              "$schema": "https://opencode.ai/config.json",
              "mcp": {
                "diskwise": {
                  "type": "local",
                  "command": [\(j), "mcp"],
                  "enabled": true
                }
              }
            }
            """)]
        case .zed:
            return [AgentSnippet(.json, """
            {
              "context_servers": {
                "diskwise": {
                  "command": \(j),
                  "args": ["mcp"]
                }
              }
            }
            """)]
        case .zcode:
            return [AgentSnippet(.json, """
            {
              "mcp": {
                "servers": {
                  "diskwise": {
                    "command": \(j),
                    "args": ["mcp"]
                  }
                }
              }
            }
            """)]
        case .claudeDesktop:
            return [AgentSnippet(.json, agentMcpServersJSON(pathJSON: j, type: nil))]
        }
    }
}

/// `mcpServers` 那一族（Qoder 的 IDE 侧、Cursor、Claude 桌面版）共用一个形状，
/// 差别只有 Cursor 按官方字段表要显式写 `type`。
private func agentMcpServersJSON(pathJSON: String, type: String?) -> String {
    var lines = ["{", "  \"mcpServers\": {", "    \"diskwise\": {"]
    if let type { lines.append("      \"type\": \"\(type)\",") }
    lines.append("      \"command\": \(pathJSON),")
    lines.append("      \"args\": [\"mcp\"]")
    lines.append("    }")
    lines.append("  }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// 客户端自报的 `clientInfo.name` → 我们核对过的那一家。
///
/// **先长后短**是这里唯一的要害：`claude-desktop` 必须排在 `claude` 前面，否则
/// 桌面版上账会被叫成 Claude Code——两个不同的客户端在账本上长同一个名字，
/// 那一行就没法信了。认不出来的返回 nil，交给调用方按原样照抄。
public func agentClient(matchingReported raw: String) -> AgentClient? {
    let key = raw.lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    let ordered: [(String, AgentClient)] = [
        ("claude-desktop", .claudeDesktop),
        ("claude", .claudeCode),
        ("codex", .codex),
        ("qoder", .qoder),
        ("cursor", .cursor),
        ("opencode", .openCode),
        ("sst-opencode", .openCode),
        ("zed", .zed),
        ("zcode", .zcode),
        ("z-code", .zcode),
    ]
    for (prefix, client) in ordered where key.hasPrefix(prefix) { return client }
    return nil
}

/// 终端里的路径：带空白必须加引号，否则粘进去就是一句断掉的话。
public func agentQuotedForShell(_ path: String) -> String {
    path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ? "\"\(path)\"" : path
}

/// 进 JSON 字符串字面量。反斜杠和引号都要转义——装到带引号的目录里的人不多，
/// 但一处不转义，粘出去的整段就是废的，而且坏在中间看不出来。
public func agentJSONString(_ value: String) -> String {
    var out = "\""
    for ch in value {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(ch)
        }
    }
    return out + "\""
}
