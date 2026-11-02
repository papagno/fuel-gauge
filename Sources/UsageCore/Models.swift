import Foundation

public struct UsageWindow: Sendable, Equatable, Identifiable, Codable {
    public var id: String { label }
    public let label: String
    /// 0...100
    public let usedPercent: Double
    public let resetsAt: Date?
    public let detail: String?
    /// Length of the limit window, used to compute the even-pace target.
    public let duration: TimeInterval?

    public init(label: String, usedPercent: Double, resetsAt: Date?, duration: TimeInterval? = nil, detail: String? = nil) {
        self.label = label
        self.usedPercent = max(0, usedPercent)
        self.resetsAt = resetsAt
        self.duration = duration
        self.detail = detail
    }

    /// Usage you'd be at by `now` if consumption were spread evenly over the window (0...100).
    public func expectedPercent(at now: Date = Date()) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let elapsed = duration - resetsAt.timeIntervalSince(now)
        return min(max(elapsed / duration, 0), 1) * 100
    }
}

/// A money balance on the account, such as prepaid credits. Shown in the panel only.
public struct CreditBalance: Sendable, Equatable, Identifiable, Codable {
    public var id: String { label }
    public let label: String
    /// Amounts in major units of `currency` (e.g. dollars).
    public let remaining: Double
    public let total: Double?
    public let currency: String
    public let expiresAt: Date?

    public init(label: String, remaining: Double, total: Double?, currency: String, expiresAt: Date?) {
        self.label = label
        self.remaining = remaining
        self.total = total
        self.currency = currency
        self.expiresAt = expiresAt
    }

    /// Share of `total` already spent (0...100), when the total is known.
    public var usedPercent: Double? {
        guard let total, total > 0 else { return nil }
        return min(max((total - remaining) / total, 0), 1) * 100
    }

    /// E.g. `$75.00 of $100.00 left`, or `€55.97 left` without a known total.
    public func summary(locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: currency, locale: locale)
        let left = remaining.formatted(style)
        guard let total else { return "\(left) left" }
        return "\(left) of \(total.formatted(style)) left"
    }
}

public struct ProviderUsage: Sendable, Equatable, Codable {
    public let plan: String?
    public let windows: [UsageWindow]
    public let credits: [CreditBalance]

    public init(plan: String?, windows: [UsageWindow], credits: [CreditBalance] = []) {
        self.plan = plan
        self.windows = windows
        self.credits = credits
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        windows = try c.decode([UsageWindow].self, forKey: .windows)
        // Absent in values cached by older versions.
        credits = try c.decodeIfPresent([CreditBalance].self, forKey: .credits) ?? []
    }

    /// Whether data fetched at `fetchedAt` still reflects reality: recent enough, and no limit has reset since.
    public func isStillRelevant(fetchedAt: Date, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(fetchedAt) < maxAge else { return false }
        return !windows.contains { w in w.resetsAt.map { $0 <= now } ?? false }
    }

    /// The most constrained window; what the menu bar shows.
    public var headlinePercent: Double? { windows.map(\.usedPercent).max() }

    /// Whether a limit is used up and waiting on a known reset; values can't change until a reset passes.
    public func isExhausted(now: Date = Date()) -> Bool {
        windows.contains { w in w.usedPercent >= 100 && (w.resetsAt.map { $0 > now } ?? false) }
    }

    /// Windows shown in the menu bar: `[session, weekly]` when the plan has both a short session
    /// window and weekly limits (highest weekly wins), otherwise just the headline.
    public var menuBarWindows: [UsageWindow] {
        let session = windows.filter { ($0.duration ?? 0) > 0 && $0.duration! <= 6 * 3600 }
        let weekly = windows.filter { ($0.duration ?? 0) > 6 * 3600 && $0.duration! <= 8 * 86400 }
        // Ties (e.g. several exhausted limits) go to the later reset, since that's what actually blocks.
        let order: (UsageWindow, UsageWindow) -> Bool = {
            ($0.usedPercent, $0.resetsAt ?? .distantPast) < ($1.usedPercent, $1.resetsAt ?? .distantPast)
        }
        if let s = session.max(by: order), let w = weekly.max(by: order) {
            return [s, w]
        }
        return windows.max(by: order).map { [$0] } ?? []
    }

    public var menuBarPercents: [Double] { menuBarWindows.map(\.usedPercent) }
}

extension UsageWindow {
    /// Menu bar text: the percentage, or the time left until reset once the limit is exhausted.
    public func menuBarText(now: Date = Date()) -> String {
        if usedPercent >= 100, let resetsAt, resetsAt > now {
            return Self.compactCountdown(resetsAt.timeIntervalSince(now))
        }
        return "\(Int(usedPercent.rounded()))%"
    }

    /// Compact duration such as `2d4h`, `3h12m` or `45m`; rounds up to the next minute.
    public static func compactCountdown(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        let d = minutes / 1440, h = minutes % 1440 / 60, m = minutes % 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }
}

public enum UsageError: LocalizedError, Sendable {
    case notLoggedIn(String)
    case tokenExpired(String)
    case http(Int, String)
    /// `retryAfter` comes from the `Retry-After` header, in seconds from when the response was received.
    case rateLimited(retryAfter: TimeInterval?)
    case parse(String)

    public var isRateLimited: Bool {
        if case .rateLimited = self { true } else { false }
    }

    public var retryAfter: TimeInterval? {
        if case .rateLimited(let s) = self { s } else { nil }
    }

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn(let hint): "Not logged in. \(hint)"
        case .tokenExpired(let hint): "Token expired. \(hint)"
        case .http(let code, let body): "HTTP \(code): \(body.prefix(120))"
        case .rateLimited: "Rate limited by API."
        case .parse(let what): "Unexpected response: \(what)"
        }
    }
}

public protocol UsageProvider: Sendable {
    var id: String { get }
    var name: String { get }
    /// Short tag used in the menu bar title.
    var shortName: String { get }
    func fetch() async throws -> ProviderUsage
}
