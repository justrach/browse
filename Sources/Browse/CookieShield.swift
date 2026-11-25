import CryptoKit
import Foundation

/// Curated WebKit `WKContentRuleList` spec for blocking common cookie consent
/// managers and banners at the network + exact-selector CSS layer with zero
/// runtime page JavaScript and zero unindexed attribute/wildcard selectors.
enum CookieShield {
    struct Spec {
        let identifier: String
        let json: String
    }

    /// Common third-party consent management platform (CMP) script origins.
    /// Scoped strictly to `third-party` loads so visiting a vendor's own site
    /// directly continues to work cleanly.
    static let thirdPartyPatterns: [String] = [
        "^https?://([^/]+\\.)?cdn\\.cookielaw\\.org",
        "^https?://([^/]+\\.)?geolocation\\.onetrust\\.com",
        "^https?://([^/]+\\.)?consent\\.cookiebot\\.com",
        "^https?://([^/]+\\.)?consentcdn\\.cookiebot\\.com",
        "^https?://([^/]+\\.)?cmp\\.quantcast\\.com",
        "^https?://([^/]+\\.)?sdk\\.privacy-center\\.org",
        "^https?://([^/]+\\.)?consent\\.trustarc\\.com",
        "^https?://([^/]+\\.)?app\\.usercentrics\\.eu",
        "^https?://([^/]+\\.)?cmp\\.osano\\.com",
        "^https?://([^/]+\\.)?cdn-cookieyes\\.com",
        "^https?://([^/]+\\.)?cdn\\.iubenda\\.com/cs/",
        "^https?://([^/]+\\.)?app\\.termly\\.io/embed\\.min\\.js",
    ]

    /// Exact ID and class selectors for well-known cookie banners and backdrops.
    /// Deliberately excludes attribute substring matchers so WebKit's CSS style
    /// resolver stays on its fast O(1) hash path.
    static let cosmeticSelectors: [String] = [
        "#onetrust-banner-sdk",
        "#onetrust-consent-sdk",
        "#onetrust-pc-sdk",
        ".onetrust-pc-dark-filter",
        "#CybotCookiebotDialog",
        "#CybotCookiebotDialogBodyUnderlay",
        "#qc-cmp2-container",
        "#didomi-host",
        ".didomi-popup-container",
        ".didomi-popup-backdrop",
        "#usercentrics-root",
        "#truste-consent-track",
        "#cookie-law-info-bar",
        ".cky-consent-container",
        ".cky-overlay",
        "#cmplz-cookiebanner-container",
        ".osano-cm-window",
        ".cc-window",
        "#iubenda-cs-banner",
        "#klaro",
    ]

    static let spec: Spec? = {
        var rules: [[String: Any]] = thirdPartyPatterns.map { pattern in
            [
                "trigger": [
                    "url-filter": pattern,
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": cosmeticSelectors.joined(separator: ", "),
            ],
        ])
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        return Spec(identifier: "office-cookies-\(digest)", json: json)
    }()
}
