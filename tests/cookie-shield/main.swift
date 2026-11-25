import Foundation

@main
struct CookieShieldTests {
    static func check(_ cond: Bool, _ msg: String) {
        if !cond {
            fputs("FAIL: \(msg)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        guard let spec = CookieShield.spec else {
            fputs("FAIL: CookieShield.spec must build\n", stderr)
            exit(1)
        }
        check(spec.identifier.hasPrefix("office-cookies-"), "identifier prefix mismatch")
        guard let data = spec.json.data(using: .utf8),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            fputs("FAIL: CookieShield.spec.json must decode as rule list array\n", stderr)
            exit(1)
        }
        check(rules.count == CookieShield.thirdPartyPatterns.count + 1, "unexpected rule count \(rules.count)")

        var sawCosmetic = false
        for rule in rules {
            guard let trigger = rule["trigger"] as? [String: Any],
                  let action = rule["action"] as? [String: Any],
                  let urlFilter = trigger["url-filter"] as? String, !urlFilter.isEmpty,
                  let actionType = action["type"] as? String else {
                fputs("FAIL: rule missing trigger or action: \(rule)\n", stderr)
                exit(1)
            }
            if actionType == "block" {
                let loadType = trigger["load-type"] as? [String] ?? []
                check(loadType == ["third-party"], "network block rule must be scoped to third-party: \(urlFilter)")
            } else if actionType == "css-display-none" {
                sawCosmetic = true
                let selector = action["selector"] as? String ?? ""
                check(!selector.isEmpty, "cosmetic selector cannot be empty")
                check(!selector.contains("["), "cosmetic selector must not contain slow attribute matchers: \(selector)")
                check(!selector.contains("*"), "cosmetic selector must not contain wildcards: \(selector)")
                let parts = selector.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                check(parts.allSatisfy { $0.hasPrefix("#") || $0.hasPrefix(".") }, "all cosmetic selectors must be exact #id or .class")
            } else {
                fputs("FAIL: unexpected action type \(actionType)\n", stderr)
                exit(1)
            }
        }
        check(sawCosmetic, "missing cosmetic display-none rule")
        print("All CookieShield rule validation tests passed (\(rules.count) rules).")
    }
}
