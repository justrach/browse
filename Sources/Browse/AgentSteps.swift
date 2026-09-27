import Foundation

// What graff did, named the way Harness names it.
//
// Harness and browse both talk to graff over ACP. A tool call arrives as a
// kind, a title, its raw input, the places it touched and what it printed or
// changed; Harness reduces that to a typed step — Run a command, Read or Edit
// a file, Search, Fetch a page, a Todo list, an Agent — and a turn's steps to
// one line: "Ran 2 commands · edited 1 file · 1 failed". This is that
// reduction, ported one to one from Harness's crates/harness/src/acp/
// normalize.rs (typed_call, tool_diff, map_update's plan) and crates/proto/
// src/view.rs (tool_chip_content, tool_group_summary), so a chat reads the
// same in either app. What browse adds is its own tools: the browser's,
// named for what they do rather than as a bare MCP call.

/// One step, typed.
struct Step: Codable, Equatable {
    enum Kind: String, Codable {
        case exec, read, write, edit, patch, search, glob, fetch, web, todo, agent, browse, other
    }
    var kind: Kind
    /// The one line beside the label: the command, the path, the query.
    var detail: String
    /// For `other`: the tool's own name, as Harness keeps it.
    var name = ""

    /// The line beside the label. A tool Harness can't type shows its own
    /// name there ("Tool · mcp__x__y"); graff's agent controls name their
    /// target ("Waiting on · agent 2").
    var shown: String { kind == .other && detail.isEmpty ? name : detail }

    /// Harness's chip label.
    var label: String {
        if kind == .other, !detail.isEmpty, !name.isEmpty { return name }
        return rawLabel
    }

    private var rawLabel: String {
        switch kind {
        case .exec: return "Run"
        case .read: return "Read"
        case .write: return "Write"
        case .edit: return "Edit"
        case .patch: return "Patch"
        case .search: return "Search"
        case .glob: return "Glob"
        case .fetch: return "Fetch"
        case .web: return "Web"
        case .todo: return "Todo"
        case .agent: return "Agent"
        case .browse: return "Browse"
        case .other: return "Tool"
        }
    }

    /// An SF Symbol standing in for Harness's icon of the same kind.
    var symbol: String {
        switch kind {
        case .exec: return "command"
        case .read: return "doc.text"
        case .write, .edit, .patch: return "pencil"
        case .search, .glob: return "magnifyingglass"
        case .fetch: return "arrow.down.doc"
        case .web: return "globe"
        case .todo: return "checklist"
        case .agent: return "person.crop.circle"
        case .browse: return "safari"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// What an edit changed: the file, and its text before (none for a new file)
/// and after.
struct StepDiff: Codable, Equatable {
    var path: String
    var old: String?
    var new: String
}

/// One line of graff's plan.
struct TodoItem: Codable, Equatable {
    var text: String
    var done: Bool
}

enum Steps {
    /// Harness caps a diff's text and a tool's output; so does this.
    static let diffCap = 64_000

    // MARK: - typing a call (normalize.rs, typed_call)

    /// Labels some agents put in `title` before the real argument arrives:
    /// never shown as if they were one.
    private static let placeholders: Set<String> = [
        "grep", "Find", "Terminal", "Read File", "Edit File", "Delete File", "Web Search", "Web Fetch",
        "Codebase Search", "Read TODOs", "Update TODOs", "Read Lints", "Task: Subagent task",
        "Subagent task", "List MCP Resources", "Fetch MCP Resource",
    ]

    private static func argument(_ title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || placeholders.contains(t) ? nil : t
    }

    /// A command given as one markdown code span, as an exec title often is.
    private static func command(from title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("`"), t.hasSuffix("`") else { return nil }
        let inner = String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\`", with: "`")
            .trimmingCharacters(in: .whitespaces)
        return inner.isEmpty || placeholders.contains(inner) ? nil : inner
    }

    private static func firstLocation(_ update: [String: Any]) -> String? {
        ((update["locations"] as? [[String: Any]])?.first?["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The first `{type: "diff"}` in a call's content.
    static func diff(_ update: [String: Any]) -> StepDiff? {
        guard let found = (update["content"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "diff" }),
              let path = found["path"] as? String, !path.isEmpty
        else { return nil }
        return StepDiff(
            path: path,
            old: (found["oldText"] as? String).map { String($0.prefix(diffCap)) },
            new: String((found["newText"] as? String ?? "").prefix(diffCap))
        )
    }

    /// Whether an update says something about a call's shape — its kind,
    /// title, input or diff — rather than only its result. Only those
    /// re-type it: a kindless completion must not turn a Run into a Tool.
    static func reshapes(_ update: [String: Any]) -> Bool {
        update["kind"] != nil || update["title"] != nil || update["rawInput"] != nil || diff(update) != nil
    }

    static func typed(_ update: [String: Any]) -> Step {
        let kind = update["kind"] as? String ?? "other"
        let title = update["title"] as? String ?? ""
        let raw = update["rawInput"] as? [String: Any]
        func input(_ key: String) -> String? {
            (raw?[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let meta = update["_meta"] as? [String: Any]
        let graffTool = meta?["graff/toolName"] as? String

        // The browser's own tools, called through graff's MCP.
        if let tool = [title, graffTool ?? ""].first(where: { Steps.browserTool($0) != nil }).flatMap(Steps.browserTool) {
            return Step(kind: .browse, detail: tool)
        }
        // graff's background agents: the parent waiting on, messaging or
        // resuming one.
        if let control = agentControl(tool: graffTool ?? title, id: raw?["id"]) {
            return Step(kind: .other, detail: control.detail, name: control.name)
        }

        switch kind {
        case "execute":
            return Step(kind: .exec, detail: input("command") ?? command(from: title) ?? argument(title) ?? "")
        case "read":
            return Step(kind: .read, detail: input("path") ?? input("file_path") ?? input("filePath")
                ?? firstLocation(update) ?? argument(title) ?? "")
        case "edit", "delete", "move":
            if let diff = diff(update) {
                return Step(kind: diff.old == nil ? .write : .edit, detail: diff.path)
            }
            let path = input("path") ?? input("file_path") ?? input("filePath") ?? firstLocation(update)
            if let path, kind == "edit" { return Step(kind: .edit, detail: path) }
            return Step(kind: .patch, detail: path ?? "workspace")
        case "search":
            if let query = input("searchTerm") { return Step(kind: .web, detail: query) }
            let pattern = input("pattern") ?? input("globPattern") ?? input("query") ?? argument(title) ?? ""
            let path = input("path")
            return Step(kind: .search, detail: path.map { "\(pattern) in \($0)" } ?? pattern)
        case "fetch":
            if let url = input("url") { return Step(kind: .fetch, detail: url) }
            return Step(kind: .web, detail: input("searchTerm") ?? input("query") ?? argument(title) ?? "")
        default:
            if let diff = diff(update) {
                return Step(kind: diff.old == nil ? .write : .edit, detail: diff.path)
            }
            if graffTool == "subagent" || (raw?["subagent_type"] != nil && raw?["prompt"] != nil) {
                return Step(kind: .agent, detail: input("description") ?? "")
            }
            return Step(kind: .other, detail: "", name: title.isEmpty ? kind : title)
        }
    }

    /// Harness's names for graff's agent controls (normalize.rs,
    /// graff_agent_control; view.rs, agent_control).
    private static func agentControl(tool: String, id: Any?) -> (name: String, detail: String)? {
        let number: String? = {
            if let n = id as? NSNumber { return n.stringValue }
            if let s = id as? String, !s.isEmpty { return s }
            return nil
        }()
        switch tool {
        case "agent_output": return ("Waiting on", number.map { "agent \($0)" } ?? "agents")
        case "agent_message": return ("Message", number.map { "agent \($0)" } ?? "agent")
        case "subagent_resume": return ("Resume", "agent")
        case "load_tool_schemas": return ("Load", "tools")
        default: return nil
        }
    }

    /// A step for a tool kept before steps were typed: from its title alone.
    static func fallback(_ entry: Agent.Entry) -> Step {
        if let tool = browserTool(entry.text) { return Step(kind: .browse, detail: tool) }
        return typed(["kind": entry.act.isEmpty ? "other" : entry.act, "title": entry.text])
    }

    /// The browser's tools, said as what they do.
    static func browserTool(_ title: String) -> String? {
        // mcp__search__ in chats from before the app was browse.
        guard let prefix = ["mcp__browse__", "mcp__search__"].first(where: title.hasPrefix) else { return nil }
        let tool = String(title.dropFirst(prefix.count))
        return [
            "search": "Searching the web", "read_pages": "Reading pages", "open": "Opening a page",
            "read": "Reading the page", "links": "Looking at the links", "go": "Going to a page",
            "back": "Going back", "forward": "Going forward", "reload": "Reloading",
            "click": "Clicking", "type": "Typing", "submit": "Submitting a form",
            "form_fields": "Reading the form", "fill": "Filling in the form", "drive": "Filling in with Jev",
            "run_js": "Running a script on the page", "screenshot": "Looking at the page",
            "tabs": "Looking at your tabs", "show": "Showing you a page", "close": "Closing a page",
        ][tool] ?? tool
    }

    /// graff's plan, as Harness keeps it: each entry's words and whether
    /// it's done.
    static func plan(_ update: [String: Any]) -> [TodoItem] {
        (update["entries"] as? [[String: Any]] ?? []).map {
            TodoItem(text: $0["content"] as? String ?? "", done: $0["status"] as? String == "completed")
        }
    }

    // MARK: - the summary (view.rs, tool_group_summary)

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// A turn's work on one line — "Ran 2 commands · edited 1 file ·
    /// 1 failed" — with Harness's own segments, order and capitalisation,
    /// and browse's for pages read and the browser used.
    static func summary(_ work: [Agent.Entry]) -> String {
        var commands = 0, reads = 0, searches = 0, fetches = 0, todos = 0, other = 0, failed = 0
        var browsed = 0, pages = 0, thoughts = 0
        var edited: [String] = []
        for entry in work {
            switch entry.kind {
            case .thought: thoughts += 1
            case .page: pages += 1
            case .plan: todos += 1
            case .tool:
                if entry.status == "failed" { failed += 1 }
                let step = entry.step ?? fallback(entry)
                switch step.kind {
                case .exec: commands += 1
                case .write, .edit, .patch:
                    let path = step.detail.isEmpty ? "patch" : step.detail
                    if !edited.contains(path) { edited.append(path) }
                case .read: reads += 1
                case .search, .glob, .web: searches += 1
                case .fetch: fetches += 1
                case .todo: todos += 1
                case .browse: browsed += 1
                case .agent, .other: other += 1
                }
            default: break
            }
        }
        var segments: [String] = []
        switch thoughts {
        case 0: break
        case 1: segments.append("thought process")
        default: segments.append("thought \(thoughts) times")
        }
        if commands > 0 { segments.append("ran " + plural(commands, "command", "commands")) }
        if !edited.isEmpty { segments.append("edited " + plural(edited.count, "file", "files")) }
        if reads > 0 { segments.append("read " + plural(reads, "file", "files")) }
        if searches > 0 { segments.append("searched " + plural(searches, "time", "times")) }
        if fetches > 0 { segments.append("fetched " + plural(fetches, "page", "pages")) }
        if pages > 0 { segments.append("read " + plural(pages, "page", "pages")) }
        if browsed > 0 { segments.append(browsed == 1 ? "used the browser" : "used the browser \(browsed) times") }
        if todos > 0 { segments.append("updated todos") }
        if other > 0 { segments.append("called " + plural(other, "tool", "tools")) }
        if failed > 0 { segments.append("\(failed) failed") }
        let summary = segments.joined(separator: " · ")
        return summary.prefix(1).uppercased() + summary.dropFirst()
    }
}
