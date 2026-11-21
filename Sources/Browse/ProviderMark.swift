import AppKit
import SwiftUI

/// Bundled provider & maker glyphs + brand accents, 1:1 with NanoHarness
/// (`model_picker.zig` `providerInfo` / `makerIcon` / `brandHex`).
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 14
    var tinted = true

    private var key: String { provider.lowercased() }

    private var asset: String? {
        Self.assets[key]
    }

    private static let assets = [
        "openai": "openai", "codex": "openai", "chatgpt-new": "openai",
        "anthropic": "claude", "claude-agent": "claude", "claude": "claude",
        "xai": "grok", "x-ai": "grok", "grok": "grok",
        "deepseek": "deepseek",
        "kimi": "kimi", "moonshotai": "moonshot", "moonshot": "moonshot",
        "openrouter": "openrouter",
        "google": "gemini", "gemini": "gemini",
        "qwen": "qwen", "alibaba": "qwen",
        "mistralai": "mistral", "mistral": "mistral",
        "minimax": "minimax", "cohere": "cohere",
        "meta-llama": "meta", "meta": "meta",
        "ollama": "ollama", "lmstudio": "lmstudio",
        "z-ai": "zai", "zai": "zai",
        "cerebras": "cerebras", "nvidia": "nvidia",
        "microsoft": "microsoft", "amazon": "aws", "aws": "aws",
        "perplexity": "perplexity", "baidu": "baidu",
        "bytedance": "bytedance", "ibm-granite": "ibm", "ibm": "ibm",
    ]

    /// Brand accent colour for the reasoning slider and effort badge, 1:1 with
    /// NanoHarness `model_picker.zig:brandHex` + light-surface contrast clamp.
    static func brandAccent(for rawKey: String, dark: Bool) -> Color {
        let hex: UInt32?
        switch rawKey.lowercased() {
        case "openai", "codex", "chatgpt-new": hex = dark ? 0x66b5ff : 0x2563eb
        case "anthropic", "claude-agent", "claude": hex = 0xd97757
        case "moonshot", "moonshotai", "kimi": hex = dark ? 0x00a1ff : 0x007cff
        case "deepseek": hex = 0x3964fe
        case "google", "gemini": hex = 0x3186ff
        case "minimax": hex = 0x1887fb
        case "xiaomi": hex = 0xff6900
        case "mistral", "mistralai": hex = 0xff5229
        case "codegraff": hex = 0x0285ff
        case "groq": hex = 0xf43e01
        case "cerebras": hex = 0xf15a27
        case "kilo": hex = 0xffdd00
        case "openrouter": hex = 0x6467f2
        case "fugu": hex = 0xe10600
        case "fireworks": hex = dark ? 0xffc0e7 : 0x7a155c
        case "lmstudio": hex = dark ? 0x7b74db : 0x4338ca
        case "xai", "x-ai", "grok": hex = dark ? 0xffffff : 0x111111
        case "zai", "z-ai": hex = dark ? 0xb4b4b4 : 0x4d4d4d
        default: hex = nil
        }
        guard let hex else { return Palette.accent }
        return Color(
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0
        )
    }

    /// Read each asset once, including when a long model list scrolls.
    private static let images: [String: NSImage] = {
        var out: [String: NSImage] = [:]
        for name in Set(assets.values) {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderMarks"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = true
            out[name] = image
        }
        return out
    }()

    var body: some View {
        Group {
            if let asset, let image = Self.images[asset] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tinted && asset == "claude" ? Color(red: 0.85, green: 0.47, blue: 0.34) : Palette.ink.opacity(0.82))
            } else if key == "codegraff" {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.82, weight: .semibold))
                    .foregroundStyle(tinted ? Color(red: 0.01, green: 0.52, blue: 1.0) : Palette.ink.opacity(0.82))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.82, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
