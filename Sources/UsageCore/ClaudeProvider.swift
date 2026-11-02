import Foundation

/// Reads the Claude Code OAuth token from the macOS keychain and queries the subscription usage endpoint.
/// An expired token is renewed by briefly starting Claude Code (see `ClaudeTokenRefresher`).
public struct ClaudeProvider: UsageProvider {
    public let id = "claude"
    public let name = "Claude"
    public let shortName = "C"
    public init() {}

    static let hint = "Run `claude` and log in to refresh."

    static func readCredentials() async throws -> ClaudeCredentials {
        let raw: String
        do {
            // Use the `security` CLI: Claude Code writes the item with it, so no keychain prompt is shown.
            raw = try await Shell.run("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        } catch {
            throw UsageError.notLoggedIn(Self.hint)
        }
        return try ClaudeCredentials.parse(Data(raw.utf8))
    }

    public func fetch() async throws -> ProviderUsage {
        var creds = try await Self.readCredentials()
        if creds.isExpired() {
            let renewed = await ClaudeTokenRefresher.shared.refresh {
                (try? await Self.readCredentials())?.isExpired() == false
            }
            if renewed { creds = try await Self.readCredentials() }
            if creds.isExpired() { throw UsageError.tokenExpired(Self.hint) }
        }
        let token = creds.accessToken
        // The endpoint rate-limits requests that don't identify as Claude Code.
        let version = (try? await Shell.run("claude", ["--version"]))?.split(separator: " ").first.map(String.init) ?? "2.1.0"
        let headers = Self.headers(token: token, version: version)
        let data = try await HTTP.getJSON(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: headers, expiredHint: Self.hint)
        let usage = try Self.parse(data, plan: creds.subscriptionType)
        guard let prepaid = await ClaudePrepaidCredits.shared.fetch(token: token, headers: headers) else { return usage }
        return ProviderUsage(plan: usage.plan, windows: usage.windows, credits: usage.credits + [prepaid])
    }

    static func headers(token: String, version: String) -> [String: String] {
        ["Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/\(version)"]
    }

    static let knownWindows: [(key: String, label: String, duration: TimeInterval)] = [
        ("five_hour", "Session (5h)", 5 * 3600),
        ("seven_day", "Weekly", 7 * 86400),
        ("seven_day_sonnet", "Weekly Sonnet", 7 * 86400),
        ("seven_day_opus", "Weekly Opus", 7 * 86400),
    ]

    public static func parse(_ data: Data, plan: String?) throws -> ProviderUsage {
        let obj = try jsonObject(data)
        var windows: [UsageWindow] = []
        for (key, label, duration) in knownWindows {
            guard let w = obj[key] as? [String: Any], let u = number(w["utilization"]) else { continue }
            windows.append(UsageWindow(label: label, usedPercent: u,
                                       resetsAt: parseISODate(w["resets_at"] as? String), duration: duration))
        }
        if let extra = obj["extra_usage"] as? [String: Any],
           extra["is_enabled"] as? Bool == true,
           let u = number(extra["utilization"]) {
            var detail: String?
            if let used = number(extra["used_credits"]), let limit = number(extra["monthly_limit"]) {
                detail = String(format: "$%.2f / $%.2f", used / 100, limit / 100)
            }
            windows.append(UsageWindow(label: "Extra usage", usedPercent: u, resetsAt: nil, detail: detail))
        }
        if windows.isEmpty { throw UsageError.parse("no usage windows") }
        return ProviderUsage(plan: plan?.capitalized, windows: windows,
                             credits: [parseCloudCredits(obj["iguana_necktie"])].compactMap { $0 })
    }

    /// Claude Code on the web credits, reported in the usage response under an internal code name.
    /// Amounts are in dollars; `resets_at` is when the credits expire.
    static func parseCloudCredits(_ value: Any?) -> CreditBalance? {
        guard let c = value as? [String: Any], let limit = number(c["limit_dollars"]), limit > 0 else { return nil }
        let remaining = number(c["remaining_dollars"])
            ?? number(c["used_dollars"]).map { limit - $0 }
            ?? number(c["utilization"]).map { limit * (1 - $0 / 100) }
        guard let remaining else { return nil }
        return CreditBalance(label: "Cloud credits", remaining: max(remaining, 0), total: limit, currency: "USD",
                             expiresAt: parseISODate(c["resets_at"] as? String))
    }

    /// Prepaid usage credits (`/organizations/{uuid}/prepaid/credits`). Amounts are in minor units.
    /// Returns nil when the account has never had any.
    public static func parsePrepaidCredits(_ data: Data) throws -> CreditBalance? {
        let obj = try jsonObject(data)
        let money = (obj["balance"] as? [String: Any])?["money"] as? [String: Any]
        guard let minor = number(money?["amount_minor"]) ?? number(obj["amount"]) else {
            throw UsageError.parse("no prepaid balance")
        }
        let tranches = (obj["tranches"] as? [[String: Any]] ?? []) + (obj["promo_tranches"] as? [[String: Any]] ?? [])
        guard minor > 0 || !tranches.isEmpty else { return nil }
        let scale = pow(10, number(money?["exponent"]) ?? 2)
        let granted = tranches.compactMap { number($0["granted_amount_minor_units"]) }
        // Only trust the granted total when every tranche reports one and it covers the balance.
        let total = granted.count == tranches.count && !granted.isEmpty && granted.reduce(0, +) >= minor
            ? granted.reduce(0, +) / scale : nil
        return CreditBalance(label: "Usage credits", remaining: minor / scale, total: total,
                             currency: money?["currency"] as? String ?? obj["currency"] as? String ?? "USD",
                             expiresAt: parseISODate(obj["next_expires_at"] as? String))
    }
}

/// Fetches prepaid credits on a best-effort basis: failures never affect the usage windows.
/// Caches the organization UUID per token and keeps the last balance if a fetch fails.
actor ClaudePrepaidCredits {
    static let shared = ClaudePrepaidCredits()

    private var organization: (token: String, uuid: String)?
    private var last: (uuid: String, balance: CreditBalance?)?

    func fetch(token: String, headers: [String: String]) async -> CreditBalance? {
        guard let uuid = await organizationUUID(token: token, headers: headers) else { return nil }
        let url = URL(string: "https://api.anthropic.com/api/oauth/organizations/\(uuid)/prepaid/credits")!
        guard let data = try? await HTTP.getJSON(url, headers: headers, expiredHint: ClaudeProvider.hint),
              let balance = try? ClaudeProvider.parsePrepaidCredits(data) else {
            return last?.uuid == uuid ? last?.balance : nil
        }
        last = (uuid, balance)
        return balance
    }

    private func organizationUUID(token: String, headers: [String: String]) async -> String? {
        if let organization, organization.token == token { return organization.uuid }
        guard let data = try? await HTTP.getJSON(URL(string: "https://api.anthropic.com/api/oauth/profile")!,
                                                 headers: headers, expiredHint: ClaudeProvider.hint),
              let obj = try? jsonObject(data),
              let uuid = (obj["organization"] as? [String: Any])?["uuid"] as? String
        else { return last?.uuid }
        organization = (token, uuid)
        return uuid
    }
}
