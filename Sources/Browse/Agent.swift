import AppKit
import Foundation

/// Isolated observable composer state so every keystroke updates only the
/// composer and send button — never invalidating `AgentColumn`, `TurnView`,
/// `MarkdownReplyView`, or `AgentHome`.
@MainActor
final class ComposerBuffer: ObservableObject {
    @Published var text: String = ""
    /// Bumped only on programmatic mutations (starters, prompt recall, slash
    /// completions, queue edit, clear) so `NanoComposerField` syncs cleanly
    /// without clobbering user typing or IME composition.
    @Published private(set) var revision: Int = 0
    /// Queued message currently being edited in place inside the composer.
    @Published var editingQueueID: Agent.Queued.ID?

    func setProgrammatic(_ value: String) {
        text = value
        revision &+= 1
    }

    func updateFromEditor(_ value: String) {
        if text != value { text = value }
    }
}

// Codegraff, working beside the page.
//
// Search doesn't carry an agent of its own; it runs the one already on the
// Mac — `graff`, Codegraff's command — and talks to it the way Zed and
// Harness do, over the Agent Client Protocol: JSON-RPC, one message a line,
// on the program's stdin and stdout. Search is the client. It opens a
// session, sends what you type (with the page you're on, unless you leave it
// out), and shows what comes back as it comes: the reply, the thinking, each
// command and edit.
//
// graff runs as `graff acp --yolo`, the way the Codegraff app runs it: every
// tool it has — the shell, reading and editing files, codedb, its MCP
// servers — and no stopping to ask before each one. Search passes words and
// a page in and shows what comes out; graff does its own talking to its
// model, with its own sign-in.
//
// What Harness learned driving graff, kept here: graff finds itself by the
// newest copy on the Mac, not the first; it reads each line into 64 KiB and
// stops listening at a longer one, so nothing sent may be longer; it owns one
// session per process, so a new conversation is a new graff; and a question
// it asks mid-turn holds the turn until it hears `session/answer`.

@MainActor
final class Agent: ObservableObject {
    enum Phase: Equatable {
        /// Not started: the column hasn't been opened since launch.
        case asleep
        case starting
        case ready
        case working
        /// graff is there but has nobody signed in.
        case signedOut
        /// No graff anywhere Search looked.
        case missing
        case broken(String)

        var words: String {
            switch self {
            case .asleep, .ready: return ""
            case .starting: return "Starting…"
            case .working: return "Working…"
            case .signedOut: return "Signed out"
            case .missing: return "Not installed"
            case .broken: return "Stopped"
            }
        }
    }

    /// One thing said or done.
    struct Entry: Identifiable, Equatable, Codable {
        /// `page`: one graff read through the browser's tools, with its
        /// address in `key`, for the user to open.
        /// `plan`: graff's to-do list, kept up to date in place (see Steps.plan).
        enum Kind: String, Codable { case you, reply, thought, tool, note, page, plan }
        var id = UUID()
        let kind: Kind
        var text: String
        /// A tool's own id, which its updates arrive under.
        var key = ""
        /// A tool's progress: pending, in_progress, completed, failed.
        var status = ""
        /// What a tool printed or changed.
        var output = ""
        /// What sort of thing a tool does, as ACP names it: read, edit,
        /// execute, fetch, search, think, other.
        var act = ""
        /// The page that went with something you said.
        var page: String?
        var passage: AgentPassage?
        /// Pasted or attached images sent with a user message.
        var images: [PastedImage]?
        /// A tool call typed as Harness types it: Run, Read, Edit… with its
        /// one line of detail (see AgentSteps.swift).
        var step: Step?
        /// What an edit changed.
        var diff: StepDiff?
        /// A plan's lines.
        var todo: [TodoItem]?
        /// When it began, and when it last changed: a reply grows, a tool
        /// finishes. How long a turn worked is read from these.
        var at = Date()
        var until = Date()
    }

    /// graff waiting on you: an answer to a question it asked in the middle
    /// of its work, or — from a graff that wasn't told to go ahead — leave to
    /// do something on the Mac.
    struct Ask: Identifiable, Equatable {
        enum Wants: Equatable {
            /// `session/request_permission`, answered by the request's own
            /// id — graff's are strings, `graff-permission-1`.
            case permission(request: String)
            /// graff's `gui_ask_user`, answered with `session/answer`.
            case question
        }
        struct Option: Identifiable, Equatable {
            let id: String
            let name: String
            let kind: String
            var allows: Bool { kind.hasPrefix("allow") }
            var refuses: Bool { kind.hasPrefix("reject") }
        }
        let id = UUID()
        let wants: Wants
        let title: String
        let detail: String?
        let options: [Option]

        var isQuestion: Bool { wants == .question }
    }

    /// An image pasted, dropped, or picked into the composer and sent as a
    /// native ACP `image` content block (`{type: "image", data, mimeType}`).
    struct PastedImage: Identifiable, Equatable, Codable {
        var id = UUID()
        let mimeType: String
        let base64: String
        let label: String
        let width: Int
        let height: Int

        static let maxAttachments = 6
        static let maxEncodedBytes = 10 * 1024 * 1024

        var acpBlock: [String: Any] {
            ["type": "image", "data": base64, "mimeType": mimeType]
        }

        var nsImage: NSImage? {
            guard let data = Data(base64Encoded: base64) else { return nil }
            return NSImage(data: data)
        }

        static func encode(_ image: NSImage, label: String = "Pasted image") -> PastedImage? {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                // Fallback via TIFF representation for vector/PDF/multi-rep images.
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let cg2 = rep.cgImage else { return nil }
                return encode(cgImage: cg2, label: label)
            }
            return encode(cgImage: cg, label: label)
        }

        private static func encode(cgImage: CGImage, label: String) -> PastedImage? {
            let maxEdge = 2048
            let srcW = cgImage.width
            let srcH = cgImage.height
            guard srcW > 0, srcH > 0 else { return nil }
            let targetCG: CGImage
            if max(srcW, srcH) > maxEdge {
                let scale = Double(maxEdge) / Double(max(srcW, srcH))
                let newW = max(1, Int((Double(srcW) * scale).rounded()))
                let newH = max(1, Int((Double(srcH) * scale).rounded()))
                let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(
                    data: nil, width: newW, height: newH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                    targetCG = ctx.makeImage() ?? cgImage
                } else {
                    targetCG = cgImage
                }
            } else {
                targetCG = cgImage
            }

            let rep = NSBitmapImageRep(cgImage: targetCG)
            let alpha = targetCG.alphaInfo
            let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
            let png = rep.representation(using: .png, properties: [:])
            let chosen: (data: Data, mime: String)?
            if let png, png.count <= 900_000 || hasAlpha {
                chosen = png.count <= maxEncodedBytes ? (png, "image/png") : nil
            } else if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
                      jpg.count <= maxEncodedBytes {
                chosen = (jpg, "image/jpeg")
            } else if let png, png.count <= maxEncodedBytes {
                chosen = (png, "image/png")
            } else {
                chosen = nil
            }
            guard let chosen else { return nil }
            return PastedImage(
                mimeType: chosen.mime,
                base64: chosen.data.base64EncodedString(),
                label: label,
                width: targetCG.width,
                height: targetCG.height
            )
        }

        static func fromFileURLs(_ urls: [URL]) -> [PastedImage] {
            let exts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp"]
            var out: [PastedImage] = []
            for url in urls where url.isFileURL {
                guard exts.contains(url.pathExtension.lowercased()),
                      let img = NSImage(contentsOf: url),
                      let encoded = encode(img, label: url.lastPathComponent)
                else { continue }
                out.append(encoded)
                if out.count >= maxAttachments { break }
            }
            return out
        }

        /// Extracts pasted images from `NSPasteboard` (screenshots, Copy Image
        /// from browsers/Meld/Figma, or copied image files from Finder).
        static func fromPasteboard(_ pb: NSPasteboard = .general) -> [PastedImage] {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                let fromFiles = fromFileURLs(urls)
                if !fromFiles.isEmpty { return fromFiles }
            }
            let imageTypes: [NSPasteboard.PasteboardType] = [
                .png,
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.heic"),
                NSPasteboard.PasteboardType("org.webmproject.webp"),
                .tiff,
            ]
            for type in imageTypes {
                if let data = pb.data(forType: type), let img = NSImage(data: data),
                   let encoded = encode(img, label: "Pasted image") {
                    return [encoded]
                }
            }
            if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
               let first = imgs.first, let encoded = encode(first, label: "Pasted image") {
                return [encoded]
            }
            return []
        }
    }

    /// Codex / ChatGPT service tier (matching NanoHarness Standard / Fast / Ultra Fast).
    enum ServiceTier: String, CaseIterable, Equatable, Identifiable {
        case standard = "default"
        case fast = "fast"
        case ultrafast = "ultrafast"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .standard: return "Standard"
            case .fast: return "Fast"
            case .ultrafast: return "Ultra Fast"
            }
        }

        var shortLabel: String {
            switch self {
            case .standard: return ""
            case .fast: return "Fast"
            case .ultrafast: return "Ultra"
            }
        }

        var hint: String {
            switch self {
            case .standard: return "Standard response speed"
            case .fast: return "Faster responses with priority tier"
            case .ultrafast: return "Maximum speed tier on supported models"
            }
        }

        var slashCommand: String {
            switch self {
            case .standard: return "/fast off"
            case .fast: return "/fast on"
            case .ultrafast: return "/fast ultrafast"
            }
        }
    }

    /// Supported ACP agent backends that `browse` can auto-discover and drive
    /// natively over stdin/stdout JSON-RPC (matching NanoHarness).
    enum Backend: String, CaseIterable, Identifiable, Codable {
        case graff
        case antigravity
        case opencode
        case gemini
        case grok
        case devin
        case hermes
        case pi

        var id: String { rawValue }

        var title: String {
            switch self {
            case .graff: return "Codegraff"
            case .antigravity: return "Antigravity"
            case .opencode: return "OpenCode"
            case .gemini: return "Gemini CLI"
            case .grok: return "Grok"
            case .devin: return "Devin"
            case .hermes: return "Hermes"
            case .pi: return "Pi"
            }
        }

        var shortName: String {
            switch self {
            case .graff: return "graff"
            case .antigravity: return "Antigravity"
            case .opencode: return "OpenCode"
            case .gemini: return "Gemini"
            case .grok: return "Grok"
            case .devin: return "Devin"
            case .hermes: return "Hermes"
            case .pi: return "Pi"
            }
        }

        var providerKey: String {
            switch self {
            case .graff: return "codegraff"
            case .antigravity: return "antigravity"
            case .opencode: return "opencode"
            case .gemini: return "google"
            case .grok: return "xai"
            case .devin: return "devin"
            case .hermes: return "hermes"
            case .pi: return "pi"
            }
        }

        var acpArguments: [String] {
            switch self {
            case .graff: return ["acp", "--yolo"]
            case .antigravity: return ["acp", "--dangerously-skip-permissions"]
            case .opencode: return ["acp"]
            case .gemini: return ["--acp"]
            case .grok: return ["--no-auto-update", "agent", "--no-leader", "stdio"]
            case .devin: return ["acp"]
            case .hermes: return ["acp"]
            case .pi: return []
            }
        }

        /// Whether this backend cleanly handles multiple sequential
        /// `session/new` calls on the same already-warm ACP process.
        var supportsMultiSession: Bool {
            self != .graff
        }
    }

    /// A model an ACP backend can reach from here (`graff/models`, ACP
    /// `configOptions[category=model]`, or `models.availableModels`).
    struct Model: Identifiable, Equatable {
        let provider: String
        let name: String
        var displayName: String? = nil
        var acpValue: String? = nil
        var context = 0
        var rawMaker: String? = nil
        var billing: String? = nil
        var effortLevels: [String] = []
        var fastSupported = false
        var ultrafastSupported = false
        var serviceTiers: [String] = []
        var id: String { "\(provider)/\(name)" }

        var supportedServiceTiers: [ServiceTier] {
            let hasFast = fastSupported || serviceTiers.contains { $0.caseInsensitiveCompare("fast") == .orderedSame || $0.caseInsensitiveCompare("priority") == .orderedSame }
            let hasUltra = ultrafastSupported || serviceTiers.contains { $0.caseInsensitiveCompare("ultrafast") == .orderedSame }
            guard hasFast || hasUltra else { return [] }
            return hasUltra ? [.standard, .fast, .ultrafast] : [.standard, .fast]
        }

        static func == (a: Model, b: Model) -> Bool { a.id == b.id }

        /// The model's own part of its name: after any "vendor/", without a
        /// ":free" or ":beta" on the end.
        private var bare: String {
            var bare = name
            if let slash = bare.lastIndex(of: "/") { bare = String(bare[bare.index(after: slash)...]) }
            if let colon = bare.firstIndex(of: ":") { bare = String(bare[..<colon]) }
            return bare
        }

        /// What follows a colon — OpenRouter's "free", "beta", "extended".
        var tag: String? {
            name.split(separator: ":").dropFirst().first.map(String.init)
        }

        /// Canonical maker key (1:1 with NanoHarness `model_picker.zig:maker`),
        /// used for the row's logo and the reasoning slider's brand accent.
        var makerKey: String {
            if let rawMaker, !rawMaker.isEmpty { return rawMaker.lowercased() }
            let clean = bare.lowercased()
            let prefixes: [(String, String)] = [
                ("claude", "anthropic"), ("gpt", "openai"), ("codex", "openai"),
                ("o1", "openai"), ("o3", "openai"), ("o4", "openai"),
                ("grok", "xai"), ("gemini", "google"), ("gemma", "google"),
                ("deepseek", "deepseek"), ("mimo", "xiaomi"),
                ("kimi", "moonshot"), ("k2", "moonshot"), ("k3", "moonshot"),
                ("glm", "zai"), ("qwen", "alibaba"), ("minimax", "minimax"),
                ("mistral", "mistral"), ("codestral", "mistral"), ("devstral", "mistral"),
                ("muse-spark", "meta"), ("llama", "meta"),
            ]
            for (prefix, lab) in prefixes where clean.hasPrefix(prefix) { return lab }
            if let slash = name.firstIndex(of: "/") {
                let vendor = String(name[..<slash]).lowercased()
                if !vendor.isEmpty { return vendor }
            }
            let p = provider.lowercased()
            if p == "codex" || p == "chatgpt-new" { return "openai" }
            if p == "claude-agent" { return "anthropic" }
            if p == "kimi" || p == "moonshot" { return "moonshot" }
            return p
        }

        /// Whose model it is, when a router carries it: "anthropic/…" is
        /// Anthropic's.
        var maker: String? {
            guard let slash = name.firstIndex(of: "/") else { return nil }
            return Model.said(String(name[..<slash]))
        }

        /// Subscription (`plan` / `plan*`) lead, then `local`, then `credits`/unknown,
        /// then `api` — 1:1 with NanoHarness `model_picker.zig:billingRank`.
        var billingRank: Int {
            switch billing {
            case "plan", "plan*": return 0
            case "local": return 1
            case "api": return 3
            default: return 2
            }
        }

        /// Billing tag in words (`model_picker.zig:billingLabel`).
        var billingLabel: String? {
            switch billing {
            case "plan": return "Your plan"
            case "plan*": return "Your plan · separate limit"
            case "credits": return "Credits"
            case "api": return "API usage"
            case "local": return "Runs locally"
            case let other?: return other
            case nil: return nil
            }
        }

        /// Whether this model uses a binary Off/On reasoning switch.
        var binaryEffort: Bool {
            effortLevels.count == 2 && effortLevels.contains("none") && effortLevels.contains("high")
        }

        /// Human-readable reasoning range ("Low – Ultra") from the catalog.
        var reasoningRange: String? {
            guard let first = effortLevels.first, let last = effortLevels.last else { return nil }
            let a = Model.reasoningLabel(first, binary: binaryEffort)
            let b = Model.reasoningLabel(last, binary: binaryEffort)
            return a == b ? a : "\(a) – \(b)"
        }

        static func reasoningLabel(_ level: String, binary: Bool = false) -> String {
            let low = level.lowercased()
            if binary && low == "high" { return "On" }
            switch low {
            case "none", "off": return "Off"
            case "minimal": return "Minimal"
            case "low": return "Low"
            case "medium": return "Medium"
            case "high": return "High"
            case "xhigh": return "XHigh"
            case "max": return "Max"
            case "ultra": return "Ultra"
            case "ultracode": return "Ultracode"
            case "ultrathink": return "Ultrathink"
            default: return level.prefix(1).uppercased() + level.dropFirst()
            }
        }

        /// Search ranking 1:1 with NanoHarness `model_picker.zig:searchRank`:
        /// 0 = prefix on label/name, 1 = substring on label/name, 2 = match on
        /// full `provider/name` id, route display name, or maker. Nil = no match.
        func searchRank(for rawQuery: String) -> Int? {
            let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return 0 }
            let labelLow = label.lowercased()
            let nameLow = name.lowercased()
            if labelLow.hasPrefix(trimmed) || nameLow.hasPrefix(trimmed) { return 0 }
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.allSatisfy({ labelLow.contains($0) || nameLow.contains($0) }) { return 1 }
            let hay = "\(id) \(Model.said(provider)) \(maker ?? "") \(makerKey)".lowercased()
            if words.allSatisfy({ hay.contains($0) }) { return 2 }
            return nil
        }

        /// "gpt-6-sol" as people say it: "GPT-6 Sol"; "claude-opus-4-8" is
        /// "Claude Opus 4.8", and a date on the end is left off.
        var label: String {
            if let displayName, !displayName.isEmpty { return displayName }
            var words: [String] = []
            var dated = false
            for part in bare.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init) {
                let lower = part.lowercased()
                // 20251101, or 2024-05-13: a snapshot's date, not part of
                // what it's called.
                if part.count == 8, part.allSatisfy(\.isNumber) { continue }
                if part.count == 4, part.hasPrefix("20"), part.allSatisfy(\.isNumber) { dated = true; continue }
                if dated, part.count <= 2, part.allSatisfy(\.isNumber) { continue }
                dated = false
                if let cased = Model.cased[lower] {
                    words.append(cased)
                    continue
                }
                if let last = words.last {
                    // 4-8 → 4.8; GPT 6 → GPT-6.
                    if part.allSatisfy(\.isNumber), part.count <= 2, last.last?.isNumber == true, !last.hasSuffix("B") {
                        words[words.count - 1] = last + "." + part
                        continue
                    }
                    if last == "GPT", part.first?.isNumber == true {
                        words[words.count - 1] = "GPT-" + part
                        continue
                    }
                }
                if ["gpt", "glm", "ui", "ai", "oss", "vl", "moe", "r1", "v3", "v4", "k2", "k3", "4o"].contains(lower) {
                    words.append(part.uppercased())
                } else if lower.range(of: #"^a?\d+(\.\d+)?[bkm]$"#, options: .regularExpression) != nil {
                    // 72b → 72B, the size of the thing; a10b → A10B.
                    words.append(part.uppercased())
                } else if lower.range(of: #"^o\d$"#, options: .regularExpression) != nil {
                    // OpenAI's o1, o3, o4 are written small.
                    words.append(lower)
                } else {
                    words.append(part.prefix(1).uppercased() + part.dropFirst())
                }
            }
            return words.isEmpty ? name : words.joined(separator: " ")
        }

        /// Words their makers write their own way.
        private static let cased = [
            "deepseek": "DeepSeek", "minimax": "MiniMax", "lmstudio": "LM Studio", "hy4": "HY4",
            "openai": "OpenAI", "chatgpt": "ChatGPT", "gemma": "Gemma", "phi": "Phi",
        ]

        /// Its window in words a person reads at a glance: "1M", "1.05M", "270k"
        /// (1:1 with NanoHarness `model_picker.zig:contextLabel`).
        var window: String? {
            guard context > 0 else { return nil }
            if context >= 1024, (context & (context - 1)) == 0 {
                return context >= (1 << 20) ? "\(context >> 20)M" : "\(context >> 10)k"
            }
            if context < 1_000 { return "\(context)" }
            let thousands = (context + 500) / 1_000
            if thousands < 1_000 { return "\(thousands)k" }
            let hundredths = (context + 5_000) / 10_000
            let whole = hundredths / 100
            let frac = hundredths % 100
            if frac == 0 { return "\(whole)M" }
            if frac % 10 == 0 { return "\(whole).\(frac / 10)M" }
            return String(format: "%d.%02dM", whole, frac)
        }

        /// Only for making pictures and sounds, or for batch jobs: nothing to
        /// talk to.
        var talks: Bool {
            let lower = name.lowercased()
            return !["imagine", "-image", "image-", "video", "lyria", "embedding", "embed-", "tts", "whisper", "transcribe", ":batch"]
                .contains { lower.contains($0) }
        }

        /// A provider or maker by the name it goes by (1:1 with NanoHarness
        /// `model_picker.zig:providerInfo`).
        static func said(_ key: String) -> String {
            let known = [
                "codegraff": "Codegraff",
                "antigravity": "Antigravity",
                "opencode": "OpenCode",
                "devin": "Devin",
                "hermes": "Hermes",
                "pi": "Pi",
                "claude-agent": "Claude Agent",
                "codex": "Codex / ChatGPT",
                "chatgpt-new": "ChatGPT plan",
                "openai": "OpenAI",
                "anthropic": "Anthropic",
                "xai": "xAI", "x-ai": "xAI",
                "kimi": "Kimi", "moonshot": "Moonshot", "moonshotai": "Moonshot",
                "deepseek": "DeepSeek",
                "openrouter": "OpenRouter",
                "google": "Google",
                "meta-llama": "Meta", "meta": "Meta",
                "mistralai": "Mistral", "mistral": "Mistral",
                "qwen": "Qwen", "alibaba": "Qwen",
                "z-ai": "Z.ai", "zai": "Z.ai",
                "cerebras": "Cerebras",
                "groq": "Groq",
                "kilo": "Kilo Gateway",
                "vercel": "Vercel AI Gateway",
                "fireworks": "Fireworks",
                "mlx": "MLX", "lmstudio": "LM Studio", "omlx": "oMLX",
                "fugu": "Sakana",
                "xiaomi": "Xiaomi",
                "nvidia": "NVIDIA", "microsoft": "Microsoft",
                "amazon": "Amazon", "cohere": "Cohere",
                "minimax": "MiniMax", "baidu": "Baidu",
                "bytedance": "ByteDance", "ibm-granite": "IBM", "perplexity": "Perplexity",
            ]
            if let name = known[key.lowercased()] { return name }
            return key.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// How hard it thinks: graff's `thought_level`, a session config option
    /// with the levels the model on offer takes.
    struct Effort: Equatable {
        let id: String
        var current: String
        var levels: [(value: String, name: String)]

        static func == (a: Effort, b: Effort) -> Bool {
            a.id == b.id && a.current == b.current && a.levels.map(\.value) == b.levels.map(\.value)
        }

        var currentName: String {
            levels.first { $0.value == current }?.name ?? current.capitalized
        }
    }

    @Published private(set) var phase: Phase = .asleep
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var asking: Ask?
    @Published private(set) var models: [Model] = []
    /// The model graff says it is running.
    @Published private(set) var model: Model?
    @Published private(set) var effort: Effort?
    /// Active Codex / ChatGPT service tier (Standard / Fast / Ultra Fast).
    @Published private(set) var serviceTier: ServiceTier = .standard
    private var pendingServiceTier: ServiceTier?
    private var applyingServiceTier = false
    /// Suppresses visible transcript chunks while a live control slash command
    /// (`/fast` or `/model`) executes in-session.
    private var suppressingControlOutput = false
    /// Isolated typing buffer observed only by the composer and Write view.
    let composer = ComposerBuffer()
    /// Flips only when draft transitions between empty and non-empty so views
    /// like the header's New Chat button stay accurate without per-keystroke redraws.
    @Published private(set) var hasDraft = false
    /// NanoHarness full-page distraction-free Write editor (`⌘⇧E`).
    @Published var writeMode = false
    /// Unsent draft text, backed by `composer` so keystrokes never trigger
    /// full-transcript SwiftUI invalidations.
    var draft: String {
        get { composer.text }
        set {
            composer.setProgrammatic(newValue)
            let nonEmpty = !newValue.isEmpty
            if hasDraft != nonEmpty { hasDraft = nonEmpty }
        }
    }
    /// Called by the native AppKit editor on every keystroke.
    func syncDraftFromEditor(_ text: String) {
        composer.updateFromEditor(text)
        let nonEmpty = !text.isEmpty
        if hasDraft != nonEmpty { hasDraft = nonEmpty }
    }
    @Published var passage: AgentPassage?
    lazy var tasks = AgentTasks()
    lazy var browserChat = AgentBrowserChat(agent: self, prefs: prefs)
    /// Unsent words and excerpts stay in memory, including on private tabs.
    /// They are never added to history or written to a draft file.
    private struct Draft {
        var text: String
        var passage: AgentPassage?
        var withPage: Bool
    }
    private var drafts: [UUID: Draft] = [:]
    private var generalDraft = Draft(text: "", withPage: true)
    private var draftTab: UUID?
    private var separatesDrafts = false
    /// A stopped conversation must not be revived by a page read or a
    /// graff lookup that finishes after shutdown (or a later restart).
    private var generation = UUID()
    enum Outcome: Equatable { case finished, stopped, interrupted(String) }
    @Published private(set) var outcome: Outcome?
    /// Whether the page you are on goes with the next message.
    @Published var withPage = true

    /// Where to get graff, for a Mac without it.
    static let download = URL(string: "https://github.com/justrach/codegraff/releases/latest")!

    /// graff takes a line at a time into 64 KiB; anything longer and it stops
    /// listening. Kept well under, for the envelope around what is sent.
    private static let longestLine = 60_000

    private let prefs: Preferences
    @Published private(set) var backend: Backend = .graff
    @Published private(set) var availableBackends: [Backend] = [.graff]
    private var modelConfigID: String?
    private var pipe: AcpPipe?
    private var program: URL?
    private var session: String?
    /// A session to pick up again when graff comes back — after a change
    /// of model, the conversation carries on rather than starting over.
    private var resuming: String?
    /// True while `session/load` replays what was said, which the column
    /// already shows.
    private var replaying = false
    private var next = 1
    private var waiting: [Int: (Result<Any, Failure>) -> Void] = [:]
    /// Requests from graff that are still to be answered, by id, with the
    /// id as it came so the answer carries it back the same.
    private var owed: [String: Any] = [:]
    /// What was typed while graff was still starting, sent once it is up.
    private var held: [[String: Any]]?
    /// True from a prompt going out until its answer comes back.
    private var prompting = false
    /// Whether this session has been told where it is. Once is enough.
    private var introduced = false

    /// Every conversation so far, for the Ask tab's page (see Chats.swift).
    let chats = Chats()
    /// The one on screen, once something has been said in it.
    @Published private(set) var chatID: UUID?
    /// How much of the model's context the conversation fills, as graff's
    /// `usage_update` says: tokens used, and the window.
    @Published private(set) var context: (used: Int, window: Int)?
    /// What graff calls the conversation (`session_info_update`), for its
    /// title where nobody has named it.
    @Published private(set) var named: String?
    /// The slash commands graff offers (`available_commands_update`).
    @Published private(set) var commands: [String] = []
    /// Last moment a streaming update arrived during an active turn (for NanoHarness quiet banner).
    @Published private(set) var lastStreamAt = Date()
    /// Saved draft text while editing a queued row in place inside the composer.
    private var savedDraftBeforeQueueEdit: String?
    /// Pending coalesced streaming reply/thought pieces flushed at ~60 Hz so
    /// high-throughput streaming never starves 120 FPS scrolling or typing.
    private var pendingFlow: (kind: Entry.Kind, text: String)?
    private var flowFlushTask: Task<Void, Never>?

    /// A message typed while graff was working: it waits its turn, and goes
    /// once the turn before it ends — Harness's queue (crates/ui/src/
    /// queue.rs), docked above the composer.
    struct Queued: Identifiable {
        let id = UUID()
        var text: String
        /// The tab to send along, read when the message goes, not now.
        var tab: Tab?
        var passage: AgentPassage?
        var mentioned: [Tab] = []
        var history: [HistoryMention] = []
        var images: [PastedImage] = []
    }
    @Published private(set) var queue: [Queued] = []

    /// Images pasted, dropped, or picked into the composer for the next prompt.
    @Published private(set) var pendingImages: [PastedImage] = []

    func attachImages(_ images: [PastedImage]) {
        guard !images.isEmpty else { return }
        let room = max(0, PastedImage.maxAttachments - pendingImages.count)
        guard room > 0 else { return }
        pendingImages.append(contentsOf: images.prefix(room))
        if !hasDraft { hasDraft = true }
    }

    func removeImage(_ id: PastedImage.ID) {
        pendingImages.removeAll { $0.id == id }
        let nonEmpty = !composer.text.isEmpty || !pendingImages.isEmpty
        if hasDraft != nonEmpty { hasDraft = nonEmpty }
    }

    func clearImages() {
        if !pendingImages.isEmpty { pendingImages.removeAll() }
    }

    /// A recently visited history item explicitly `@`-mentioned in the composer
    /// (Dia-style `@history` context). Sent with the next prompt and cleared on send.
    struct HistoryMention: Identifiable, Equatable {
        let id: String
        let title: String
        let url: URL

        var host: String {
            let h = url.host() ?? ""
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
    }

    @Published private(set) var mentionedHistory: [HistoryMention] = []

    func mentionHistory(title: String, url: URL) {
        let key = url.absoluteString
        guard !mentionedHistory.contains(where: { $0.id == key }) else { return }
        mentionedHistory.append(HistoryMention(id: key, title: title.isEmpty ? (url.host() ?? key) : title, url: url))
    }

    func unmentionHistory(_ id: String) {
        mentionedHistory.removeAll { $0.id == id }
    }

    func clearMentionedHistory() {
        if !mentionedHistory.isEmpty { mentionedHistory.removeAll() }
    }

    /// Additional open tabs explicitly `@`-mentioned in the composer (Dia-style
    /// multi-tab context). Sent alongside the next prompt and cleared on send.
    @Published private(set) var mentionedTabs: [Tab] = []

    func mentionTab(_ tab: Tab) {
        guard !tab.isBlank, !mentionedTabs.contains(where: { $0.id == tab.id }) else { return }
        mentionedTabs.append(tab)
    }

    func unmentionTab(_ id: Tab.ID) {
        mentionedTabs.removeAll { $0.id == id }
    }

    func clearMentionedTabs() {
        if !mentionedTabs.isEmpty { mentionedTabs.removeAll() }
    }

    /// The tab this conversation is about, and the only one it works in:
    /// every message carries it, graff is told to stay in it, and the
    /// browser's tools act on it when graff names no other page
    /// (AgentTools.on). A form to fill in, a page to work through — an
    /// agent on that tab alone.
    @Published private(set) var pinned: Tab?

    func pin(_ tab: Tab?) {
        pinned = tab
        if separatesDrafts, let tab { draftTab = tab.id }
        if tab == nil { moveDraft(to: AgentTools.shared.browser?.active) }
    }

    /// Starters and saved tasks leave any words already typed intact.
    func prepareDraft(_ text: String) {
        guard asking?.isQuestion != true else { return }
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n\n" + text
    }

    func separateDrafts(_ on: Bool, page: Tab?) {
        separatesDrafts = on
        drafts = [:]
        generalDraft = Draft(text: "", withPage: true)
        draftTab = (pinned ?? page)?.id
    }

    func moveDraft(to tab: Tab?) {
        guard separatesDrafts, pinned == nil, asking?.isQuestion != true, draftTab != tab?.id else { return }
        let before = Draft(text: draft, passage: passage, withPage: withPage)
        if let draftTab { drafts[draftTab] = before } else { generalDraft = before }
        let next = tab.flatMap { drafts[$0.id] } ?? (tab == nil ? generalDraft : Draft(text: "", withPage: true))
        draftTab = tab?.id
        draft = next.text
        passage = next.passage
        withPage = next.withPage
    }

    func forgetDraft(_ id: UUID) {
        if pinned?.id == id { pin(nil) }
        unmentionTab(id)
        drafts[id] = nil
    }
    /// Stopped by hand or reconnected: the queue waits for the next thing sent
    /// or an explicit resume — a stop means stop.
    @Published private(set) var queueHeld = false
    /// Why the last turn went wrong, for its card; nothing once one works.
    private var stumble: String?
    /// What was said before, for a graff that couldn't pick the session
    /// back up: it goes ahead of the next message instead.
    private var lost: String?
    /// When graff last did something or was asked something.
    private var lastActive = Date()
    private var idleWatch: Task<Void, Never>?
    /// graff and its pages hold ~40 MB and more for as long as it runs. With
    /// nothing to do for this long it goes, and the next message brings the
    /// same conversation back with `session/load`.
    private static let idleLimit: TimeInterval = 20 * 60

    init(prefs: Preferences) {
        self.prefs = prefs
        self.backend = Backend(rawValue: prefs.agentBackend) ?? .graff
        // Hydrate cached model catalog in <1 ms so the model picker is never empty.
        hydrateCachedCatalog(for: self.backend)
        // graff saves its session when its input ends, and ends with it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keep()
                self?.chats.flush()
                self?.pipe?.stop()
                AgentEngine.shared.shutdownAll()
                // The port dies with the app; nothing should be told of it.
                AgentTools.withdraw()
            }
        }
        refreshBackends()
        // Pre-warm the active backend in the background right after launch so
        // opening the Agent sidebar has zero warm time.
        if prefs.usesAgent && !Store.testing {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.prefs.usesAgent, self.pipe == nil, self.phase == .asleep else { return }
                AgentEngine.shared.prewarm(backend: self.backend, prefs: self.prefs)
            }
        }
    }

    private func hydrateCachedCatalog(for target: Backend) {
        guard let cached = AgentEngine.shared.cachedCatalog(for: target) else { return }
        let savedID = prefs.agentModel(for: target.rawValue)
        var list = cached.models
        let chosen = (!savedID.isEmpty ? list.first(where: { $0.id == savedID || $0.acpValue == savedID }) : nil)
            ?? cached.current
            ?? list.first
        if let chosen {
            list.removeAll { $0 == chosen }
            list.insert(chosen, at: 0)
        }
        self.models = list
        self.model = chosen
        self.effort = cached.effort
        self.modelConfigID = cached.modelConfigID
    }

    func refreshBackends() {
        let custom = prefs.agentPath
        Task {
            let found = await AgentEngine.shared.discoverAll(customGraff: custom)
            if !found.isEmpty {
                self.availableBackends = found
            }
        }
    }

    /// Quietly pre-warms the top secondary installed backend(s) when the user
    /// opens the Model Picker so clicking another agent pill is 0 ms instant.
    func prewarmSecondaryBackends() {
        guard prefs.usesAgent, !Store.testing else { return }
        let others = availableBackends.filter { $0 != backend }
        // Prioritize Antigravity and Codegraff first since they're the primary daily drivers.
        let ordered = others.sorted { a, b in
            let rank: (Backend) -> Int = {
                switch $0 {
                case .antigravity: return 0
                case .graff: return 1
                case .opencode: return 2
                case .grok: return 3
                default: return 4
                }
            }
            return rank(a) < rank(b)
        }
        for candidate in ordered.prefix(2) {
            AgentEngine.shared.prewarm(backend: candidate, prefs: prefs)
        }
    }

    /// Parks the currently active idle worker into `AgentEngine`'s warm pool
    /// instead of killing it, so switching back to it takes 0 ms.
    private func parkCurrentWorker() {
        flushFlow()
        generation = UUID()
        replaying = false
        asking = nil
        owed = [:]
        held = nil
        fail(Failure(code: -1, message: "Switched backend"))

        guard let livePipe = pipe, livePipe.isRunning, let liveSession = session, !prompting, phase == .ready else {
            let dying = pipe
            pipe = nil
            dying?.stop()
            session = nil
            prompting = false
            phase = .asleep
            return
        }
        let worker = AgentEngine.WarmWorker(backend: backend, pipe: livePipe, program: program ?? URL(fileURLWithPath: "/usr/bin/env"))
        worker.session = liveSession
        worker.models = models
        worker.model = model
        worker.effort = effort
        worker.modelConfigID = modelConfigID
        worker.serviceTier = serviceTier
        worker.commands = commands
        worker.nextID = next
        worker.ready = true
        worker.lastUsed = Date()

        // Detach before parking so the pool owns this pipe cleanly.
        pipe = nil
        session = nil
        prompting = false
        phase = .asleep
        AgentEngine.shared.park(worker)
    }

    /// Attaches an already-warm worker from `AgentEngine` in 0 ms!
    private func attach(warm worker: AgentEngine.WarmWorker) {
        self.program = worker.program
        self.pipe = worker.pipe
        self.session = worker.session
        self.next = max(self.next, worker.nextID)
        self.serviceTier = worker.serviceTier
        self.commands = worker.commands
        self.modelConfigID = worker.modelConfigID
        if !worker.models.isEmpty { self.models = worker.models }
        if let m = worker.model { self.model = m }
        if let e = worker.effort { self.effort = e }
        self.phase = .ready
        self.lastActive = Date()
        self.introduced = false
        watchIdle()

        let livePipe = worker.pipe
        livePipe.onMessage = { [weak self, weak livePipe] message in
            guard let self, let livePipe, self.pipe === livePipe else { return }
            self.take(message)
        }
        livePipe.onExit = { [weak self, weak livePipe] status, said in
            guard let self, let livePipe, self.pipe === livePipe else { return }
            self.ended(status: status, said: said)
        }

        // Apply remembered model/effort if they drifted while parked.
        let savedModel = prefs.agentModel(for: backend.rawValue)
        if !savedModel.isEmpty,
           let match = models.first(where: { $0.id == savedModel || $0.acpValue == savedModel }),
           match != self.model {
            choose(match)
        }
        let wantedEffort = prefs.agentEffort
        if let effort, !wantedEffort.isEmpty, wantedEffort != effort.current,
           effort.levels.contains(where: { $0.value == wantedEffort }) {
            choose(effort: wantedEffort)
        }
        if backend == .graff && models.isEmpty {
            listModels()
        }
        if let blocks = held {
            held = nil
            prompt(blocks)
        }
    }

    /// Switch the active ACP agent backend (e.g. Codegraff → Antigravity →
    /// OpenCode → Gemini CLI → Grok → Devin), parking the old warm worker so
    /// switching back is 0 ms instant and carrying over visible context.
    func choose(backend next: Backend) {
        guard next != backend else { return }
        prefs.agentBackend = next.rawValue
        keep()
        parkCurrentWorker()
        backend = next
        model = nil
        models = []
        effort = nil
        modelConfigID = nil
        serviceTier = .standard
        pendingServiceTier = nil
        resuming = nil
        lost = entries.contains(where: { $0.kind == .you }) ? Agent.transcript(entries) : nil
        if !entries.isEmpty {
            entries.append(Entry(kind: .note, text: "Switched to \(next.title)"))
        }
        // Populate model picker in <1 ms from persistent catalog cache.
        hydrateCachedCatalog(for: next)
        start()
    }

    struct Failure: Error {
        let code: Int
        let message: String
    }

    var canSend: Bool {
        guard prefs.usesAgent else { return false }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty else { return false }
        if asking?.isQuestion == true { return true }
        switch phase {
        case .ready, .asleep, .working: return true
        // One message can wait for graff to be up, not a queue of them.
        case .starting: return held == nil
        default: return false
        }
    }

    // MARK: - starting and stopping

    /// Browser access is tied to one conversation, even before its first turn.
    func identifyConversation() -> UUID {
        if let chatID { return chatID }
        let id = UUID()
        chatID = id
        return id
    }

    /// A second composer must never consume the draft or excerpt on this Mac.
    /// Pages are only attached from the native composer; browser tools remain
    /// available when the remote message explicitly asks to use them.
    func sendFromBrowser(_ text: String) -> Bool {
        guard prefs.usesAgent, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count < 40_000 else { return false }
        switch phase {
        case .ready, .asleep, .working: break
        default: return false
        }
        if let asking {
            guard asking.isQuestion else { return false }
            entries.append(Entry(kind: .you, text: text))
            respond(asking, text: text, preserveDraft: true)
        } else if phase == .working || prompting {
            guard queue.count < 8 else { return false }
            queue.append(Queued(text: text, tab: nil, passage: nil))
        } else {
            queueHeld = false
            submit(text, page: nil)
        }
        return true
    }

    /// The column opened: start graff if it isn't already.
    func wake() {
        guard prefs.usesAgent else { return }
        lastActive = Date()
        if phase == .asleep { start() }
    }

    /// graff stopped after a long quiet, to give back what it holds: the
    /// conversation stays on screen and its session is picked up again
    /// with the next message (see idleLimit).
    func rest() {
        guard pipe != nil, phase == .ready, asking == nil, !prompting else { return }
        let carried = session
        keep()
        shutDown()
        resuming = carried
        AgentTools.shared.dropPages()
    }

    /// Checks once a minute, while graff runs, whether it has been quiet
    /// for idleLimit.
    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, self.pipe != nil else { return }
                if Date().timeIntervalSince(self.lastActive) > Agent.idleLimit {
                    self.rest()
                    return
                }
            }
        }
    }

    /// graff afresh: after signing in, after it stopped, after the path to
    /// it changed.
    func restart() {
        shutDown()
        start()
    }

    /// Recovery is not a new conversation. Carry the session across the
    /// new process, with the visible transcript as fallback if it was lost.
    /// Nothing queued is replayed until the person sends another message.
    func reconnect() {
        let carried = session ?? chats.all.first(where: { $0.id == chatID })?.session
        keep()
        queueHeld = true
        shutDown()
        settle(false)
        resuming = carried
        lost = carried == nil ? Agent.transcript(entries) : nil
        stumble = nil
        outcome = .stopped
        start()
    }

    /// Turned off in Settings, or about to be started afresh.
    func shutDown() {
        flushFlow()
        generation = UUID()
        let dying = pipe
        pipe = nil
        dying?.stop()
        session = nil
        replaying = false
        prompting = false
        fail(Failure(code: -1, message: "Stopped"))
        asking = nil
        owed = [:]
        held = nil
        phase = .asleep
    }

    /// A clean slate. Multi-session ACP backends (Antigravity, OpenCode,
    /// Gemini, Grok, Devin, Hermes, Pi) open a fresh `session/new` over the
    /// already-warm pipe (~10 ms vs ~1.4 s cold start); `graff` starts fresh
    /// using cached binary/PATH resolution.
    func startOver() {
        keep()
        AgentTools.shared.dropPages()
        entries = []
        chatID = nil
        pinned = nil
        passage = nil
        clearMentionedTabs()
        clearMentionedHistory()
        clearImages()
        outcome = nil
        queue = []
        queueHeld = false
        composer.editingQueueID = nil
        savedDraftBeforeQueueEdit = nil
        writeMode = false
        named = nil
        context = nil
        stumble = nil
        lost = nil
        resuming = nil
        if backend.supportsMultiSession, let livePipe = pipe, livePipe.isRunning, !prompting, phase == .ready {
            // Keep the warm process alive and just open a fresh session!
            flushFlow()
            asking = nil
            owed = [:]
            session = nil
            introduced = false
            phase = .starting
            open()
        } else {
            restart()
        }
        moveDraft(to: AgentTools.shared.browser?.active)
    }

    /// A conversation from before, back on screen, and graff picking it up
    /// where it was left: its session loaded again, or — if graff has lost
    /// it — what was said, sent ahead of the next message.
    func resume(_ chat: Chat) {
        guard chat.id != chatID else { return }
        keep()
        AgentTools.shared.dropPages()
        shutDown()
        entries = chat.entries
        chatID = chat.id
        pinned = nil
        passage = nil
        outcome = chat.failed.map(Outcome.interrupted)
        queue = []
        queueHeld = false
        composer.editingQueueID = nil
        savedDraftBeforeQueueEdit = nil
        writeMode = false
        named = nil
        context = nil
        stumble = nil
        lost = chat.session == nil ? Agent.transcript(chat.entries) : nil
        resuming = chat.session
        start()
        moveDraft(to: AgentTools.shared.browser?.active)
    }

    /// The conversation on screen, saved with the others.
    func keep() {
        guard let chatID, entries.contains(where: { $0.kind == .you }) else { return }
        let before = chats.all.first { $0.id == chatID }
        // Only when something changed: leaving a chat as it was mustn't
        // make it the newest.
        if let before, before.entries == entries, before.failed == stumble,
           session == nil || before.session == session { return }
        chats.keep(Chat(
            id: chatID,
            session: session ?? before?.session,
            // A name somebody gave it outlasts what's said after.
            title: before?.named == true ? before?.title ?? "" : named ?? before?.title ?? Chat.title(for: entries),
            started: before?.started ?? entries.first?.at ?? Date(),
            updated: Date(),
            entries: entries,
            failed: stumble,
            named: before?.named,
            pinned: before?.pinned
        ))
    }

    /// What the conversation on screen is called: the name somebody gave
    /// it, or the first thing asked.
    var title: String {
        if let chatID, let saved = chats.all.first(where: { $0.id == chatID }), saved.named == true { return saved.title }
        return named ?? Chat.title(for: entries)
    }

    /// One taken off the list; the one on screen goes back to a clean slate.
    func forget(_ chat: Chat) {
        chats.remove(chat.id)
        if chat.id == chatID {
            chatID = nil
            startOver()
        }
    }

    /// Another model. graff takes it at launch, so graff starts again — and
    /// picks the conversation up where it was.
    /// The models chosen last, newest first, for the top of the picker.
    var recentModels: [Model] {
        (Store.settings.stringArray(forKey: "agent.recent") ?? []).compactMap { id in
            models.first { $0.id == id }
        }
    }

    func choose(_ model: Model, effort wantedEffort: String? = nil) {
        if let wantedEffort {
            prefs.agentEffort = wantedEffort
            if model == self.model {
                choose(effort: wantedEffort)
                return
            }
        }
        guard model != self.model else { return }
        var recent = Store.settings.stringArray(forKey: "agent.recent") ?? []
        if let leaving = self.model?.id { recent.removeAll { $0 == leaving }; recent.insert(leaving, at: 0) }
        recent.removeAll { $0 == model.id }
        recent.insert(model.id, at: 0)
        Store.settings.set(Array(recent.prefix(6)), forKey: "agent.recent")
        prefs.setAgentModel(model.id, for: backend.rawValue)

        // Standard ACP backends (Antigravity, OpenCode, Gemini CLI, Grok,
        // Devin, Hermes, Pi) switch models live in-session without restarting.
        if backend != .graff, let session {
            let previous = self.model
            self.model = model
            var reordered = self.models
            reordered.removeAll { $0 == model }
            reordered.insert(model, at: 0)
            self.models = reordered
            let wire = model.acpValue ?? model.name
            let finish: (Result<Any, Failure>) -> Void = { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let reply):
                    self.adopt(reply)
                    if let wantedEffort { self.choose(effort: wantedEffort) }
                case .failure(let failure):
                    self.model = previous
                    self.entries.append(Entry(kind: .note, text: failure.message))
                }
            }
            if let configId = modelConfigID {
                call("session/set_config_option", ["sessionId": session, "configId": configId, "value": wire], then: finish)
            } else {
                call("session/set_model", ["sessionId": session, "modelId": wire], then: finish)
            }
            return
        }

        // Codegraff live in-session `/model` switch (~6 ms vs ~2.2 s cold
        // restart!) when idle and connected. Falls back to restart if busy.
        if backend == .graff, let session, !prompting, phase == .ready {
            let previous = self.model
            self.model = model
            var reordered = self.models
            reordered.removeAll { $0 == model }
            reordered.insert(model, at: 0)
            self.models = reordered
            suppressingControlOutput = true
            let cmd = "/model \(model.provider)/\(model.name)"
            call("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": cmd]]]) { [weak self] result in
                guard let self else { return }
                self.suppressingControlOutput = false
                switch result {
                case .success:
                    if !self.entries.isEmpty {
                        self.entries.append(Entry(kind: .note, text: "Now \(model.label)"))
                    }
                    self.listModels()
                    if let wantedEffort { self.choose(effort: wantedEffort) }
                case .failure:
                    // Fallback to full restart if this graff build doesn't accept `/model`.
                    self.model = previous
                    let carried = self.session
                    self.shutDown()
                    self.resuming = carried
                    self.entries.append(Entry(kind: .note, text: "Now \(model.label)"))
                    self.start()
                }
            }
            return
        }

        let carried = session
        shutDown()
        resuming = carried
        entries.append(Entry(kind: .note, text: "Now \(model.label)"))
        start()
    }

    /// Starred model ids, persisted across launches (1:1 with NanoHarness favorites).
    var favoriteModelIDs: Set<String> {
        Set(Store.settings.stringArray(forKey: "agent.favorites") ?? [])
    }

    var preferredEffort: String { prefs.agentEffort }

    func toggleFavorite(_ model: Model) {
        var list = Store.settings.stringArray(forKey: "agent.favorites") ?? []
        if let idx = list.firstIndex(of: model.id) {
            list.remove(at: idx)
        } else {
            list.insert(model.id, at: 0)
        }
        Store.settings.set(list, forKey: "agent.favorites")
        objectWillChange.send()
    }

    private func start() {
        guard prefs.usesAgent else { return }
        let activeBackend = self.backend

        // 0 ms fast path: attach an already-warm worker from AgentEngine's pool
        // when we aren't resuming a specific older session ID.
        if resuming == nil, let warm = AgentEngine.shared.checkout(activeBackend) {
            attach(warm: warm)
            return
        }

        // If a background pre-warm for this backend is already mid-handshake,
        // wait for it to finish instead of spawning a duplicate subprocess!
        if resuming == nil, let pending = AgentEngine.shared.pendingWorker(for: activeBackend) {
            phase = .starting
            let generation = self.generation
            pending.waiters.append { [weak self] ok in
                guard let self, self.generation == generation, self.backend == activeBackend, self.phase == .starting, self.pipe == nil else { return }
                if ok, let warm = AgentEngine.shared.checkout(activeBackend) {
                    self.attach(warm: warm)
                } else {
                    self.startCold(activeBackend: activeBackend, generation: generation)
                }
            }
            return
        }

        phase = .starting
        let generation = self.generation
        startCold(activeBackend: activeBackend, generation: generation)
    }

    private func startCold(activeBackend: Backend, generation: UUID) {
        let custom = prefs.agentPath
        Task {
            // The browser's own tools first, so the file that tells the agent
            // where they are is there before it looks (see AgentTools.swift).
            if !(await AgentTools.shared.start()) {
                AgentTools.withdraw()
            }
            guard self.generation == generation, prefs.usesAgent else { return }
            if activeBackend == .graff { Agent.leaveKuriOut() }
            let resolved = await AgentEngine.shared.binary(for: activeBackend, customGraff: custom)
            let discovered = await AgentEngine.shared.discoverAll(customGraff: custom)
            guard self.generation == generation, prefs.usesAgent else { return }
            if !discovered.isEmpty { self.availableBackends = discovered }
            guard phase == .starting, pipe == nil else { return }
            guard let resolved else {
                phase = .missing
                return
            }
            launch(resolved.program, path: resolved.shellPath, backend: activeBackend)
        }
    }

    private func launch(_ program: URL, path: String?, backend activeBackend: Backend) {
        self.program = program
        var arguments = activeBackend.acpArguments
        if activeBackend == .graff, !prefs.agentModel.isEmpty {
            arguments += ["--model", prefs.agentModel]
        }
        let pipe = AcpPipe(program: program, arguments: arguments, environment: Agent.environment(for: program, path: path, lean: !prefs.agentAllTools), folder: Agent.folder)
        pipe.onMessage = { [weak self, weak pipe] message in
            guard let self, let pipe, self.pipe === pipe else { return }
            self.take(message)
        }
        pipe.onExit = { [weak self, weak pipe] status, said in
            guard let self, let pipe, self.pipe === pipe else { return }
            self.ended(status: status, said: said)
        }
        do {
            try pipe.start()
        } catch {
            phase = .broken("Couldn't run \(program.path): \(error.localizedDescription)")
            return
        }
        self.pipe = pipe
        call("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": [String: Any]()],
            "clientInfo": ["name": "browse", "title": "browse", "version": Updater.version],
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.open()
            case .failure(let failure): self.stumbled(failure)
            }
        }
    }

    /// A session, in graff's own folder: the one being carried over if
    /// there is one, a new one otherwise. The first request that needs
    /// someone signed in — a graff with nobody signed in says so here.
    private func open() {
        let params: [String: Any] = ["cwd": Agent.folder.path, "mcpServers": AgentTools.shared.acpServers]
        if let carried = resuming {
            resuming = nil
            replaying = true
            var loading = params
            loading["sessionId"] = carried
            call("session/load", loading) { [weak self] result in
                guard let self else { return }
                self.replaying = false
                switch result {
                case .success(let value): self.opened(carried, value)
                case .failure(let failure):
                    if Agent.wantsSignIn(failure) {
                        self.stumbled(failure)
                    } else {
                        // A fresh session, told what was said in the old one.
                        self.lost = Agent.transcript(self.entries)
                        self.open()
                    }
                }
            }
            return
        }
        call("session/new", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                guard let id = (value as? [String: Any])?["sessionId"] as? String else {
                    self.stumbled(Failure(code: 0, message: "graff opened no session"))
                    return
                }
                self.opened(id, value)
            case .failure(let failure):
                self.stumbled(failure)
            }
        }
    }

    private func opened(_ id: String, _ reply: Any) {
        session = id
        phase = .ready
        lastActive = Date()
        watchIdle()
        introduced = false
        adopt(reply)
        // The level last chosen, where this model offers it.
        let wanted = prefs.agentEffort
        if let effort, !wanted.isEmpty, wanted != effort.current, effort.levels.contains(where: { $0.value == wanted }) {
            choose(effort: wanted)
        }
        if backend == .graff {
            listModels()
        } else {
            let savedModel = prefs.agentModel(for: backend.rawValue)
            if !savedModel.isEmpty,
               let match = models.first(where: { $0.id == savedModel || $0.acpValue == savedModel }),
               match != self.model {
                choose(match)
            }
        }
        if let blocks = held {
            held = nil
            prompt(blocks)
        }
    }

    /// Shared parser for `graff/models` used by both live sessions and
    /// `AgentEngine` background pre-warming.
    static func parseGraffModels(_ reply: [String: Any]) -> (models: [Model], current: Model?, serviceTier: ServiceTier) {
        let rows = reply["models"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var models: [Model] = rows.compactMap { row in
            guard row["authenticated"] as? Bool == true,
                  let provider = row["provider"] as? String, let name = row["name"] as? String,
                  !provider.isEmpty, !name.isEmpty
            else { return nil }
            let rawMaker = (row["maker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let cost = (row["cost"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let separate = row["separateQuota"] as? Bool == true
            let billing = (cost == "plan" && separate) ? "plan*" : cost
            let effortLevels = (row["effortLevels"] as? [Any] ?? []).compactMap { $0 as? String }
            let fast = row["fastSupported"] as? Bool == true
            let ultrafast = row["ultrafastSupported"] as? Bool == true
            let serviceTiers = (row["serviceTiers"] as? [Any] ?? []).compactMap { $0 as? String }
            let model = Model(
                provider: provider,
                name: name,
                context: row["context"] as? Int ?? 0,
                rawMaker: rawMaker,
                billing: billing,
                effortLevels: effortLevels,
                fastSupported: fast,
                ultrafastSupported: ultrafast,
                serviceTiers: serviceTiers
            )
            guard model.talks else { return nil }
            return seen.insert(model.id).inserted ? model : nil
        }
        var currentModel: Model?
        var tier: ServiceTier = .standard
        if let current = reply["current"] as? [String: Any],
           let provider = current["provider"] as? String, let name = current["model"] as? String {
            let now = models.first { $0.provider == provider && $0.name == name } ?? Model(provider: provider, name: name)
            currentModel = now
            if let rawTier = current["serviceTier"] as? String, let parsed = ServiceTier(rawValue: rawTier) {
                tier = parsed
            } else if current["fast"] as? Bool == true {
                tier = .fast
            }
            models.removeAll { $0 == now }
            models.insert(now, at: 0)
        }
        return (models, currentModel, tier)
    }

    /// What graff can reach with the keys it has, for the picker, and which
    /// one it is on — graff's own `graff/models`, the catalog its `/models`
    /// prints.
    private func listModels() {
        call("graff/models", [:]) { [weak self] result in
            guard let self, case .success(let value) = result, let reply = value as? [String: Any] else { return }
            let parsed = Agent.parseGraffModels(reply)
            if let now = parsed.current {
                self.model = now
                self.serviceTier = parsed.serviceTier
                // Apply remembered service tier preference if supported by this model.
                let wantedRaw = self.prefs.agentServiceTier
                if !wantedRaw.isEmpty,
                   let wanted = ServiceTier(rawValue: wantedRaw),
                   now.supportedServiceTiers.contains(wanted),
                   wanted != self.serviceTier {
                    self.choose(serviceTier: wanted)
                }
            }
            if !parsed.models.isEmpty {
                self.models = parsed.models
                AgentEngine.shared.saveCatalog(
                    for: .graff,
                    models: parsed.models,
                    current: parsed.current ?? self.model,
                    effort: self.effort,
                    modelConfigID: nil
                )
            }
        }
    }

    /// Switches Codex / ChatGPT service tier (`Standard` / `Fast` / `Ultra Fast`)
    /// via graff's persistent `/fast` slash command without polluting the chat transcript.
    func choose(serviceTier tier: ServiceTier) {
        guard backend == .graff else { return }
        if let model, !model.supportedServiceTiers.isEmpty, !model.supportedServiceTiers.contains(tier) {
            return
        }
        prefs.agentServiceTier = tier.rawValue
        guard tier != serviceTier || pendingServiceTier != nil else { return }
        serviceTier = tier
        if session == nil || prompting || phase == .working {
            pendingServiceTier = tier
            return
        }
        applyServiceTierNow(tier)
    }

    private func applyServiceTierNow(_ tier: ServiceTier) {
        guard let session else {
            pendingServiceTier = tier
            return
        }
        pendingServiceTier = nil
        applyingServiceTier = true
        call("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": tier.slashCommand]]]) { [weak self] _ in
            guard let self else { return }
            self.applyingServiceTier = false
            self.listModels()
            if let next = self.pendingServiceTier {
                self.applyServiceTierNow(next)
            }
        }
    }

    /// A reasoning level, for the session graff has now. The model decides
    /// which there are; the choice is remembered for the next session.
    func choose(effort value: String) {
        guard let session, let effort, effort.levels.contains(where: { $0.value == value }) else { return }
        prefs.agentEffort = value
        guard value != effort.current else { return }
        self.effort?.current = value
        call("session/set_config_option", ["sessionId": session, "configId": effort.id, "value": value]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply): self.adopt(reply)
            case .failure(let failure):
                self.effort?.current = effort.current
                self.entries.append(Entry(kind: .note, text: failure.message))
            }
        }
    }

    /// Shared parser for ACP `configOptions` (`thought_level` + `model`) and
    /// `models.availableModels`, used by both live sessions and `AgentEngine`.
    static func parseSessionOptions(_ reply: Any, backend: Backend) -> (
        effort: Effort?,
        hasConfigOptions: Bool,
        models: [Model],
        current: Model?,
        modelConfigID: String?
    ) {
        guard let dict = reply as? [String: Any] else {
            return (nil, false, [], nil, nil)
        }
        let hasConfig = dict["configOptions"] != nil
        let options = dict["configOptions"] as? [[String: Any]] ?? []

        var parsedEffort: Effort?
        if let option = options.first(where: {
            ($0["category"] as? String == "thought_level" || $0["id"] as? String == "thought_level")
                && ($0["type"] as? String ?? "select") == "select"
        }), let id = option["id"] as? String {
            let levels = (option["options"] as? [[String: Any]] ?? []).compactMap { choice -> (value: String, name: String)? in
                guard let value = choice["value"] as? String else { return nil }
                return (value, choice["name"] as? String ?? value.capitalized)
            }
            parsedEffort = levels.isEmpty ? nil : Effort(id: id, current: option["currentValue"] as? String ?? "", levels: levels)
        }

        guard backend != .graff else {
            return (parsedEffort, hasConfig, [], nil, nil)
        }

        let effortValues = parsedEffort?.levels.map(\.value) ?? []
        let fallbackProvider = backend.providerKey

        func makeACPModel(rawID: String, rawName: String?) -> Model {
            let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if backend == .opencode, let slash = rawID.firstIndex(of: "/") {
                let vendor = String(rawID[..<slash])
                let rest = String(rawID[rawID.index(after: slash)...])
                let cleanDisplay = trimmedName.flatMap { name -> String? in
                    if let s = name.firstIndex(of: "/") {
                        let tail = String(name[name.index(after: s)...])
                        return tail.isEmpty ? name : tail
                    }
                    return name.isEmpty ? nil : name
                }
                return Model(
                    provider: vendor,
                    name: rest,
                    displayName: cleanDisplay,
                    acpValue: rawID,
                    billing: "plan",
                    effortLevels: effortValues
                )
            }
            return Model(
                provider: fallbackProvider,
                name: rawID,
                displayName: (trimmedName?.isEmpty == false) ? trimmedName : nil,
                acpValue: rawID,
                billing: "plan",
                effortLevels: effortValues
            )
        }

        var parsedModels: [Model] = []
        var parsedCurrent: Model?
        var parsedConfigID: String?

        if let modelOpt = options.first(where: {
            ($0["category"] as? String == "model" || $0["id"] as? String == "model")
                && ($0["type"] as? String ?? "select") == "select"
        }), let configID = modelOpt["id"] as? String {
            parsedConfigID = configID
            let choices = modelOpt["options"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            parsedModels = choices.compactMap { choice in
                guard let value = choice["value"] as? String, !value.isEmpty else { return nil }
                let m = makeACPModel(rawID: value, rawName: choice["name"] as? String)
                return seen.insert(m.id).inserted ? m : nil
            }
            if let currentValue = modelOpt["currentValue"] as? String, !currentValue.isEmpty {
                let now = parsedModels.first { $0.acpValue == currentValue } ?? makeACPModel(rawID: currentValue, rawName: nil)
                parsedCurrent = now
                parsedModels.removeAll { $0 == now }
                parsedModels.insert(now, at: 0)
            } else {
                parsedCurrent = parsedModels.first
            }
        } else if let modelsObj = dict["models"] as? [String: Any],
                  let available = modelsObj["availableModels"] as? [[String: Any]] {
            var seen = Set<String>()
            parsedModels = available.compactMap { row in
                guard let modelId = row["modelId"] as? String, !modelId.isEmpty else { return nil }
                let m = makeACPModel(rawID: modelId, rawName: row["name"] as? String)
                return seen.insert(m.id).inserted ? m : nil
            }
            if let currentID = modelsObj["currentModelId"] as? String, !currentID.isEmpty {
                let now = parsedModels.first { $0.acpValue == currentID } ?? makeACPModel(rawID: currentID, rawName: nil)
                parsedCurrent = now
                parsedModels.removeAll { $0 == now }
                parsedModels.insert(now, at: 0)
            } else {
                parsedCurrent = parsedModels.first
            }
        }

        return (parsedEffort, hasConfig, parsedModels, parsedCurrent, parsedConfigID)
    }

    /// Session options from opening a session or changing one: `thought_level`
    /// for all ACP backends, plus standard ACP `model` configOptions /
    /// `models.availableModels` for non-graff backends.
    private func adopt(_ reply: Any) {
        let parsed = Agent.parseSessionOptions(reply, backend: backend)
        if let e = parsed.effort {
            effort = e
        } else if parsed.hasConfigOptions {
            effort = nil
        }
        guard backend != .graff else { return }
        if parsed.modelConfigID != nil || !parsed.models.isEmpty {
            modelConfigID = parsed.modelConfigID
        }
        if let cur = parsed.current {
            model = cur
        }
        if !parsed.models.isEmpty {
            models = parsed.models
            AgentEngine.shared.saveCatalog(
                for: backend,
                models: parsed.models,
                current: parsed.current ?? model,
                effort: effort,
                modelConfigID: modelConfigID
            )
        }
    }

    /// A page graff read through the browser's tools, named in the column.
    func saw(_ url: URL, title: String) {
        entries.append(Entry(kind: .page, text: title, key: url.absoluteString))
    }

    /// What was said, with pages read one after another kept together, so
    /// the column can draw them as one card.
    static func grouped(_ entries: [Entry]) -> [[Entry]] {
        var runs: [[Entry]] = []
        for entry in entries {
            if entry.kind == .page, runs.last?.last?.kind == .page {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
        return runs
    }

    private func stumbled(_ failure: Failure) {
        if Agent.wantsSignIn(failure) {
            phase = .signedOut
            held = nil
            return
        }
        phase = .broken(failure.message)
    }

    private func ended(status: Int32, said: String) {
        pipe = nil
        session = nil
        asking = nil
        owed = [:]
        prompting = false
        replaying = false
        let why = said.isEmpty ? "graff stopped (status \(status))." : said
        fail(Failure(code: Int(status), message: why))
        if phase == .signedOut || phase == .missing { return }
        phase = Agent.wantsSignIn(Failure(code: 0, message: why)) ? .signedOut : .broken(why)
        stumble = why
        keep()
    }

    /// Signed in to Codegraff from here, as `graff login` does — the page
    /// to approve it opens as a tab, and graff starts again once it's done
    /// (see Account.swift).
    func signIn() {
        guard let browser = AgentTools.shared.browser else { return }
        CodegraffAccount.shared.signIn(show: { browser.open($0, foreground: true) }, done: { browser.signedIn() })
    }

    /// `graff login`, in Terminal, for the providers graff signs in to
    /// itself — Codex, Kimi and the rest. A .command file opens there on its
    /// own, without the browser needing leave to drive Terminal.
    func loginInTerminal() {
        Task {
            guard let found = await Agent.locate(custom: prefs.agentPath)?.program else {
                phase = .missing
                return
            }
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("graff-login.command")
            let body = """
            #!/bin/sh
            clear
            \(Agent.quoted(found.path)) login
            """
            do {
                try body.write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            } catch {
                return
            }
            NSWorkspace.shared.open(script)
        }
    }

    /// Whether graff is running now, rather than waiting to be asked.
    var started: Bool { pipe != nil }

    // MARK: - talking

    /// Earlier user prompts in this conversation, oldest first (deduplicating
    /// consecutive repeats), for NanoHarness ↑/↓ prompt recall.
    var sessionPrompts: [String] {
        var out: [String] = []
        for entry in entries where entry.kind == .you {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, out.last != trimmed else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// What was typed. An answer, if graff is waiting on one; otherwise a
    /// prompt, with the page as an embedded resource — graff's way of taking
    /// a document along with the words.
    func send(page tab: Tab?) {
        if composer.editingQueueID != nil {
            commitQueueEdit()
            return
        }
        guard prefs.usesAgent else { return }
        let tab = pinned ?? tab
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !text.isEmpty || !images.isEmpty else { return }
        if !text.isEmpty, let details = AgentFeedbackDraft.command(text), let browser = AgentTools.shared.browser {
            draft = ""
            browser.reportAgentProblem(details)
            return
        }
        if let asking, asking.isQuestion {
            guard !text.isEmpty else { return }
            draft = ""
            entries.append(Entry(kind: .you, text: text))
            respond(asking, text: text)
            return
        }
        guard Agent.wire((passage?.blocks ?? []) + [["type": "text", "text": text]]) < Agent.longestLine - (passage == nil ? 0 : 16_000) else {
            entries.append(Entry(kind: .note, text: "That's too long to send in one message"))
            return
        }
        draft = ""
        writeMode = false
        let excerpt = passage
        passage = nil
        clearImages()
        let extras = mentionedTabs.filter { !$0.isBlank && $0.id != tab?.id }
        clearMentionedTabs()
        let hist = mentionedHistory
        clearMentionedHistory()
        // Mid-turn, it waits its turn.
        if phase == .working || prompting {
            queue.append(Queued(text: text, tab: tab, passage: excerpt, mentioned: extras, history: hist, images: images))
            return
        }
        queueHeld = false
        submit(text, page: tab, passage: excerpt, mentioned: extras, history: hist, images: images)
    }

    /// Re-sends an earlier user prompt without discarding anything the user
    /// currently has typed in the composer.
    func resend(_ text: String, page tab: Tab?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, prefs.usesAgent, phase != .working, !prompting else { return }
        submit(trimmed, page: pinned ?? tab)
    }

    /// NanoHarness ⌘↩ shortcut:
    /// - Editing a queued item → save back to queue.
    /// - Empty draft while queued items exist → interrupt and send newest queued item now.
    /// - Non-empty draft while working → interrupt current turn and send this immediately.
    /// - Otherwise → standard send.
    func sendInterrupt(page tab: Tab?) {
        if composer.editingQueueID != nil {
            commitQueueEdit()
            return
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && pendingImages.isEmpty {
            if let newest = queue.last { sendNow(newest.id) }
            return
        }
        if (phase == .working || prompting), asking?.isQuestion != true {
            guard prefs.usesAgent else { return }
            let targetTab = pinned ?? tab
            let excerpt = passage
            let images = pendingImages
            let extras = mentionedTabs.filter { !$0.isBlank && $0.id != targetTab?.id }
            let hist = mentionedHistory
            draft = ""
            writeMode = false
            passage = nil
            clearImages()
            clearMentionedTabs()
            clearMentionedHistory()
            let item = Queued(text: trimmed, tab: targetTab, passage: excerpt, mentioned: extras, history: hist, images: images)
            queue.insert(item, at: 0)
            queueHeld = false
            if let asking { answer(asking, with: nil) }
            if let session { notify("session/cancel", ["sessionId": session]) }
            return
        }
        send(page: tab)
    }

    private func submit(
        _ text: String,
        page tab: Tab?,
        passage: AgentPassage? = nil,
        mentioned: [Tab] = [],
        history: [HistoryMention] = [],
        images: [PastedImage] = []
    ) {
        let generation = self.generation
        let skillExpansion = DiaSkill.expand(text, customTasks: tasks.all)
        let wireText = skillExpansion?.prompt ?? text
        let pageTitle = tab.flatMap { tab -> String? in
            guard !tab.isBlank else { return nil }
            return tab.title.isEmpty ? (tab.address?.host() ?? "This page") : tab.title
        }
        let extraTitles = mentioned.compactMap { extra -> String? in
            guard !extra.isBlank else { return nil }
            return extra.title.isEmpty ? (extra.address?.host() ?? "Tab") : extra.title
        } + history.map(\.title)
        let displayPage: String? = {
            let names = ([pageTitle].compactMap { $0 }) + extraTitles.map { "@\($0)" }
            return names.isEmpty ? nil : names.joined(separator: " · ")
        }()
        lastActive = Date()
        if chatID == nil { chatID = UUID() }
        entries.append(Entry(kind: .you, text: text, page: displayPage, passage: passage, images: images.isEmpty ? nil : images))
        outcome = nil
        keep()
        if phase == .ready { phase = .working }
        Task {
            var page: (address: String, title: String, text: String, tab: String)?
            if let tab { page = await Agent.read(tab) }
            var extras: [(address: String, title: String, text: String, tab: String)] = []
            for extra in mentioned {
                if let read = await Agent.read(extra) { extras.append(read) }
            }
            guard self.generation == generation, prefs.usesAgent else { return }
            let blocks = Agent.blocks(
                wireText,
                page: page,
                extras: extras,
                history: history,
                passage: passage,
                images: images,
                only: self.pinned != nil && tab === self.pinned
            )
            switch phase {
            case .ready, .working:
                prompt(blocks)
            case .asleep, .starting:
                held = blocks
                wake()
            default:
                entries.append(Entry(kind: .note, text: "graff isn't running"))
            }
        }
    }

    private func prompt(_ blocks: [[String: Any]]) {
        guard let session else {
            held = blocks
            return
        }
        phase = .working
        prompting = true
        var blocks = blocks
        if let lost {
            self.lost = nil
            blocks.insert(["type": "text", "text": "Earlier in this conversation, before you were restarted:\n\n" + lost], at: 0)
        }
        if !introduced {
            introduced = true
            var intro = Agent.introduction
            let memory = prefs.agentMemory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !memory.isEmpty {
                intro += "\n\nUser's personal preferences and memory (always honor these):\n" + memory
            }
            blocks.insert(["type": "text", "text": intro], at: 0)
        }
        call("session/prompt", ["sessionId": session, "prompt": blocks]) { [weak self] result in
            guard let self else { return }
            self.flushFlow()
            self.prompting = false
            if self.phase == .working { self.phase = .ready }
            self.asking = nil
            switch result {
            case .success(let value):
                let reason = (value as? [String: Any])?["stopReason"] as? String
                if reason == "cancelled" {
                    self.entries.append(Entry(kind: .note, text: "Stopped"))
                } else if reason == "max_turn_requests" {
                    self.entries.append(Entry(kind: .note, text: "Stopped at its limit for one turn"))
                }
                self.settle(reason == "end_turn")
                self.stumble = nil
                self.outcome = reason == "end_turn" ? .finished : .stopped
            case .failure(let failure):
                self.settle(false)
                if failure.code != -1 { self.outcome = .interrupted(failure.message) }
                self.queueHeld = !self.queue.isEmpty
                if Agent.wantsSignIn(failure) {
                    self.phase = .signedOut
                    self.stumble = failure.message
                } else if failure.code != -1 {
                    self.entries.append(Entry(kind: .note, text: failure.message))
                    self.stumble = failure.message
                }
            }
            self.keep()
            if let pendingTier = self.pendingServiceTier, !self.prompting, self.phase == .ready {
                self.applyServiceTierNow(pendingTier)
            }
            self.sendQueued()
        }
    }

    // MARK: - the queue

    /// The next queued message, once a turn is over — unless it ended by
    /// hand, or badly, or graff is waiting on an answer.
    private func sendQueued() {
        guard !queueHeld, !prompting, asking == nil, phase == .ready, !queue.isEmpty else { return }
        let first = queue.removeFirst()
        submit(first.text, page: first.tab, passage: first.passage, mentioned: first.mentioned, history: first.history, images: first.images)
    }

    /// Harness's Send now: this one goes next, and the turn under way is
    /// stopped so it can.
    func sendNow(_ id: Queued.ID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: index)
        queue.insert(item, at: 0)
        queueHeld = false
        if prompting || phase == .working {
            if let asking { answer(asking, with: nil) }
            if let session { notify("session/cancel", ["sessionId": session]) }
        } else {
            sendQueued()
        }
    }

    /// NanoHarness inline queue editing: opens the queued row in the composer
    /// while keeping the row visible as "Editing in composer".
    func edit(_ id: Queued.ID) {
        if composer.editingQueueID == id { return }
        if composer.editingQueueID != nil { cancelQueueEdit() }
        guard let item = queue.first(where: { $0.id == id }) else { return }
        savedDraftBeforeQueueEdit = draft
        composer.editingQueueID = id
        draft = item.text
    }

    func commitQueueEdit() {
        guard let id = composer.editingQueueID else { return }
        let edited = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = queue.firstIndex(where: { $0.id == id }) {
            if edited.isEmpty {
                queue.remove(at: index)
            } else {
                queue[index].text = edited
            }
        }
        composer.editingQueueID = nil
        draft = savedDraftBeforeQueueEdit ?? ""
        savedDraftBeforeQueueEdit = nil
    }

    func cancelQueueEdit() {
        guard composer.editingQueueID != nil else { return }
        composer.editingQueueID = nil
        draft = savedDraftBeforeQueueEdit ?? ""
        savedDraftBeforeQueueEdit = nil
    }

    func unqueue(_ id: Queued.ID) {
        if composer.editingQueueID == id { cancelQueueEdit() }
        queue.removeAll { $0.id == id }
        if queue.isEmpty { queueHeld = false }
    }

    /// Explicitly release a held queue after Stop/Reconnect and send the next item.
    func resumeHeldQueue() {
        guard queueHeld, !prompting, asking == nil, phase == .ready, !queue.isEmpty else { return }
        queueHeld = false
        sendQueued()
    }

    /// Discard every waiting queued message and cancel any active inline queue edit.
    func clearQueued() {
        if composer.editingQueueID != nil { cancelQueueEdit() }
        queue.removeAll()
        queueHeld = false
    }

    /// The turn is over: anything still spinning has finished, or never will.
    private func settle(_ finished: Bool) {
        for index in entries.indices where entries[index].kind == .tool
            && (entries[index].status == "pending" || entries[index].status == "in_progress") {
            entries[index].status = finished ? "completed" : "failed"
        }
    }

    /// Esc for graff: the turn ends at its next step. A question it was
    /// waiting on goes unanswered.
    func stop() {
        if !queue.isEmpty { queueHeld = true }
        if let asking { answer(asking, with: nil) }
        guard let session else { return }
        notify("session/cancel", ["sessionId": session])
    }

    func answer(_ ask: Ask, with option: Ask.Option?, preserveDraft: Bool = false) {
        guard asking?.id == ask.id else { return }
        switch ask.wants {
        case .permission(let request):
            asking = nil
            let outcome: [String: Any] = option.map { ["outcome": "selected", "optionId": $0.id] }
                ?? ["outcome": "cancelled"]
            reply(to: request, result: ["outcome": outcome])
        case .question:
            if let option { entries.append(Entry(kind: .you, text: option.name)) }
            respond(ask, text: option?.name, preserveDraft: preserveDraft)
        }
    }

    /// A question answered in words, or left — `session/answer` either way,
    /// or graff's turn waits for ever.
    private func respond(_ ask: Ask, text: String?, preserveDraft: Bool = false) {
        asking = nil
        if !preserveDraft { moveDraft(to: AgentTools.shared.browser?.active) }
        guard let session else { return }
        notify("session/answer", ["sessionId": session, "text": text ?? "", "cancelled": text == nil])
    }

    // MARK: - what graff says

    private func take(_ message: [String: Any]) {
        lastActive = Date()
        let method = message["method"] as? String
        let id = message["id"]
        if let method, let id, !(id is NSNull) {
            asked(method, id: id, params: message["params"] as? [String: Any] ?? [:])
        } else if let method {
            guard method == "session/update", !replaying,
                  let params = message["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any]
            else { return }
            if let session, let from = params["sessionId"] as? String, from != session { return }
            if applyingServiceTier || suppressingControlOutput {
                // Still adopt effort/config changes emitted by live `/model` or `/fast`.
                if update["sessionUpdate"] as? String == "config_option_update" {
                    updated(update)
                }
                return
            }
            updated(update)
        } else if let id = Agent.number(id), let answer = waiting.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                answer(.failure(Failure(code: Agent.number(error["code"]) ?? 0, message: error["message"] as? String ?? "graff refused")))
            } else {
                answer(.success(message["result"] ?? NSNull()))
            }
        }
    }

    private func updated(_ update: [String: Any]) {
        lastStreamAt = Date()
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            flow(.reply, Agent.text(update["content"]))
        case "agent_thought_chunk":
            flow(.thought, Agent.text(update["content"]))
        case "tool_call":
            flushFlow()
            let key = update["toolCallId"] as? String ?? ""
            let title = update["title"] as? String ?? "Working"
            // graff finding and unfolding its own tools: its business, not
            // something done.
            if Agent.plumbing.contains(title) { return }
            let status = update["status"] as? String ?? "pending"
            let act = update["kind"] as? String ?? ""
            let index: Int
            if !key.isEmpty, let found = entries.lastIndex(where: { $0.kind == .tool && $0.key == key }) {
                index = found
                entries[index].text = title
                entries[index].status = status
                if !act.isEmpty { entries[index].act = act }
            } else {
                entries.append(Entry(kind: .tool, text: title, key: key, status: status, act: act))
                index = entries.count - 1
            }
            entries[index].step = Steps.typed(update)
            took(update, into: index)
        case "tool_call_update":
            let key = update["toolCallId"] as? String ?? ""
            guard let index = entries.lastIndex(where: { $0.kind == .tool && $0.key == key }) else { return }
            entries[index].until = Date()
            if let status = update["status"] as? String { entries[index].status = status }
            if let title = update["title"] as? String, !title.isEmpty { entries[index].text = title }
            // Only an update that says something about the call's shape
            // re-types it, as Harness does: a completion that carries only
            // the result keeps the Run a Run.
            if Steps.reshapes(update) {
                var merged = update
                if merged["kind"] == nil, !entries[index].act.isEmpty { merged["kind"] = entries[index].act }
                if merged["title"] == nil { merged["title"] = entries[index].text }
                entries[index].step = Steps.typed(merged)
            }
            took(update, into: index)
        case "plan":
            flushFlow()
            // No id of its own on the wire: one plan per turn, refreshed in
            // place, as Harness keeps it under one id.
            let items = Steps.plan(update)
            let turn = entries.lastIndex { $0.kind == .you } ?? -1
            if let index = entries.lastIndex(where: { $0.kind == .plan }), index > turn {
                entries[index].todo = items
                entries[index].until = Date()
            } else {
                var plan = Entry(kind: .plan, text: "Todo")
                plan.todo = items
                entries.append(plan)
            }
        case "usage_update":
            let used = Agent.number(update["used"])
            let window = ["max", "limit", "size", "contextWindow", "context_window"]
                .lazy.compactMap { Agent.number(update[$0]) }.first { $0 > 0 }
            if used != nil || window != nil { context = (used ?? context?.used ?? 0, window ?? context?.window ?? 0) }
        case "session_info_update":
            // graff naming the conversation. A name somebody gave it stays.
            if let title = update["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                named = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "available_commands_update":
            commands = (update["availableCommands"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        case "user_message_chunk", "current_mode_update":
            // A live user chunk is the prompt echoed back; modes aren't
            // something the column offers. Harness drops both too.
            break
        case "gui_ask_user":
            flushFlow()
            if let asking { answer(asking, with: nil) }
            let input = update["input"] as? [String: Any] ?? [:]
            let options = (input["options"] as? [Any] ?? []).compactMap { option -> Ask.Option? in
                let name = option as? String
                    ?? (option as? [String: Any]).flatMap { $0["label"] as? String ?? $0["name"] as? String ?? $0["value"] as? String }
                return name.map { Ask.Option(id: $0, name: $0, kind: "answer") }
            }
            asking = Ask(
                wants: .question,
                title: update["question"] as? String ?? "Codegraff has a question",
                detail: nil,
                options: options
            )
        case "config_option_update":
            adopt(update)
        case "gui_turn_end":
            flushFlow()
            // A turn graff woke up for on its own has ended; one Search
            // started ends with its answer instead.
            if !prompting { settle(true) }
        default:
            break
        }
    }

    /// A call's result as it arrives: what it printed, and what an edit
    /// changed.
    private func took(_ update: [String: Any], into index: Int) {
        let shown = Agent.shown(update["content"])
        if !shown.isEmpty { entries[index].output = String(shown.prefix(16_000)) }
        if let diff = Steps.diff(update) { entries[index].diff = diff }
    }

    /// A reply or a thought arrives a few words at a time; coalesce bursts to
    /// ~60 Hz (16 ms) so rapid streaming never starves 120 FPS scrolling or typing,
    /// and flush immediately on every structural boundary (tool, plan, end).
    private func flow(_ kind: Entry.Kind, _ piece: String) {
        guard !piece.isEmpty else { return }
        if let pending = pendingFlow, pending.kind == kind {
            pendingFlow = (kind, pending.text + piece)
        } else {
            flushFlow()
            pendingFlow = (kind, piece)
        }
        guard flowFlushTask == nil else { return }
        flowFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            self?.flushFlow()
        }
    }

    private func flushFlow() {
        flowFlushTask?.cancel()
        flowFlushTask = nil
        guard let pending = pendingFlow else { return }
        pendingFlow = nil
        lastStreamAt = Date()
        if let last = entries.indices.last, entries[last].kind == pending.kind {
            entries[last].text += pending.text
            entries[last].until = Date()
        } else {
            entries.append(Entry(kind: pending.kind, text: pending.text))
        }
    }

    /// The bench's `stream`: a question, then its answer arriving a piece at
    /// a time through the same door graff's updates come in by, with the
    /// column drawing it as it would a turn at work. Test runs only.
    func rehearse(asking: String) {
        guard Store.testing else { return }
        entries.append(Entry(kind: .you, text: asking))
        outcome = nil
        before = phase
        phase = .working
    }

    func rehearse(piece: String) {
        guard Store.testing else { return }
        take(["jsonrpc": "2.0", "method": "session/update", "params": [
            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": piece]],
        ]])
        flushFlow()
    }

    /// Any `session/update` at all, as graff would send it — the bench's
    /// `acp`, for drawing a turn's steps, plan and diffs without a model
    /// having to do them. Test runs only.
    func rehearse(update: [String: Any]) {
        guard Store.testing else { return }
        take(["jsonrpc": "2.0", "method": "session/update", "params": ["update": update]])
    }

    /// Back to what it was before: ready, or no graff at all.
    func rehearsed() {
        guard Store.testing, let was = before else { return }
        before = nil
        if phase == .working, !prompting { phase = was }
        outcome = .finished
    }

    private var before: Phase?

    private func asked(_ method: String, id: Any, params: [String: Any]) {
        let key = "\(id)"
        owed[key] = id
        switch method {
        case "session/request_permission":
            // Only from a graff that wasn't started with --yolo, such as one
            // named in Settings that ignores it. Asked, not assumed.
            if let session, let from = params["sessionId"] as? String, from != session {
                reply(to: key, result: ["outcome": ["outcome": "cancelled"]])
                return
            }
            let call = params["toolCall"] as? [String: Any] ?? [:]
            let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> Ask.Option? in
                guard let id = option["optionId"] as? String else { return nil }
                return Ask.Option(id: id, name: option["name"] as? String ?? id, kind: option["kind"] as? String ?? "")
            }
            if let asking { answer(asking, with: nil) }
            asking = Ask(
                wants: .permission(request: key),
                title: call["title"] as? String ?? "Codegraff wants to do something on your Mac",
                detail: Agent.brief(call["rawInput"]),
                options: options
            )
        default:
            reply(to: key, error: ["code": -32601, "message": "Method not found: \(method)"])
        }
    }

    // MARK: - the wire

    private func call(_ method: String, _ params: [String: Any], then: @escaping (Result<Any, Failure>) -> Void) {
        guard let pipe else {
            then(.failure(Failure(code: -1, message: "graff isn't running")))
            return
        }
        let id = next
        next += 1
        waiting[id] = then
        if !pipe.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) {
            waiting[id] = nil
            then(.failure(Failure(code: 0, message: "That's too long to send in one message")))
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        pipe?.send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func reply(to key: String, result: Any? = nil, error: [String: Any]? = nil) {
        guard let id = owed.removeValue(forKey: key) else { return }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { message["error"] = error } else { message["result"] = result ?? NSNull() }
        pipe?.send(message)
    }

    /// Everything still waiting on graff hears that it won't come.
    private func fail(_ failure: Failure) {
        let answers = waiting.values
        waiting = [:]
        answers.forEach { $0(.failure(failure)) }
    }

    // MARK: - pieces

    /// graff's own browser, kuri, switched off for the graff that runs here:
    /// in a browser, the browser is the one to use, and a second one driven
    /// from the shell only competes with it. graff reads the switch from
    /// .harness/settings.json in the folder it works in — {"skills": {"kuri":
    /// false}}, the same one `/skills remove kuri` writes — so graff
    /// everywhere else keeps it. Anything else in the file is left as it is.
    static func leaveKuriOut() {
        let folder = Agent.folder.appendingPathComponent(".harness", isDirectory: true)
        let file = folder.appendingPathComponent("settings.json")
        var settings = (try? Data(contentsOf: file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var skills = settings["skills"] as? [String: Any] ?? [:]
        guard skills["kuri"] as? Bool != false else { return }
        skills["kuri"] = false
        settings["skills"] = skills
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// graff's own steps for finding and loading tools.
    private static let plumbing: Set<String> = ["mcp_search_tools", "load_tool_schemas", "mcp_select_tool", "read_tool_result"]

    /// Said once at the start of each session, ahead of the first message:
    /// where graff is, and what it has to hand here that it wouldn't at a
    /// terminal.
    private static var introduction: String {
        var text = """
        You are graff (Codegraff), running inside browse, the web browser the user is using right now; \
        they are talking to you from beside the page, or from a page of its own. The `browse` MCP \
        tools (mcp__browse__*) are already loaded: call them directly, with no searching for or \
        loading of tools first. When a page comes with the question, answer from it; when you \
        know the answer well, say it. Go to the web for what is current, specific or checkable, \
        or when asked for sources: `search`, then `read_pages` with many \
        links at once — they load in parallel in pages the user doesn't see — and `open` a page to \
        act on it. For steps on a page — a form, a search and its filters — `drive` takes the goal \
        and the values to type and does the clicking and typing quickly; `form_fields` and `fill` \
        are there too, and set many fields at once. When it is on the page the user is looking at, act on their tab \
        (its id comes with the page) so they watch it happen. Fill freely, but ask before \
        submitting anything that pays, sends, posts, books, deletes or signs them up, and never \
        make up details about them — ask. The folder you are in is just your scratch space, not a \
        project. Answer plainly and briefly unless asked for more, and name the sources you used, \
        as markdown links.
        """
        if AgentTools.harnessAvailable {
            text += " The local Harness engine MCP server (`harness`, mcp__harness__*) is also connected — use it when the user asks to inspect or coordinate with NanoHarness chats, projects, devices, rooms, or bots."
        }
        return text
    }

    /// A conversation as words, for a graff that has lost its own record
    /// of it: what was asked and what was answered, the newest kept whole.
    static func transcript(_ entries: [Entry]) -> String? {
        let said = entries.compactMap { entry -> String? in
            switch entry.kind {
            case .you: return "User: " + entry.text
            case .reply: return "You: " + entry.text
            default: return nil
            }
        }
        guard !said.isEmpty else { return nil }
        let whole = said.joined(separator: "\n\n")
        return whole.count > 12_000 ? "…\n" + String(whole.suffix(12_000)) : whole
    }

    /// graff's folder for anything it makes when nobody said where: inside
    /// Search's own, so nothing lands loose in the home folder.
    static var folder: URL {
        let url = Store.folder.appendingPathComponent("Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// graff's "Authentication required: run `graff login`", however it
    /// arrives. By the words: graff uses the same code for other refusals.
    private static func wantsSignIn(_ failure: Failure) -> Bool {
        failure.message.localizedCaseInsensitiveContains("authentication required")
            || failure.message.localizedCaseInsensitiveContains("graff login")
    }

    /// An id or a code, whether it came as a number or as a string.
    static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    /// The text of a content block.
    private static func text(_ content: Any?) -> String {
        guard let block = content as? [String: Any] else { return "" }
        return block["text"] as? String ?? ""
    }

    /// A tool update's content, as the column shows it: text as it is, a
    /// diff as its path and new text.
    private static func shown(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item -> String? in
            switch item["type"] as? String {
            case "content": return text(item["content"])
            case "diff":
                let path = item["path"] as? String ?? ""
                let new = item["newText"] as? String ?? ""
                return path.isEmpty ? new : "\(path)\n\(new)"
            default: return nil
            }
        }
        .joined(separator: "\n")
    }

    /// The command or arguments behind a question, short enough to read.
    private static func brief(_ input: Any?) -> String? {
        guard let input else { return nil }
        if let object = input as? [String: Any] {
            for key in ["command", "cmd", "path", "file_path", "url"] {
                if let value = object[key] as? String { return value }
            }
        }
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return String(string.prefix(600))
    }

    /// A reply's markdown, inline: bold, code, links. Anything it can't read
    /// shows as it was written.
    static func rich(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// How many bytes something takes on the wire.
    private static func wire(_ object: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))?.count ?? .max
    }

    /// The prompt: the active page and any `@`-mentioned tabs, trimmed fairly to
    /// fit within one ACP line, followed by any excerpt, pasted images, and the user's words.
    private static func blocks(
        _ text: String,
        page: (address: String, title: String, text: String, tab: String)?,
        extras: [(address: String, title: String, text: String, tab: String)] = [],
        history: [HistoryMention] = [],
        passage: AgentPassage? = nil,
        images: [PastedImage] = [],
        only: Bool = false
    ) -> [[String: Any]] {
        let imageBlocks = images.map(\.acpBlock)
        let historyBlock: [[String: Any]] = history.isEmpty ? [] : [[
            "type": "text",
            "text": "Also referencing recently visited pages from browser history (use `read_pages` to inspect them if needed):\n"
                + history.map { "- \($0.title): \($0.url.absoluteString)" }.joined(separator: "\n"),
        ]]
        let words: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        let excerpt = passage?.blocks ?? []
        var sources: [(lead: String, address: String, whole: String)] = []
        if let page {
            let lead = only
                ? "Work only in my browser tab \(page.tab): pass page \"\(page.tab)\" to every browser tool, act on it rather than opening pages of your own, and don't submit a form or go past a step that pays, sends or signs up until I say so. Here it is now:"
                : "I'm looking at this page in my browser (tab \(page.tab)):"
            let whole = page.title.isEmpty ? page.text : "\(page.title)\n\n\(page.text)"
            sources.append((lead, page.address, whole))
        }
        for extra in extras {
            let title = extra.title.isEmpty ? extra.address : extra.title
            let lead = "Also referencing open browser tab \(extra.tab) (\(title)):"
            let whole = extra.title.isEmpty ? extra.text : "\(extra.title)\n\n\(extra.text)"
            sources.append((lead, extra.address, whole))
        }
        guard !sources.isEmpty else { return historyBlock + excerpt + imageBlocks + words }

        func assemble(_ bodies: [String]) -> [[String: Any]] {
            var out: [[String: Any]] = []
            for (src, body) in zip(sources, bodies) where !body.isEmpty {
                out.append(["type": "text", "text": src.lead])
                out.append(["type": "resource", "resource": [
                    "uri": src.address,
                    "mimeType": "text/plain",
                    "text": body,
                ]])
            }
            return out + historyBlock + excerpt + words
        }

        var bodies = sources.map(\.whole)
        let room = longestLine - 16_000
        var size = wire(assemble(bodies))
        while size > room {
            let totalChars = bodies.reduce(0) { $0 + $1.count }
            guard totalChars > 0 else { break }
            let ratio = Double(room) / Double(size) * 0.92
            bodies = bodies.map { body in
                guard !body.isEmpty else { return "" }
                let keep = max(0, Int(Double(body.count) * ratio))
                return keep < body.count ? String(body.prefix(keep)) : body
            }
            size = wire(assemble(bodies.enumerated().map { idx, b in
                b.count < sources[idx].whole.count && !b.isEmpty ? b + "\n…" : b
            }))
        }
        let finalBodies = bodies.enumerated().map { idx, b in
            b.count < sources[idx].whole.count && !b.isEmpty ? b + "\n…" : b
        }
        // Append native ACP image blocks after text trimming (graff accepts up to 64 MiB per line).
        return assemble(finalBodies) + imageBlocks
    }

    /// The page's words, as a reader would take them: its text, not its
    /// markup — and the tab's id as the browser's tools know it, so graff can
    /// act on the page it was shown.
    private static func read(_ tab: Tab) async -> (address: String, title: String, text: String, tab: String)? {
        guard let web = tab.built, let address = tab.address else { return nil }
        let title = tab.title
        var text: String = await withCheckedContinuation { done in
            web.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                done.resume(returning: (value as? String) ?? "")
            }
        }
        if YouTubeHelper.isYouTubeWatch(address) {
            let yt: String = await withCheckedContinuation { done in
                web.callAsyncJavaScript(
                    "return await \(YouTubeHelper.contextScript)",
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    done.resume(returning: (try? result.get() as? String) ?? "")
                }
            }
            if !yt.isEmpty {
                text = yt + "\n\n---\nPage text:\n" + text
            }
        }
        return (address.absoluteString, title, text, String(tab.id.uuidString.prefix(8)).lowercased())
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What graff runs in: the app's own environment with the PATH a
    /// Terminal would have — an app opened from the Dock gets the bare
    /// system one, and graff's shell wants the tools Terminal finds — graff's
    /// own folder first. It stays in the folder it is given rather than
    /// making itself a worktree, and nothing Claude Code left in the
    /// environment makes it think it is running inside that.
    nonisolated static func environment(for program: URL, path: String?, lean: Bool) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var folders: [String] = [program.deletingLastPathComponent().path]
        folders += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += (path ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let kept = folders.filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = kept.joined(separator: ":")
        environment["GRAFF_AUTO_ISOLATE"] = "0"
        // The browser's tools come ready to call, not folded away behind
        // graff's search for tools: in a browser they are the point.
        environment["GRAFF_MCP_EAGER"] = "browse"
        // Lean, unless Settings says otherwise: the browser's tools and
        // graff's own, not every MCP server the user's other apps name. Those
        // come up with every graff — a node REPL, code indexes — and took a
        // chat from ~40 MB to ~200 MB (25 Sep 2026). graff reads Search's
        // config (AgentTools.own) in place of its own, and leaves Claude's,
        // Cursor's and Codex's alone (GRAFF_NO_PLUGINS; honoured before MCP
        // starts from the graff after justrach/codegraff 0.0.302.4).
        if lean {
            environment["GRAFF_MCP_CONFIG"] = AgentTools.own.path
            environment["GRAFF_NO_PLUGINS"] = "1"
        }
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION"] {
            environment[key] = nil
        }
        return environment
    }

    /// Where graff is. The place Settings names, if it names one; otherwise
    /// the newest of every copy on the Mac — the installer's, Homebrew's,
    /// Harness's and the Codegraff app's, and any on the login shell's PATH —
    /// as Harness chooses. That shell's PATH comes back too, for graff's own
    /// commands.
    /// Locate an ACP agent binary on this Mac (`graff`, `agy`, `opencode`,
    /// `gemini`, or `pi-acp`), plus the user's login shell PATH.
    nonisolated static func locate(backend: Backend = .graff, customGraff: String = "") async -> (program: URL, path: String?)? {
        if backend == .graff {
            return await locate(custom: customGraff)
        }
        return await Task.detached {
            let shell = Agent.loginPath()
            guard let url = Agent.findExecutable(for: backend, shellPath: shell) else { return nil }
            return (url, shell)
        }.value
    }

    /// Discover all supported ACP agent backends currently installed on this Mac.
    nonisolated static func discoverBackends(customGraff: String = "") async -> [Backend] {
        await Task.detached {
            let files = FileManager.default
            let home = files.homeDirectoryForCurrentUser.path
            let shell = Agent.loginPath()
            var found: [Backend] = []
            for candidate in Backend.allCases {
                if candidate == .graff {
                    let named = (customGraff as NSString).expandingTildeInPath
                    if !named.isEmpty && files.isExecutableFile(atPath: named) {
                        found.append(.graff)
                        continue
                    }
                    let graffPlaces = (shell ?? "").split(separator: ":").map { "\($0)/graff" } + [
                        "\(home)/.local/bin/graff", "\(home)/bin/graff",
                        "/opt/homebrew/bin/graff", "/usr/local/bin/graff",
                        "\(home)/.harness/bin/graff",
                        "/Applications/Harness.app/Contents/Resources/bin/graff",
                        "/Applications/Codegraff.app/Contents/Resources/graff",
                    ]
                    if graffPlaces.contains(where: { files.isExecutableFile(atPath: $0) }) {
                        found.append(.graff)
                    }
                } else if Agent.findExecutable(for: candidate, shellPath: shell) != nil {
                    found.append(candidate)
                }
            }
            return found
        }.value
    }

    /// Synchronously resolves the executable for `backend` using a pre-probed
    /// login-shell `PATH` (called once per launch by `AgentEngine`).
    nonisolated static func resolveBinarySync(backend: Backend, customGraff: String, shellPath: String?) -> URL? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        if backend == .graff {
            let named = (customGraff as NSString).expandingTildeInPath
            if !named.isEmpty {
                return files.isExecutableFile(atPath: named) ? URL(fileURLWithPath: named) : nil
            }
            var places = (shellPath ?? "").split(separator: ":").map { "\($0)/graff" }
            places += [
                "\(home)/.local/bin/graff",
                "\(home)/bin/graff",
                "/opt/homebrew/bin/graff",
                "/usr/local/bin/graff",
                "\(home)/.harness/bin/graff",
                "/Applications/Harness.app/Contents/Resources/bin/graff",
                "/Applications/Codegraff.app/Contents/Resources/graff",
            ]
            var seen = Set<String>()
            var best: (url: URL, version: [Int])?
            for place in places where files.isExecutableFile(atPath: place) {
                let url = URL(fileURLWithPath: place)
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                let version = Agent.version(of: url)
                if let current = best, !Agent.newer(version, than: current.version) { continue }
                best = (url, version)
            }
            return best?.url
        }
        return findExecutable(for: backend, shellPath: shellPath)
    }

    nonisolated static func probeLoginPathOnce() -> String? {
        loginPath()
    }

    nonisolated private static func findExecutable(for backend: Backend, shellPath: String?) -> URL? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        let pathDirs = (shellPath ?? "").split(separator: ":").map(String.init)
        var places: [String] = []
        switch backend {
        case .graff:
            return nil
        case .antigravity:
            places = pathDirs.map { "\($0)/agy" } + [
                "\(home)/.local/bin/agy",
                "\(home)/bin/agy",
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy",
                "\(home)/.harness/bin/agy",
            ]
        case .opencode:
            places = pathDirs.map { "\($0)/opencode" } + [
                "\(home)/.opencode/bin/opencode",
                "\(home)/.local/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode",
            ]
        case .gemini:
            places = pathDirs.map { "\($0)/gemini" } + [
                "\(home)/.local/bin/gemini",
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini",
            ]
            if let versions = try? files.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
                for v in versions.sorted().reversed() {
                    places.append("\(home)/.nvm/versions/node/\(v)/bin/gemini")
                }
            }
        case .grok:
            places = pathDirs.map { "\($0)/grok" } + [
                "\(home)/.local/bin/grok",
                "\(home)/bin/grok",
                "/opt/homebrew/bin/grok",
                "/usr/local/bin/grok",
            ]
        case .devin:
            places = pathDirs.map { "\($0)/devin" } + [
                "\(home)/.local/bin/devin",
                "\(home)/bin/devin",
                "/opt/homebrew/bin/devin",
                "/usr/local/bin/devin",
            ]
        case .hermes:
            places = pathDirs.map { "\($0)/hermes" } + [
                "\(home)/.local/bin/hermes",
                "\(home)/.hermes/bin/hermes",
                "/opt/homebrew/bin/hermes",
                "/usr/local/bin/hermes",
            ]
        case .pi:
            places = pathDirs.map { "\($0)/pi-acp" } + [
                "\(home)/.local/bin/pi-acp",
                "/opt/homebrew/bin/pi-acp",
            ]
            let adaptersDir = "\(home)/.harness/adapters/pi-acp"
            if let versions = try? files.contentsOfDirectory(atPath: adaptersDir) {
                for v in versions.sorted().reversed() {
                    places.append("\(adaptersDir)/\(v)/node_modules/.bin/pi-acp")
                }
            }
        }
        for place in places where files.isExecutableFile(atPath: place) {
            return URL(fileURLWithPath: place)
        }
        return nil
    }

    nonisolated static func locate(custom: String) async -> (program: URL, path: String?)? {
        await Task.detached {
            let files = FileManager.default
            let home = files.homeDirectoryForCurrentUser.path
            let shell = Agent.loginPath()
            let named = (custom as NSString).expandingTildeInPath
            if !named.isEmpty {
                return files.isExecutableFile(atPath: named) ? (URL(fileURLWithPath: named), shell) : nil
            }
            var places = (shell ?? "").split(separator: ":").map { "\($0)/graff" }
            places += [
                "\(home)/.local/bin/graff",
                "\(home)/bin/graff",
                "/opt/homebrew/bin/graff",
                "/usr/local/bin/graff",
                "\(home)/.harness/bin/graff",
                "/Applications/Harness.app/Contents/Resources/bin/graff",
                "/Applications/Codegraff.app/Contents/Resources/graff",
            ]
            var seen = Set<String>()
            var best: (url: URL, version: [Int])?
            for place in places where files.isExecutableFile(atPath: place) {
                let url = URL(fileURLWithPath: place)
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                let version = Agent.version(of: url)
                if let current = best, !Agent.newer(version, than: current.version) { continue }
                best = (url, version)
            }
            return best.map { ($0.url, shell) }
        }.value
    }

    /// Part by part, a missing part counting as nought; a tie keeps the
    /// copy found first.
    nonisolated private static func newer(_ one: [Int], than other: [Int]) -> Bool {
        for index in 0..<max(one.count, other.count) {
            let a = index < one.count ? one[index] : 0
            let b = index < other.count ? other[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// `graff --version`, as numbers to compare part by part:
    /// "graff 0.0.302.4" is [0, 0, 302, 4]. Nothing, for one that won't say.
    nonisolated private static func version(of program: URL) -> [Int] {
        guard let said = run(program.path, ["--version"]) else { return [] }
        let word = said.split(whereSeparator: { $0 == " " || $0.isNewline })
            .first { $0.first?.isNumber == true || ($0.first == "v" && $0.dropFirst().first?.isNumber == true) }
        guard let word else { return [] }
        return word.drop { $0 == "v" }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// The PATH a login shell has — what Terminal would give graff.
    nonisolated private static func loginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let path = run(shell, ["-l", "-c", "printf %s \"$PATH\""])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    /// A short program's output, or nothing if it fails or takes too long —
    /// a shell profile that hangs doesn't hang the column with it.
    nonisolated private static func run(_ program: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// graff itself: one process, one JSON-RPC message a line each way.
///
/// Reading happens off the main thread and each whole line is handed over
/// on it; writing goes through a queue of its own, so a long page never
/// holds the window up waiting for graff to take it in.
final class AcpPipe: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writes = DispatchQueue(label: "search.agent.write")
    private let lock = NSLock()
    private var buffer = Data()
    /// The last of what graff wrote to stderr, for when it stops.
    private var said = Data()
    private var over = false

    var onMessage: (@MainActor ([String: Any]) -> Void)?
    var onExit: (@MainActor (Int32, String) -> Void)?

    var isRunning: Bool {
        lock.lock()
        let ended = over
        lock.unlock()
        return !ended && process.isRunning
    }

    /// graff reads a line into 64 KiB and stops listening at a longer one.
    static let longest = 65_000

    init(program: URL, arguments: [String], environment: [String: String], folder: URL) {
        process.executableURL = program
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = folder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.take(chunk)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.said.append(chunk)
            if self.said.count > 4096 { self.said = Data(self.said.suffix(4096)) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let status = process.terminationStatus
            // Whatever was still on its way arrives before the news that
            // graff ended.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.lock.lock()
                let words = String(decoding: self.said, as: UTF8.self)
                let ended = self.over
                self.lock.unlock()
                let why = AcpPipe.lastLines(words)
                DispatchQueue.main.async {
                    guard !ended else { return }
                    MainActor.assumeIsolated { self.onExit?(status, why) }
                }
            }
        }
        try process.run()
    }

    /// Its input closed first, so it saves the session and ends on its own;
    /// told to, if it hasn't after a moment.
    func stop() {
        lock.lock()
        over = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let handle = input.fileHandleForWriting
        let process = process
        writes.async {
            try? handle.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// False when the message is too long for graff to take.
    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        guard var line = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
              line.count < AcpPipe.longest
        else { return false }
        line.append(0x0A)
        let handle = input.fileHandleForWriting
        writes.async {
            try? handle.write(contentsOf: line)
        }
        return true
    }

    private func take(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<end))
            buffer.removeSubrange(buffer.startIndex...end)
        }
        let ended = over
        lock.unlock()
        guard !ended else { return }
        // Anything that isn't a JSON-RPC message is graff talking to itself.
        let messages = lines.compactMap { line -> [String: Any]? in
            guard !line.isEmpty,
                  let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  message["jsonrpc"] as? String == "2.0"
            else { return nil }
            return message
        }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                messages.forEach { self.onMessage?($0) }
            }
        }
    }

    /// The end of stderr, which is where a program says why it stopped.
    private static func lastLines(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: "\n")
    }
}
