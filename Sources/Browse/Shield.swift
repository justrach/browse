import WebKit

// The ad blocker. No settings, no counter, no shield icon going green — it is
// compiled once and then it is simply true that the page is lighter.
//
// A content rule list is enforced inside WebKit's networking, before a request
// is made and before a stylesheet is applied, so this costs nothing at run time
// in the way a JavaScript blocker does.
//
// Three lists. A short one of our own, compiled at every launch in a moment,
// so blocking starts with the first page. Then EasyList and EasyPrivacy, as
// ./shield-lists converts them and the app carries them (Resources/Shield): one
// list of what's never fetched, one of what's hidden. Those are 130,000 rules,
// a few seconds to compile, so WebKit keeps the compiled copy and only a new
// set of lists — a new release — is compiled again, in the background, with
// the short list standing in until it's done.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    /// What's compiled so far, in the order it arrived.
    private(set) var lists: [WKContentRuleList] = []

    /// Every page's controller, with the site it's on (empty until it's
    /// going somewhere), so a list that arrives late reaches the pages open
    /// already — except on the sites it's paused for.
    private let controllers = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()

    /// Set the one time compiling our own list didn't work. The toggle in
    /// Settings can say "on" all it wants; nothing is actually blocked until
    /// this is nil, so it is the one thing worth telling a person about
    /// rather than failing the quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    var enabled = true

    /// Sites it is off for — the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
    }

    /// Before each page: the lists go on or off for the site this tab is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation is what makes "off for this site" true
    /// for the whole page rather than for the second half of it.
    func tune(_ controller: WKUserContentController, for host: String?) {
        controllers.setObject((host ?? "") as NSString, forKey: controller)
        lists.forEach { controller.remove($0) }
        if enabled, !isPaused(on: host) { lists.forEach { controller.add($0) } }
    }

    /// Third parties whose only job is to watch or to sell. First-party
    /// requests are untouched: a site's own scripts are the site.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]

    /// The few slots that are reliably an advertisement and nothing else. Kept
    /// deliberately short — a generous cosmetic list is how a blocker starts
    /// eating the page it was meant to clean.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
    ]

    private var compiling = false

    func compile() {
        guard lists.isEmpty, !compiling else { return }
        compiling = true
        trouble = nil
        var rules: [[String: Any]] = Shield.unwanted.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?\(escaped)",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Shield.slots.joined(separator: ", ")],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else {
            compiling = false
            trouble = "Couldn't build the block list"
            return
        }

        guard let store = WKContentRuleListStore.default() else {
            compiling = false
            trouble = "WebKit has nowhere to compile it"
            return
        }
        store.compileContentRuleList(
            forIdentifier: "office-shield",
            encodedContentRuleList: json
        ) { [weak self] compiled, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.compiling = false
                guard let compiled else {
                    self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                    return
                }
                self.arrived(compiled)
                self.bring(store)
            }
        }
    }

    // MARK: - EasyList and EasyPrivacy

    /// Where ./shield-lists put them: in the app, or beside the source for a
    /// `swift build` run.
    private nonisolated static var folder: URL? {
        if let bundled = Bundle.main.url(forResource: "Shield", withExtension: nil) { return bundled }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Assets/Shield", isDirectory: true)
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// Each of the carried lists: the compiled copy if this set was
    /// compiled before, else compiled now, off to one side. Copies of older
    /// sets are thrown away once this one is in.
    private func bring(_ store: WKContentRuleListStore) {
        guard let folder = Shield.folder,
              let version = try? String(contentsOf: folder.appendingPathComponent("version"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty
        else { return }
        let wanted = ["network", "cosmetic"].map { ($0, "shield-\($0)-\(version)") }

        store.getAvailableContentRuleListIdentifiers { kept in
            for old in kept ?? [] where old.hasPrefix("shield-") && !wanted.contains(where: { $0.1 == old }) {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
        for (name, identifier) in wanted {
            store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] found, _ in
                MainActor.assumeIsolated {
                    if let found {
                        self?.arrived(found)
                        return
                    }
                    let file = folder.appendingPathComponent("\(name).json.xz")
                    Task.detached(priority: .utility) {
                        guard let packed = try? Data(contentsOf: file),
                              let json = try? (packed as NSData).decompressed(using: .lzma) as Data,
                              let text = String(data: json, encoding: .utf8)
                        else {
                            NSLog("shield: couldn't open \(file.lastPathComponent)")
                            return
                        }
                        await MainActor.run {
                            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: text) { [weak self] compiled, error in
                                MainActor.assumeIsolated {
                                    guard let compiled else {
                                        NSLog("shield: \(name) didn't compile: \(error?.localizedDescription ?? "no reason given")")
                                        return
                                    }
                                    self?.arrived(compiled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A list ready: on every page already open that wants blocking.
    private func arrived(_ list: WKContentRuleList) {
        lists.append(list)
        guard enabled else { return }
        for controller in controllers.keyEnumerator().allObjects as? [WKUserContentController] ?? [] {
            let host = controllers.object(forKey: controller) as String?
            if !isPaused(on: host?.isEmpty == false ? host : nil) { controller.add(list) }
        }
    }

    /// Every tab asks for it; whoever asks before it is ready gets it as
    /// each list arrives.
    func protect(_ controller: WKUserContentController) {
        controllers.setObject("", forKey: controller)
        if enabled { lists.forEach { controller.add($0) } }
    }

    /// Switched on or off for every page that is already open.
    func apply(to controllers: [WKUserContentController]) {
        for controller in controllers {
            let host = self.controllers.object(forKey: controller) as String?
            lists.forEach { controller.remove($0) }
            if enabled, !isPaused(on: host?.isEmpty == false ? host : nil) { lists.forEach { controller.add($0) } }
        }
    }
}
