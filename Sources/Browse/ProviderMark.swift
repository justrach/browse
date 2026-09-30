import AppKit
import SwiftUI

/// Bundled provider glyphs, kept small like the Harness Swift pickers.
/// A router keeps its own mark; the model maker is labelled separately.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 14

    private var asset: String? {
        Self.assets[provider.lowercased()]
    }

    private static let assets = [
        "openai": "openai", "codex": "openai", "anthropic": "claude",
        "xai": "grok", "x-ai": "grok", "deepseek": "deepseek",
        "kimi": "kimi", "moonshotai": "moonshot", "moonshot": "moonshot",
        "openrouter": "openrouter", "google": "gemini", "gemini": "gemini",
        "qwen": "qwen", "mistralai": "mistral", "mistral": "mistral",
        "minimax": "minimax", "cohere": "cohere", "meta-llama": "meta",
        "meta": "meta", "ollama": "ollama", "lmstudio": "lmstudio",
        "z-ai": "zai", "zai": "zai", "cerebras": "cerebras",
        "nvidia": "nvidia", "microsoft": "microsoft", "amazon": "aws",
        "aws": "aws", "perplexity": "perplexity", "baidu": "baidu",
        "bytedance": "bytedance", "ibm-granite": "ibm", "ibm": "ibm",
    ]

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
                    .foregroundStyle(asset == "claude" ? Color(red: 0.85, green: 0.47, blue: 0.34) : Palette.ink.opacity(0.8))
            } else {
                // Custom providers remain recognizable without borrowing a
                // different provider's logo. The full name stays in the row.
                Text(String(provider.prefix(1)).uppercased())
                    .font(.system(size: size * 0.65, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
