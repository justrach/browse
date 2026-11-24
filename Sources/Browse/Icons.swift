import ImageIO
import SwiftUI
import WebKit

// A site's own icon, for the tabs that are set to wear one.
//
// WebKit doesn't hand these over, so the page is asked what it declares and
// the best of those is fetched once and kept as a small PNG next to the
// history. A tab brought back from yesterday's session has its icon before it
// has a page; a tab on a site never seen before shows a letter until the icon
// arrives, which is a second or so.

@MainActor
final class Favicons {
    static let shared = Favicons()

    /// Called with a host and its icon whenever one arrives, so every tab on
    /// that host can put it on at once.
    var arrived: ((String, NSImage) -> Void)?

    private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
    private var busy: Set<String> = []
    private var missing: Set<String> = []
    /// Keys with no file on disk or unreadable images, as far as `known` has looked.
    private var absent: Set<String> = []
    /// In-memory directory & mtime index populated asynchronously at startup so
    /// `cached(_:)` and `fresh(_:)` avoid blocking `stat`/`NSImage` calls on misses.
    private var fileMtimes: [String: Date] = [:]
    private var indexLoaded = false
    private var indexGeneration = 0
    private var deferredWarm: Set<String> = []
    /// Hosts confirmed during this session to declare no `prefers-color-scheme: dark` icon.
    private var noDarkHosts: Set<String> = []

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    private init() {
        loadIndex()
    }

    private func loadIndex() {
        let gen = indexGeneration
        let dir = Favicons.folder
        Task.detached(priority: .utility) { [weak self] in
            var scanned: [String: Date] = [:]
            if let urls = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for url in urls where url.pathExtension == "png" {
                    let stem = url.deletingPathExtension().lastPathComponent
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    scanned[stem] = mtime
                }
            }
            let result = scanned
            await MainActor.run { [weak self] in
                guard let self, self.indexGeneration == gen else { return }
                for (stem, mtime) in result where self.fileMtimes[stem] == nil {
                    self.fileMtimes[stem] = mtime
                }
                self.indexLoaded = true
                self.warmDeferred()
            }
        }
    }

    private func warmDeferred() {
        let hosts = deferredWarm
        deferredWarm.removeAll()
        guard !hosts.isEmpty else { return }
        let dark = Favicons.dark
        var targets: [(host: String, key: String, file: URL)] = []
        for host in hosts {
            let candidates = host.hasPrefix("www.")
                ? [host, String(host.dropFirst(4))]
                : [host, "www." + host]
            var matchedKey: String?
            for base in candidates {
                if dark, fileMtimes[Favicons.key(base, dark: true)] != nil {
                    matchedKey = Favicons.key(base, dark: true)
                    break
                }
                if fileMtimes[base] != nil {
                    matchedKey = base
                    break
                }
            }
            if let matchedKey, memory.object(forKey: matchedKey as NSString) == nil {
                targets.append((host, matchedKey, Favicons.file(matchedKey)))
            }
        }
        guard !targets.isEmpty else { return }
        let gen = indexGeneration
        Task.detached(priority: .utility) { [weak self] in
            var loaded: [(host: String, key: String, cg: CGImage)] = []
            for target in targets {
                guard let src = CGImageSourceCreateWithURL(target.file as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
                else { continue }
                loaded.append((target.host, target.key, cg))
            }
            guard !loaded.isEmpty else { return }
            let decoded = loaded
            await MainActor.run { [weak self] in
                guard let self, self.indexGeneration == gen else { return }
                for item in decoded {
                    let image = NSImage(cgImage: item.cg, size: NSSize(width: 64, height: 64))
                    self.memory.setObject(image, forKey: item.key as NSString)
                    self.arrived?(item.host, image)
                }
            }
        }
    }

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }

    /// Clear History: every icon kept on disk goes. The tabs open now keep
    /// theirs until they are closed.
    func forgetAll() {
        try? FileManager.default.removeItem(at: Favicons.folder)
        indexGeneration &+= 1
        memory.removeAllObjects()
        fileMtimes.removeAll()
        deferredWarm.removeAll()
        noDarkHosts.removeAll()
        missing.removeAll()
        absent.removeAll()
    }

    /// Release decoded favicon bitmaps under memory pressure.
    func trim() {
        memory.removeAllObjects()
    }
    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

    /// Whether the chrome is dark right now. A site that declares an icon
    /// for `prefers-color-scheme: dark` is asked for that one, and it is
    /// kept apart from the light one, so switching looks switches icons.
    static var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The name an icon is kept under: the host, with a suffix for the dark
    /// variant a site offered. Sites without one keep one file for both.
    private static func key(_ host: String, dark: Bool) -> String { dark ? host + "@dark" : host }

    /// What is already known, and nothing fetched. In the dark, the dark
    /// variant when there is one, the ordinary icon otherwise.
    func cached(_ host: String) -> NSImage? {
        let normalized = host.lowercased()
        if let hit = match(normalized, warmHost: normalized) { return hit }
        if normalized.hasPrefix("www.") {
            let bare = String(normalized.dropFirst(4))
            if let hit = match(bare, warmHost: normalized) { return hit }
        } else {
            let www = "www." + normalized
            if let hit = match(www, warmHost: normalized) { return hit }
        }
        return nil
    }

    private func match(_ key: String, warmHost: String? = nil) -> NSImage? {
        if Favicons.dark, let hit = known(Favicons.key(key, dark: true), warmHost: warmHost) { return hit }
        return known(key, warmHost: warmHost)
    }

    private func known(_ key: String, warmHost: String? = nil) -> NSImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if absent.contains(key) { return nil }
        if !indexLoaded {
            if let warmHost { deferredWarm.insert(warmHost) }
            return nil
        }
        // Only read from disk when the preloaded directory index confirms a file exists.
        guard fileMtimes[key] != nil else { return nil }
        guard let image = NSImage(contentsOf: Favicons.file(key)) else {
            absent.insert(key)
            return nil
        }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    private func fresh(_ key: String) -> Bool {
        if indexLoaded {
            guard let stamp = fileMtimes[key] else { return false }
            return Date().timeIntervalSince(stamp) < 7 * 86_400
        }
        guard let stamp = try? Favicons.file(key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(stamp) < 7 * 86_400
    }

    /// The look changed: every tab puts on the icon that goes with it, and
    /// asks again for one where the site may have a variant not yet seen.
    func relook(_ tabs: [Tab]) {
        missing = []
        for tab in tabs {
            guard let host = tab.address?.host()?.lowercased() else { continue }
            tab.icon = cached(host)
            fetch(for: tab)
        }
    }

    /// An icon from somewhere else — another browser's cache, at import —
    /// kept as if the site had handed it over, unless one is already here.
    func adopt(_ data: Data, for host: String) async {
        guard cached(host) == nil, let image = await Favicons.square(data) else { return }
        memory.setObject(image, forKey: host as NSString)
        keep(image, for: host)
        arrived?(host, image)
    }

    /// A site's icon with no page of it open — the search engine's, for the
    /// rows under the address field: its /favicon.ico, asked once a session,
    /// and nothing if one is already kept.
    func fetch(host: String) {
        let host = host.lowercased()
        guard cached(host) == nil, !busy.contains(host), !missing.contains(host),
              let url = URL(string: "https://\(host)/favicon.ico") else { return }
        busy.insert(host)
        Task { await download([url], host: host, key: host, shy: false) }
    }

    /// Asks the page which icon it wants to be known by, fetches it, and keeps
    /// it. Nothing happens if a fresh one is already on disk.
    func fetch(for tab: Tab) {
        guard let url = tab.address, let host = url.host()?.lowercased(),
              url.scheme?.hasPrefix("http") == true
        else { return }

        let dark = Favicons.dark
        if dark && noDarkHosts.contains(host), fresh(host), let known = known(host) {
            if tab.address?.host()?.lowercased() == host { tab.icon = known }
            return
        }
        // Fresh and right for this look: nothing to do. In the dark, a fresh
        // light icon is not enough on its own — the site may offer a dark
        // one that has never been asked for — so the page is asked.
        if fresh(Favicons.key(host, dark: dark)), let known = known(Favicons.key(host, dark: dark)) {
            if tab.address?.host()?.lowercased() == host { tab.icon = known }
            return
        }
        guard !busy.contains(host), !missing.contains(host) else { return }
        busy.insert(host)

        let shy = tab.shy
        tab.web.evaluateJavaScript(Favicons.probe) { [weak self] answer, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let result = answer as? [String: Any]
                let documentURL = (result?["url"] as? String).flatMap { URL(string: $0) }
                // Navigation can replace the document before WebKit runs the probe.
                guard error != nil || documentURL == url else {
                    self.busy.remove(host)
                    return
                }
                let declared = (result?["icons"] as? [[String: String]]) ?? []
                let offersDark = declared.contains { Favicons.media($0["media"]) == .dark }
                let wantDark = dark && offersDark
                if dark && !offersDark {
                    self.noDarkHosts.insert(host)
                }
                let key = Favicons.key(host, dark: wantDark)
                // No dark variant here after all, and the ordinary one is
                // fresh: it is the one to wear.
                if !wantDark, self.fresh(key), let known = self.known(key) {
                    if tab.address?.host()?.lowercased() == host {
                        tab.icon = known
                    }
                    self.busy.remove(host)
                    return
                }
                let candidates = Favicons.rank(declared, page: url, dark: wantDark)
                Task { await self.download(candidates, host: host, key: key, shy: shy) }
            }
        }
    }

    private enum Scheme { case any, light, dark }

    /// What a `media` attribute says about the scheme, if anything.
    private static func media(_ value: String?) -> Scheme {
        let text = (value ?? "").lowercased()
        if text.contains("prefers-color-scheme") {
            if text.contains("dark") { return .dark }
            if text.contains("light") { return .light }
        }
        return .any
    }

    private func download(_ candidates: [URL], host: String, key: String, shy: Bool) async {
        defer { busy.remove(host) }
        for candidate in candidates {
            guard let (data, response) = try? await Favicons.session.data(from: candidate),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 2_000_000
            else { continue }
            guard let image = await Favicons.square(data) else { continue }
            memory.setObject(image, forKey: key as NSString)
            if !shy { keep(image, for: key) }
            arrived?(host, image)
            return
        }
        // Not asked again this session: hammering a site for an icon it
        // doesn't have is exactly the kind of thing a quiet browser doesn't do.
        missing.insert(host)
    }

    /// Decoded and drawn into a square off the main thread — an .ico can hold
    /// a dozen sizes and take a moment to unpack.
    private static func square(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let image = NSImage(data: data), image.isValid,
                  image.size.width > 0, image.size.height > 0
            else { return nil }
            let side: CGFloat = 64
            let out = NSImage(size: NSSize(width: side, height: side))
            out.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            let scale = min(side / image.size.width, side / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(
                in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            out.unlockFocus()
            return out
        }.value
    }

    private func keep(_ image: NSImage, for key: String) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        fileMtimes[key] = Date()
        absent.remove(key)
        let file = Favicons.file(key)
        let dir = Favicons.folder
        DispatchQueue.global(qos: .utility).async {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? (data as Data).write(to: file, options: .atomic)
        }
    }

    /// Best first. A crisp icon around 32–64 pixels is what a tab wants; the
    /// touch icon is a fine second; the file at the root is the fallback every
    /// site has had since 1999.
    private static func rank(_ declared: [[String: String]], page: URL, dark: Bool) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            guard let href = entry["href"],
                  let url = URL(string: href, relativeTo: page)?.absoluteURL,
                  url.scheme?.hasPrefix("http") == true
            else { continue }
            let rel = entry["rel"] ?? ""
            let sizes = entry["sizes"] ?? ""
            let type = entry["type"] ?? ""
            // An icon meant for the other scheme is the last resort; one
            // meant for this scheme comes first whatever its size.
            let scheme = media(entry["media"])
            if scheme == (dark ? .light : .dark) { continue }
            var score = 25
            if rel.contains("apple-touch") { score = 40 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 45
                case 48..<128: score = 50
                case 128..<260: score = 42
                default: score = 20
                }
            }
            if sizes == "any" || type.contains("svg") || url.pathExtension.lowercased() == "svg" { score = 35 }
            if scheme != .any { score += 40 }
            scored.append((url, score))
        }
        var list = scored.sorted { $0.1 > $1.1 }.map(\.0)
        if let host = page.host(), let root = URL(string: "\(page.scheme ?? "https")://\(host)/favicon.ico") {
            list.append(root)
        }
        // The same address twice is a wasted request.
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    private static let probe = """
    (function () {
      var out = [];
      var links = document.querySelectorAll('link[rel]');
      for (var i = 0; i < links.length; i++) {
        var l = links[i];
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) continue;
        out.push({
          href: l.href,
          rel: rel,
          sizes: (l.getAttribute('sizes') || '').toLowerCase(),
          type: (l.getAttribute('type') || '').toLowerCase(),
          media: (l.getAttribute('media') || '').toLowerCase()
        });
      }
      return { url: document.URL, icons: out };
    })();
    """
}

/// What stands for a page when there is no room for its title: the site's
/// icon if there is one, and a letter in a faint square until there is.
struct Mark: View {
    let icon: NSImage?
    let letter: String
    var size: CGFloat = 16
    var dim = false

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Palette.ink.opacity(0.06))
                    )
            }
        }
        .opacity(dim ? 0.45 : 1)
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}
