import Foundation
import Network
import WebKit

/// Parsed server entry from an extension's `chrome.proxy.settings` value.
struct ExtensionProxySpec: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int
    let excludedDomains: [String]
    let username: String?
    let password: String?
    let allowFailover: Bool
}

/// Resolved proxy mode for `chrome.proxy.settings`.
enum ExtensionProxyMode: Equatable, Sendable {
    case system
    case direct
    case fixed([ExtensionProxySpec])
    case unsupported(String)
}

/// Bridges `chrome.proxy.settings` onto WebKit's `WKWebsiteDataStore.proxyConfigurations`.
enum ExtensionProxy {
    @MainActor static private(set) var current: [ProxyConfiguration] = []
    @MainActor static private(set) var activeExtensionID: String?
    @MainActor private static var lastSynced: (id: String?, mode: ExtensionProxyMode, storeIDs: [ObjectIdentifier])?

    /// Normalizes Chrome `bypassList` entries into domain suffixes/hosts for `ProxyConfiguration.excludedDomains`.
    static func normalizeBypass(_ entries: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != "*", !seen.contains(value) else { return }
            seen.insert(value)
            out.append(value)
        }

        for raw in entries {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed == "<local>" {
                for local in ["localhost", "127.0.0.1", "::1", "*.local"] { add(local) }
                continue
            }
            var host = trimmed
            if let range = host.range(of: "://") {
                host = String(host[range.upperBound...])
            }
            if let slash = host.firstIndex(of: "/") {
                host = String(host[..<slash])
            }
            if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                let inner = String(host[host.index(after: host.startIndex)..<close])
                add(inner)
                continue
            }
            if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
                host = String(host[..<colon])
            }
            if host.hasPrefix("*.") {
                host = String(host.dropFirst())
            }
            add(host)
        }
        return out
    }

    /// Parses a Chrome `ProxyConfig` dictionary into an `ExtensionProxyMode`.
    static func parse(_ raw: [String: Any]) -> ExtensionProxyMode {
        let mode = (raw["mode"] as? String ?? "system").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mode {
        case "", "system", "auto_detect":
            return .system
        case "direct":
            return .direct
        case "pac_script":
            return .unsupported("PAC scripts are not supported by WebKit proxyConfigurations")
        case "fixed_servers":
            let rules = raw["rules"] as? [String: Any] ?? [:]
            let bypass = normalizeBypass(rules["bypassList"] as? [String] ?? [])

            if let single = rules["singleProxy"] as? [String: Any] {
                switch parseServer(single, excludedDomains: bypass, allowFailover: false) {
                case .success(let spec):
                    return .fixed([spec])
                case .failure(let err):
                    return .unsupported(err.message)
                }
            }

            var specs: [ExtensionProxySpec] = []
            var dedupe = Set<String>()
            let keys = ["proxyForHttps", "proxyForHttp", "fallbackProxy"]
            let candidates = keys.compactMap { rules[$0] as? [String: Any] }
            let failover = candidates.count > 1

            for server in candidates {
                switch parseServer(server, excludedDomains: bypass, allowFailover: failover) {
                case .success(let spec):
                    let sig = "\(spec.scheme)|\(spec.host.lowercased())|\(spec.port)"
                    if dedupe.insert(sig).inserted {
                        specs.append(spec)
                    }
                case .failure(let err):
                    return .unsupported(err.message)
                }
            }

            guard !specs.isEmpty else {
                return .unsupported("fixed_servers requires singleProxy, proxyForHttp, proxyForHttps, or fallbackProxy")
            }
            return .fixed(specs)
        default:
            return .unsupported("Unsupported proxy mode: \(mode)")
        }
    }

    private struct ParseError: Error {
        let message: String
    }

    private static func parseServer(
        _ server: [String: Any],
        excludedDomains: [String],
        allowFailover: Bool
    ) -> Result<ExtensionProxySpec, ParseError> {
        let host = (server["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return .failure(ParseError(message: "Proxy server host cannot be empty"))
        }

        let rawScheme = (server["scheme"] as? String ?? "http").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scheme: String
        switch rawScheme {
        case "", "http":
            scheme = "http"
        case "https":
            scheme = "https"
        case "socks", "socks5":
            scheme = "socks5"
        default:
            return .failure(ParseError(message: "Unsupported proxy scheme: \(rawScheme)"))
        }

        let port: Int
        if let rawPort = server["port"] {
            if let intPort = rawPort as? Int {
                port = intPort
            } else if let doublePort = rawPort as? Double, doublePort.rounded() == doublePort {
                port = Int(doublePort)
            } else if let strPort = rawPort as? String, let parsed = Int(strPort) {
                port = parsed
            } else {
                return .failure(ParseError(message: "Invalid proxy port"))
            }
            guard (1...65535).contains(port) else {
                return .failure(ParseError(message: "Proxy port out of range: \(port)"))
            }
        } else {
            switch scheme {
            case "https": port = 443
            case "socks5": port = 1080
            default: port = 80
            }
        }

        let user = (server["username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pass = server["password"] as? String
        return .success(ExtensionProxySpec(
            scheme: scheme,
            host: host,
            port: port,
            excludedDomains: excludedDomains,
            username: user,
            password: pass,
            allowFailover: allowFailover
        ))
    }

    /// Converts parsed proxy specs into Network framework `ProxyConfiguration` entries.
    static func makeConfigurations(_ specs: [ExtensionProxySpec]) -> [ProxyConfiguration] {
        specs.compactMap { spec in
            guard (1...65535).contains(spec.port),
                  let port = NWEndpoint.Port(rawValue: UInt16(spec.port))
            else { return nil }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(spec.host), port: port)
            var config: ProxyConfiguration
            switch spec.scheme {
            case "https":
                config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
            case "socks5":
                config = ProxyConfiguration(socksv5Proxy: endpoint)
            default:
                config = ProxyConfiguration(httpCONNECTProxy: endpoint)
            }
            if !spec.excludedDomains.isEmpty {
                config.excludedDomains = spec.excludedDomains
            }
            config.allowFailover = spec.allowFailover
            if let username = spec.username, !username.isEmpty {
                config.applyCredential(username: username, password: spec.password ?? "")
            }
            return config
        }
    }

    /// Applies the active proxy configurations to the supplied WebKit website stores.
    @MainActor
    static func apply(to stores: [WKWebsiteDataStore]) {
        for store in stores {
            store.proxyConfigurations = current
        }
    }

    /// Resolves the highest-precedence enabled extension's `proxy.settings` and applies it across Space stores.
    #if !EXTENSION_PROXY_STANDALONE
    @available(macOS 15.4, *)
    @MainActor
    @discardableResult
    static func sync(owner: Extensions) -> (id: String, issue: String)? {
        var targetID: String?
        var targetMode: ExtensionProxyMode = .system
        var problem: (id: String, issue: String)?
        for item in owner.installed.reversed() where item.enabled {
            let settings = Extensions.settings(for: item.id)
            guard let raw = settings["proxy.settings"] as? [String: Any] else { continue }
            let parsed = parse(raw)
            switch parsed {
            case .system, .direct, .fixed:
                targetID = item.id
                targetMode = parsed
            case .unsupported(let reason):
                targetID = nil
                targetMode = .system
                problem = (item.id, reason)
            }
            break
        }
        let stores = Spaces.everyStore
        let storeIDs = stores.map(ObjectIdentifier.init)
        if let lastSynced,
           lastSynced.id == targetID,
           lastSynced.mode == targetMode,
           lastSynced.storeIDs == storeIDs {
            return problem
        }
        activeExtensionID = targetID
        if case .fixed(let specs) = targetMode {
            current = makeConfigurations(specs)
        } else {
            current = []
        }
        apply(to: stores)
        lastSynced = (targetID, targetMode, storeIDs)
        return problem
    }
    #endif
}
