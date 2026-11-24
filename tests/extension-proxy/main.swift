import Foundation

@main
struct ExtensionProxyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        check(ExtensionProxy.parse(["mode": "system"]) == .system, "system mode")
        check(ExtensionProxy.parse(["mode": "auto_detect"]) == .system, "auto_detect maps to system")
        check(ExtensionProxy.parse(["mode": "direct"]) == .direct, "direct mode")

        let bypass = ExtensionProxy.normalizeBypass(["<local>", "*.example.com", "*://sub.test.org:8080/path", "[::1]:9000", "*"])
        check(
            bypass == ["localhost", "127.0.0.1", "::1", "*.local", ".example.com", "sub.test.org"],
            "normalizeBypass produced \(bypass)"
        )

        let single = ExtensionProxy.parse([
            "mode": "fixed_servers",
            "rules": [
                "singleProxy": [
                    "scheme": "https",
                    "host": "proxy.example.com",
                    "port": 8443,
                    "username": "alice",
                    "password": "secret",
                ],
                "bypassList": ["<local>", "*.internal.example"],
            ],
        ])
        check(
            single == .fixed([
                ExtensionProxySpec(
                    scheme: "https",
                    host: "proxy.example.com",
                    port: 8443,
                    excludedDomains: ["localhost", "127.0.0.1", "::1", "*.local", ".internal.example"],
                    username: "alice",
                    password: "secret",
                    allowFailover: false
                )
            ]),
            "singleProxy parse mismatch: \(single)"
        )

        let multi = ExtensionProxy.parse([
            "mode": "fixed_servers",
            "rules": [
                "proxyForHttp": ["host": "http.local"],
                "proxyForHttps": ["scheme": "socks5", "host": "socks.local", "port": 9050],
                "fallbackProxy": ["scheme": "http", "host": "http.local", "port": 80],
            ],
        ])
        check(
            multi == .fixed([
                ExtensionProxySpec(
                    scheme: "socks5",
                    host: "socks.local",
                    port: 9050,
                    excludedDomains: [],
                    username: nil,
                    password: nil,
                    allowFailover: true
                ),
                ExtensionProxySpec(
                    scheme: "http",
                    host: "http.local",
                    port: 80,
                    excludedDomains: [],
                    username: nil,
                    password: nil,
                    allowFailover: true
                ),
            ]),
            "multi-scheme proxy parse mismatch: \(multi)"
        )

        if case .fixed(let specs) = multi {
            let configs = ExtensionProxy.makeConfigurations(specs)
            check(configs.count == 2, "expected 2 ProxyConfigurations, got \(configs.count)")
        } else {
            check(false, "expected .fixed multi")
        }

        if case .unsupported = ExtensionProxy.parse(["mode": "pac_script"]) {
            // expected
        } else {
            check(false, "expected pac_script to return .unsupported")
        }

        if case .unsupported = ExtensionProxy.parse([
            "mode": "fixed_servers",
            "rules": ["singleProxy": ["scheme": "socks4", "host": "127.0.0.1", "port": 1080]],
        ]) {
            // expected
        } else {
            check(false, "expected socks4 to return .unsupported")
        }

        if case .unsupported = ExtensionProxy.parse([
            "mode": "fixed_servers",
            "rules": ["singleProxy": ["host": "", "port": 8080]],
        ]) {
            // expected
        } else {
            check(false, "expected empty host to return .unsupported")
        }

        if case .unsupported = ExtensionProxy.parse([
            "mode": "fixed_servers",
            "rules": ["singleProxy": ["host": "127.0.0.1", "port": 70000]],
        ]) {
            // expected
        } else {
            check(false, "expected out-of-range port to return .unsupported")
        }

        print("PASS extension proxy parsing and ProxyConfiguration translation checks")
    }
}
