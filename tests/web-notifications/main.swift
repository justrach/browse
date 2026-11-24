import Foundation

@main
struct WebNotificationsTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        check(
            WebNotifications.secureOrigin(scheme: "https", host: "example.com", port: 0) == "https://example.com",
            "https default port"
        )
        check(
            WebNotifications.secureOrigin(scheme: "HTTPS", host: "Example.COM", port: 443) == "https://example.com",
            "https port 443 normalization"
        )
        check(
            WebNotifications.secureOrigin(scheme: "https", host: "example.com", port: 8443) == "https://example.com:8443",
            "https custom port"
        )
        check(
            WebNotifications.secureOrigin(scheme: "http", host: "localhost", port: 3000) == "http://localhost:3000",
            "localhost http allowed"
        )
        check(
            WebNotifications.secureOrigin(scheme: "http", host: "127.0.0.1", port: 80) == "http://127.0.0.1",
            "loopback 127.0.0.1 allowed"
        )
        check(
            WebNotifications.secureOrigin(scheme: "http", host: "::1", port: 8080) == "http://[::1]:8080",
            "loopback ::1 allowed"
        )
        check(
            WebNotifications.secureOrigin(scheme: "http", host: "app.localhost", port: 0) == "http://app.localhost",
            "subdomain .localhost allowed"
        )
        check(
            WebNotifications.secureOrigin(scheme: "http", host: "example.com", port: 80) == nil,
            "insecure non-loopback http must be rejected"
        )
        check(
            WebNotifications.secureOrigin(scheme: "file", host: "", port: 0) == nil,
            "file origin must be rejected"
        )
        check(
            WebNotifications.permissionKey(for: "https://example.com") == "capture.https://example.com|notifications",
            "permission key must match Browser.savedCaptureChoices()"
        )
        check(!WebNotifications.hasAppBundle, "CLI test binary must not report a .app bundle")
        check(WebNotifications.page.contains("Object.defineProperty(window, 'Notification'"), "page script defines window.Notification")
        check(!WebNotifications.page.contains("webkit.messageHandlers"), "page script must never touch window.webkit")
        check(WebNotifications.bridge.contains("webkit.messageHandlers.\(WebNotifications.name)"), "bridge relays to WebNotificationRelay")

        print("PASS web notifications origin, permission-key, and bundle-safety checks")
    }
}
