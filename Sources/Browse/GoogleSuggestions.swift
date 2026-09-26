import Foundation

/// Optional, short-lived query completions. Google does not publish this web
/// endpoint as a supported API, so failure simply leaves the local offers.
enum GoogleSuggestions {
    static let maximumBytes = 32_768
    static let maximumRows = 4

    /// A typed address, email, or pasted URL never goes to the suggestion
    /// service. Search terms can still be submitted normally with Return.
    static func eligible(_ typed: String) -> Bool {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 120,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        let lower = text.lowercased()
        guard !lower.hasPrefix("www."), !lower.hasPrefix("localhost"),
              !lower.contains(":"), !lower.contains("@"), !lower.contains("\\")
        else { return false }
        return !lower.split(whereSeparator: \.isWhitespace).contains { part in
            part.contains("/") || part.contains(".")
        }
    }

    static func request(for typed: String) -> URLRequest? {
        guard eligible(typed) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "suggestqueries.google.com"
        parts.path = "/complete/search"
        parts.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "q", value: typed.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decode(_ data: Data, for typed: String) -> [String] {
        guard data.count <= maximumBytes,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              payload.count >= 2,
              let echoed = payload[0] as? String,
              Searched.plain(echoed) == Searched.plain(typed),
              let choices = payload[1] as? [String]
        else { return [] }
        var seen = Set<String>()
        var found: [String] = []
        for choice in choices {
            let text = choice.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Searched.plain(text)
            guard !key.isEmpty, text.count <= 120,
                  key != Searched.plain(typed), seen.insert(key).inserted
            else { continue }
            found.append(text)
            if found.count == maximumRows { break }
        }
        return found
    }

    static func fetch(_ typed: String, using session: URLSession) async -> [String] {
        guard let request = request(for: typed) else { return [] }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https", http.url?.host == "suggestqueries.google.com",
                  ["application/json", "text/javascript"].contains(http.mimeType ?? ""),
                  (http.expectedContentLength <= Int64(maximumBytes)
                    || http.expectedContentLength == NSURLSessionTransferSizeUnknown)
            else { return [] }
            var data = Data()
            for try await byte in bytes {
                if Task.isCancelled || data.count >= maximumBytes { return [] }
                data.append(byte)
            }
            if Task.isCancelled { return [] }
            return decode(data, for: typed)
        } catch {
            return []
        }
    }
}
