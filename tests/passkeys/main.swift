import AuthenticationServices
import Foundation
import WebKit

// Minimal stubs so Passkeys.swift compiles standalone without the full app.
enum Preferences { static var entitledToPasskeys = false }
enum FormRelay { static var passkeysOffered = true }
enum Store { static var testing = true }
@MainActor final class Tab { var committed: URL? }

@objc(BrowseTestPasskeyAssertion)
private final class MockAssertion: NSObject, ASAuthorizationPublicKeyCredentialAssertion {
    var credentialID = Data([1])
    var rawClientDataJSON = Data([2])
    var rawAuthenticatorData: Data! = Data([3])
    var signature: Data! = Data([4])
    var userID: Data!
    static var supportsSecureCoding: Bool { true }
    override init() { super.init() }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}
    func copy(with zone: NSZone? = nil) -> Any { self }
}

private var failures = 0
private func expect(_ ok: Bool, _ what: String) {
    if !ok {
        failures += 1
        print("FAIL: \(what)")
    }
}

@main
struct PasskeysChecks {
    @MainActor static func main() throws {
        // 1. Registrable.sameSite with macOS's public-suffix test (#679).
        guard let test = Passkeys.publicSuffix else {
            fatalError("no public-suffix test on this Mac")
        }
        let suffix: (String) -> Bool = { test($0 as CFString) }
        expect(Registrable.sameSite("account.apple.com", "idmsa.apple.com", isSuffix: suffix),
               "Apple's sign-in frame is the page's own site")
        expect(Registrable.sameSite("appleid.apple.com", "idmsa.apple.com", isSuffix: suffix),
               "Sign in with Apple frame is the page's own site")
        expect(Registrable.sameSite("example.com", "example.com", isSuffix: suffix),
               "the same host is the same site")
        expect(!Registrable.sameSite("raindrop.io", "idmsa.apple.com", isSuffix: suffix),
               "another site is not")
        expect(!Registrable.sameSite("evil.github.io", "victim.github.io", isSuffix: suffix),
               "two sites under a public suffix are not one")
        expect(!Registrable.sameSite("a.co.uk", "b.co.uk", isSuffix: suffix),
               "nor under a two-label suffix")
        expect(!Registrable.sameSite("10.0.0.1", "10.0.0.2", isSuffix: suffix),
               "addresses are never one site")
        expect(!Registrable.sameSite("apple.com.evil.com", "idmsa.apple.com", isSuffix: suffix),
               "a look-alike is not")
        expect(!Registrable.sameSite("a.example.com", "b.example.com", isSuffix: nil),
               "without the suffix test, only the same host")

        // 2. Security-key assertions without a user handle (#646).
        func reply(from got: ASAuthorizationPublicKeyCredentialAssertion) -> [String: Any] {
            Passkeys.assertionReply(
                id: got.credentialID, clientData: got.rawClientDataJSON, authenticatorData: got.rawAuthenticatorData,
                signature: got.signature, user: got.userID, attachment: "cross-platform"
            )
        }
        let noHandle = reply(from: MockAssertion())
        expect(noHandle["userHandle"] is NSNull, "nil userID becomes NSNull")
        expect(noHandle["kind"] as? String == "get", "kind is get")
        expect(noHandle["id"] as? String == "AQ", "id encoded as base64url")
        expect(noHandle["clientDataJSON"] as? String == "Ag", "clientDataJSON encoded")
        expect(noHandle["authenticatorData"] as? String == "Aw", "authenticatorData encoded")
        expect(noHandle["signature"] as? String == "BA", "signature encoded")
        expect(noHandle["attachment"] as? String == "cross-platform", "attachment preserved")
        _ = try JSONSerialization.data(withJSONObject: noHandle)

        let withHandle = MockAssertion()
        withHandle.userID = Data([0xfb, 0xff])
        expect(reply(from: withHandle)["userHandle"] as? String == "-_8", "non-empty userID encoded as base64url")
        withHandle.userID = Data()
        expect(reply(from: withHandle)["userHandle"] as? String == "", "empty userID encoded as empty string")

        // 3. Main-frame committed origin check (#988).
        func page(_ text: String) -> URL? { URL(string: text) }
        expect(Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: page("https://example.com/login")),
               "matches same origin")
        expect(Passkeys.isPage(scheme: "https", host: "Example.COM", port: 0, of: page("https://example.com/")),
               "host comparison is case-insensitive")
        expect(Passkeys.isPage(scheme: "http", host: "localhost", port: 3000, of: page("http://localhost:3000/")),
               "matches explicit port")
        expect(Passkeys.isPage(scheme: "https", host: "example.com", port: 443, of: page("https://example.com/")),
               "443 matches omitted https port")
        expect(Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: page("https://example.com:443/")),
               "0 matches explicit 443 on https")
        expect(!Passkeys.isPage(scheme: "https", host: "example.com", port: 8443, of: page("https://example.com/")),
               "non-default port does not match omitted")
        expect(!Passkeys.isPage(scheme: "https", host: "bank.example", port: 0, of: page("https://example.com/")),
               "another domain does not match")
        expect(!Passkeys.isPage(scheme: "https", host: "login.example.com", port: 0, of: page("https://example.com/")),
               "subdomain does not match apex")
        expect(!Passkeys.isPage(scheme: "http", host: "localhost", port: 0, of: page("https://localhost/")),
               "different scheme does not match")
        expect(Passkeys.isPage(scheme: "http", host: "::1", port: 8080, of: page("http://[::1]:8080/")),
               "IPv6 literal matches")
        expect(!Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: nil),
               "nil page does not match")
        expect(!Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: page("about:blank")),
               "about:blank does not match")

        // 4. Writable credential methods & conditional mediation capabilities in page script (#407, #17).
        expect(PasskeyRelay.page.contains("writable: !!hidden"), "credential methods are writable")
        expect(PasskeyRelay.page.contains("conditionalGet: true, conditionalMediation: true"),
               "conditional mediation capabilities are advertised")

        if failures > 0 { exit(1) }
        print("PASS passkey same-site frames, nil userHandle, committed origin, and page script checks")
    }
}
