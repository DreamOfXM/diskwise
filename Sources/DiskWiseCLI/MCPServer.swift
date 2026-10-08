import DiskCleanerCore
import Foundation

// MCP server（stdio）：按行分帧的 JSON-RPC 2.0，不引第三方库。
//
// 协议面刻意做窄：initialize / notifications/initialized / tools/list /
// tools/call / ping，其余带 id 的方法回 -32601——未知方法在 MCP 里几乎总是
// 客户端版本差异，明确报错比静默成功安全。
//
// stdout 只写协议帧（调试一律 stderr），业务错误（被拒/过期/超限）用
// isError: true 的**结果**返回而不是 JSON-RPC error：模型要看的是原因码与
// 下一步指引，不是传输层的报错。

enum MCPServer {

    /// 客户端在 initialize 里自报的名字（clientInfo.name），落进操作日志回答
    /// 「这次是谁干的」。没 initialize 就直接调、或没报名字的，记 "mcp"。
    static var clientName = "mcp"

    static func run() async {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        // 同步逐块读 + 手动按 \n 分帧：readabilityHandler 的回调不保证行完整，
        // 而每条消息必须独占一行（MCP stdio 规范，正文不得内嵌换行）
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }   // EOF：客户端走了，跟着退
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer = Data(buffer[buffer.index(after: idx)...])
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    await handle(line: line)
                }
            }
        }
    }

    // MARK: - 帧处理

    static func handle(line: String) async {
        guard let req = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            reply(id: nil, error: (code: -32700, message: "Parse error"))
            return
        }
        let id = req["id"]
        let method = req["method"] as? String ?? ""
        // 通知（无 id）不回包——回了客户端只会当协议错误
        guard id != nil else { return }
        let params = req["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            let version = (requested != nil && supported.contains(requested!)) ? requested! : "2025-06-18"
            // 自报名字记下来：execute 时随操作落日志（来源标注见 clientName）
            if let info = params["clientInfo"] as? [String: Any],
               let name = info["name"] as? String, !name.isEmpty {
                clientName = name
            }
            reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "diskwise", "version": cliVersion()],
                "instructions": "DiskWise exposes safe disk cleanup: scan known cache locations, "
                    + "explain any path, plan a cleanup, execute it (moves to Trash only, undoable). "
                    + "Always show the plan summary to the user and get their consent before execute_cleanup.",
            ])
        case "notifications/initialized", "initialized":
            // 到这里说明它带了 id（不合规但无害）：按通知处理，不回包
            break
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": tools()])
        case "tools/call":
            guard let name = params["name"] as? String else {
                reply(id: id, error: (code: -32602, message: "Invalid params: missing tool name"))
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (payload, isError) = await dispatch(name: name, arguments: arguments)
            var result: [String: Any] = [
                "content": [["type": "text", "text": payload.text]],
                "structuredContent": payload.structured,
            ]
            if isError { result["isError"] = true }
            reply(id: id, result: result)
        default:
            reply(id: id, error: (code: -32601, message: "Method not found: \(method)"))
        }
    }

    static func reply(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        if id == nil { msg.removeValue(forKey: "id") }
        write(msg)
    }

    static func reply(id: Any?, error: (code: Int, message: String)) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "error": [
            "code": error.code, "message": error.message,
        ]]
        if let id { envelope["id"] = id } else { envelope["id"] = NSNull() }
        write(envelope)
    }

    static func write(_ msg: [String: Any]) {
        let opt: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: opt) else { return }
        var out = data
        out.append(0x0A)   // 一行一帧，不带内嵌换行
        FileHandle.standardOutput.write(out)
    }

    // MARK: - 工具表

    static func tools() -> [[String: Any]] {
        let readOnly = ["readOnlyHint": true] as [String: Any]
        func tool(_ name: String, _ desc: String, props: [String: Any], required: [String],
                  annotations: [String: Any] = [:]) -> [String: Any] {
            [
                "name": name,
                "description": desc,
                "inputSchema": ["type": "object", "properties": props, "required": required],
                "annotations": annotations.isEmpty ? readOnly : annotations,
            ]
        }
        let pathProp = ["type": "string",
                        "description": "Absolute path; ~ and $HOME are expanded"] as [String: Any]
        return [
            tool("scan_disk",
                 "Scan the knowledge base of known cache/developer locations and measure real disk usage. "
                 + "Read-only. Categories: all | dev | ai_models | apps. min_bytes filters small entries (decimal).",
                 props: [
                     "category": ["type": "string", "enum": ["all", "dev", "ai_models", "apps"]] as [String: Any],
                     "min_bytes": ["type": "integer", "description": "Minimum size in bytes (decimal), e.g. 100000000"] as [String: Any],
                 ], required: []),
            tool("explain_path",
                 "Explain one path: what it is, what happens if deleted, how to restore, and whether the "
                 + "agent may trash it (refusal codes tell you why not). Read-only.",
                 props: ["path": pathProp], required: ["path"]),
            tool("plan_cleanup",
                 "Draw up a cleanup plan for the given paths. Touches NOTHING — returns plan_id, per-item "
                 + "sizes/tiers and refusals. ALWAYS show the summary to the user and get explicit consent "
                 + "before calling execute_cleanup. Plans expire after 10 minutes; re-plan if expired.",
                 props: ["paths": ["type": "array", "items": ["type": "string"]] as [String: Any]],
                 required: ["paths"]),
            tool("execute_cleanup",
                 "Execute a plan by id: moves the planned items to the Trash (the ONLY removal path — "
                 + "nothing is ever permanently deleted) and records an undoable operation. Every item is "
                 + "re-validated at execution time.",
                 props: ["plan_id": ["type": "string"] as [String: Any]],
                 required: ["plan_id"],
                 annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false,
                               "openWorldHint": false] as [String: Any]),
            tool("undo_cleanup",
                 "Restore every item of an operation (or the latest one) from the Trash to its original "
                 + "place. Items already gone from the Trash are reported, not treated as failures.",
                 props: ["operation_id": ["type": "string"] as [String: Any]], required: [],
                 annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false,
                               "openWorldHint": false] as [String: Any]),
            tool("cleanup_history",
                 "List recent operations with their items and whether they were undone. Read-only.",
                 props: ["limit": ["type": "integer"] as [String: Any]], required: []),
        ]
    }

    // MARK: - 分发

    struct ToolOut {
        let text: String
        let structured: [String: Any]
    }

    static func dispatch(name: String, arguments: [String: Any]) async -> (ToolOut, Bool) {
        switch name {
        case "scan_disk":
            let category = (arguments["category"] as? String).flatMap(AgentCategory.init(rawValue:)) ?? .all
            let minBytes = (arguments["min_bytes"] as? NSNumber)?.int64Value ?? 0
            let items = await agentScan(category: category, minBytes: minBytes)
            let trashable = items.filter(\.agentMayTrash)
            let total = contentsUnionSize(trashable.map { ($0.path, $0.bytes) })
            let text = "\(items.count) known locations found; agent may trash \(trashable.count) "
                + "of them (\(human(total)) total, nested paths counted once). "
                + "Use plan_cleanup with chosen paths."
            return (ToolOut(text: text, structured: structify(items)), false)

        case "explain_path":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return (ToolOut(text: "explain_path requires a non-empty 'path'",
                                structured: ["error": "invalid_params"]), true)
            }
            let item = await agentExplain(path: path)
            var text = "\(item.path) · \(human(item.bytes)) · tier \(item.tier)"
            if let n = item.name { text += "\n\(n)" }
            if let d = item.ifDeleted { text += "\nIf deleted: \(d)" }
            text += "\nagent may trash: \(item.agentMayTrash ? "yes" : "NO (\(item.refusal?.rawValue ?? "?"))")"
            return (ToolOut(text: text, structured: structify(item)), false)

        case "plan_cleanup":
            let paths = arguments["paths"] as? [String] ?? []
            guard !paths.isEmpty else {
                return (ToolOut(text: "plan_cleanup requires a non-empty 'paths' array",
                                structured: ["error": "invalid_params"]), true)
            }
            do {
                let plan = try await agentPlan(paths: paths)
                var text = "Plan \(plan.planId) created — valid ~10 min.\n"
                text += "\(plan.items.count) item(s), \(human(plan.totalBytes)) to free"
                if !plan.refused.isEmpty {
                    text += "; \(plan.refused.count) refused:\n"
                    text += plan.refused.map { "  \($0.path) — \($0.refusal?.rawValue ?? "?")" }
                        .joined(separator: "\n")
                }
                text += "\nShow this summary to the user and get consent, then execute_cleanup "
                    + "with plan_id \(plan.planId)."
                return (ToolOut(text: text, structured: structify(plan)), plan.refused.isEmpty ? false : true)
            } catch let e as AgentAPIError {
                return (agentErrorOut(e), true)
            } catch {
                return (ToolOut(text: "plan failed: \(error.localizedDescription)",
                                structured: ["error": "plan_failed"]), true)
            }

        case "execute_cleanup":
            guard let planId = arguments["plan_id"] as? String, !planId.isEmpty else {
                return (ToolOut(text: "execute_cleanup requires a non-empty 'plan_id'",
                                structured: ["error": "invalid_params"]), true)
            }
            do {
                let result = try agentExecute(planId: planId, client: clientName)
                var text = "Moved \(result.trashed.count) item(s), \(human(result.totalBytes)) to the Trash."
                if !result.failed.isEmpty {
                    text += "\nRefused/failed items:"
                    text += result.failed.map { "  \($0.path) — \($0.reason)" }.joined(separator: "\n")
                }
                text += "\nUndo anytime with undo_cleanup"
                    + (result.operationId.isEmpty ? "" : " (operation_id \(result.operationId))") + "."
                return (ToolOut(text: text, structured: structify(result)), result.failed.isEmpty ? false : true)
            } catch let e as AgentAPIError {
                return (agentErrorOut(e), true)
            } catch {
                return (ToolOut(text: "execute failed: \(error.localizedDescription)",
                                structured: ["error": "execute_failed"]), true)
            }

        case "undo_cleanup":
            let opId = arguments["operation_id"] as? String
            do {
                let statuses = try agentUndo(operationId: opId)
                let restored = statuses.filter { $0.status == "restored" }.count
                let text = "Restored \(restored)/\(statuses.count) item(s) to their original places."
                    + statuses.filter { $0.status != "restored" }
                        .map { "\n  \($0.path) — \($0.status)" }.joined()
                return (ToolOut(text: text, structured: structify(statuses)),
                        statuses.contains { $0.status == "failed" })
            } catch let e as AgentAPIError {
                return (agentErrorOut(e), true)
            } catch {
                return (ToolOut(text: "undo failed: \(error.localizedDescription)",
                                structured: ["error": "undo_failed"]), true)
            }

        case "cleanup_history":
            let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 20
            let ops = agentHistory(limit: limit)
            let text = ops.isEmpty
                ? "No operations yet."
                : "\(ops.count) operation(s), oldest first:\n"
                    + ops.map { op -> String in
                        let bytes = op.items.reduce(Int64(0)) { $0 + $1.bytes }
                        return "  \(op.id) · \(op.client ?? "unknown") · \(op.items.count) item(s) · \(human(bytes))"
                            + (op.undoneAt == nil ? "" : " · undone")
                    }.joined(separator: "\n")
            return (ToolOut(text: text, structured: structify(ops)), false)

        default:
            return (ToolOut(text: "Unknown tool: \(name)", structured: ["error": "unknown_tool"]), true)
        }
    }

    /// AgentAPIError -> 给模型的文案：必须自带下一步（plan_expired 是长对话常态）
    static func agentErrorOut(_ e: AgentAPIError) -> ToolOut {
        let msg: String
        switch e {
        case .planExpired: msg = "Plan expired (valid 10 min). Call plan_cleanup again for a fresh plan."
        case .planNotFound: msg = "No such plan. Call plan_cleanup to create one."
        case .planTooLarge(let items, let bytes):
            msg = "Plan too large: \(items) items / \(human(bytes)) (limits: 200 items / 200 GB). Plan fewer paths."
        case .invalidPath: msg = "No trashable path in the request."
        case .noUndoableOperation: msg = "Nothing to undo."
        }
        return ToolOut(text: msg, structured: ["error": e.description])
    }

    // MARK: - 结构化输出

    /// Encodable -> JSONSerialization 可写回的任意 JSON（structuredContent 用）
    static func structify<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder.agentAPI.encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func structify<T: Encodable>(_ value: [T]) -> [String: Any] {
        ["items": structifyArray(value)]
    }

    static func structifyArray<T: Encodable>(_ value: [T]) -> [[String: Any]] {
        guard let data = try? JSONEncoder.agentAPI.encode(value),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }
}

/// 与 main.swift 的 versionString 同源（MCP serverInfo 用）
func cliVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
}
