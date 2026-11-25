import AppKit
import UniformTypeIdentifiers
import WebKit

/// User-facing page capture and export actions (Copy as Markdown, Save as PDF,
/// and viewport / full-page PNG screenshots).
extension Browser {
    func copyPageAsMarkdown() {
        guard let tab = active, !tab.isBlank, let web = tab.built else { return }
        let title = tab.label
        let address = tab.pageAddress?.absoluteString ?? ""
        web.evaluateJavaScript(AgentTools.markdownScript) { [weak self] value, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil {
                    self.announce("Couldn't extract page text")
                    return
                }
                let raw = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = raw.isEmpty ? "" : raw
                let header = address.isEmpty ? "# \(title)" : "# \(title)\n\n<\(address)>"
                let markdown = fallback.isEmpty ? header : "\(header)\n\n\(fallback)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                self.announce("Copied Markdown")
            }
        }
    }

    func savePageAsPDF() {
        guard let tab = active, !tab.isBlank, let web = tab.built else { return }
        let suggested = Self.exportFilename(for: tab.label, fallback: "page", ext: "pdf")
        let folder = prefs.downloads
        let hostWindow = web.window ?? Links.window ?? NSApp.keyWindow
        web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.presentExportPanel(
                        data: data,
                        type: .pdf,
                        filename: suggested,
                        directory: folder,
                        window: hostWindow,
                        announcement: "Saved PDF"
                    )
                case .failure:
                    self.announce("Couldn't create PDF")
                }
            }
        }
    }

    func captureScreenshot(fullPage: Bool, copyToClipboard: Bool) {
        guard let tab = active, !tab.isBlank, let web = tab.built else { return }
        let suggested = Self.exportFilename(
            for: tab.label,
            fallback: fullPage ? "full-page" : "screenshot",
            ext: "png"
        )
        let folder = prefs.downloads
        let hostWindow = web.window ?? Links.window ?? NSApp.keyWindow

        if fullPage {
            let measure = """
            (function () {
              var doc = document.documentElement, body = document.body;
              var w = Math.max(doc ? doc.scrollWidth : 0, body ? body.scrollWidth : 0, window.innerWidth || 0);
              var h = Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0, window.innerHeight || 0);
              return { w: Math.min(Math.max(w, 1), 4000), h: Math.min(Math.max(h, 1), 8000) };
            })()
            """
            web.evaluateJavaScript(measure) { [weak self, weak web] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let web else { return }
                    let config = WKSnapshotConfiguration()
                    config.afterScreenUpdates = true
                    if let dict = value as? [String: Any],
                       let w = dict["w"] as? Double,
                       let h = dict["h"] as? Double,
                       w > 0, h > 0 {
                        config.rect = CGRect(x: 0, y: 0, width: w, height: h)
                        config.snapshotWidth = NSNumber(value: min(w, 2400))
                    }
                    self.takeAndDeliverScreenshot(
                        on: web,
                        configuration: config,
                        copyToClipboard: copyToClipboard,
                        filename: suggested,
                        directory: folder,
                        window: hostWindow
                    )
                }
            }
        } else {
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            takeAndDeliverScreenshot(
                on: web,
                configuration: config,
                copyToClipboard: copyToClipboard,
                filename: suggested,
                directory: folder,
                window: hostWindow
            )
        }
    }

    private func takeAndDeliverScreenshot(
        on web: WKWebView,
        configuration: WKSnapshotConfiguration,
        copyToClipboard: Bool,
        filename: String,
        directory: URL,
        window: NSWindow?
    ) {
        web.takeSnapshot(with: configuration) { [weak self] image, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard error == nil, let image else {
                    self.announce("Couldn't capture screenshot")
                    return
                }
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.cgImage }
                guard let cg else {
                    self.announce("Couldn't encode screenshot")
                    return
                }
                Task { @MainActor [weak self] in
                    let pngData = await Self.encodePNGOffMain(cg)
                    guard let self else { return }
                    guard let pngData else {
                        self.announce("Couldn't encode screenshot")
                        return
                    }
                    if copyToClipboard {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setData(pngData, forType: .png)
                        if let tiff = image.tiffRepresentation {
                            pb.setData(tiff, forType: .tiff)
                        }
                        self.announce("Copied screenshot")
                    } else {
                        self.presentExportPanel(
                            data: pngData,
                            type: .png,
                            filename: filename,
                            directory: directory,
                            window: window,
                            announcement: "Saved screenshot"
                        )
                    }
                }
            }
        }
    }

    private func presentExportPanel(
        data: Data,
        type: UTType,
        filename: String,
        directory: URL,
        window: NSWindow?,
        announcement: String
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = filename
        panel.directoryURL = directory

        let saveHandler: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self.announce(announcement)
            } catch {
                self.announce("Couldn't save file")
            }
        }

        if let window {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { saveHandler(response) }
            }
        } else {
            saveHandler(panel.runModal())
        }
    }

    nonisolated private static func encodePNGOffMain(_ cg: CGImage) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }.value
    }

    private static func exportFilename(for rawTitle: String, fallback: String, ext: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\\n\r\t\0")
        let cleaned = rawTitle
            .components(separatedBy: disallowed)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? fallback : String(cleaned.prefix(80))
        return "\(base).\(ext)"
    }
}
