import Foundation

class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectGuard()
    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let original = task.originalRequest, let from = original.url, let to = request.url,
              let sourceOrigin = Self.origin(from), let targetOrigin = Self.origin(to),
              !(response.url?.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https"),
              !(from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https") else { return nil }
        guard sourceOrigin != targetOrigin else { return request }
        // Never replay a token exchange, API mutation or upload body at another origin (including another port).
        guard ["GET", "HEAD"].contains(original.httpMethod ?? "GET"),
              original.httpBody == nil, original.httpBodyStream == nil,
              ["GET", "HEAD"].contains(request.httpMethod ?? "GET"),
              request.httpBody == nil, request.httpBodyStream == nil else { return nil }
        var stripped = request
        for header in ["Authorization", "Proxy-Authorization", "Cookie"] {
            stripped.setValue(nil, forHTTPHeaderField: header)
        }
        return stripped
    }
}

