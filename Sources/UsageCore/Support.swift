import Foundation

enum Shell {
    /// A PATH that includes Homebrew locations (GUI apps don't inherit the shell PATH).
    static var path: String {
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    static func run(_ executable: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [executable] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: s)
                } else {
                    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    cont.resume(throwing: UsageError.notLoggedIn("`\(executable)` failed: \(e.prefix(120))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

enum HTTP {
    static func getJSON(_ url: URL, headers: [String: String], expiredHint: String) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401, 403: throw UsageError.tokenExpired(expiredHint)
        case 429:
            let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw UsageError.rateLimited(retryAfter: parseRetryAfter(header))
        default: throw UsageError.http(code, String(decoding: data, as: UTF8.self))
        }
    }
}

/// Parses a `Retry-After` header value: either delay-seconds or an HTTP date.
public func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
    if let seconds = Double(v) { return max(0, seconds) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f.date(from: v).map { max(0, $0.timeIntervalSince(now)) }
}

func parseISODate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withFullDate]
    return f.date(from: s)
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UsageError.parse("not a JSON object")
    }
    return obj
}

func number(_ v: Any?) -> Double? {
    (v as? NSNumber)?.doubleValue
}
