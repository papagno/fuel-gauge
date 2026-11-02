import Foundation
import Testing
@testable import UsageCore

@Test func claudeParsesWindowsAndExtraUsage() throws {
    let json = """
    {"five_hour":{"utilization":12.0,"resets_at":"2026-10-08T12:00:00.123+00:00"},
     "seven_day":{"utilization":40,"resets_at":"2026-10-12T00:00:00Z"},
     "seven_day_opus":null,
     "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234,"utilization":24.68}}
    """
    let u = try ClaudeProvider.parse(Data(json.utf8), plan: "max")
    #expect(u.plan == "Max")
    #expect(u.windows.map(\.label) == ["Session (5h)", "Weekly", "Extra usage"])
    #expect(u.windows[0].resetsAt != nil)
    #expect(u.windows[2].detail == "$12.34 / $50.00")
    #expect(u.headlinePercent == 40)
    #expect(u.credits.isEmpty)
}

@Test func claudeParsesCloudCreditsOutsideWindows() throws {
    let json = """
    {"seven_day":{"utilization":40,"resets_at":"2026-10-12T00:00:00Z"},
     "iguana_necktie":{"utilization":25,"resets_at":"2026-11-05T00:00:00Z","limit_dollars":100,"used_dollars":null,"remaining_dollars":null}}
    """
    let u = try ClaudeProvider.parse(Data(json.utf8), plan: nil)
    #expect(u.windows.map(\.label) == ["Weekly"])
    let c = try #require(u.credits.first)
    #expect(c.label == "Cloud credits")
    #expect(c.remaining == 75 && c.total == 100 && c.usedPercent == 25)
    #expect(c.expiresAt == parseISODate("2026-11-05T00:00:00Z"))
    #expect(c.summary(locale: Locale(identifier: "en_US")) == "$75.00 of $100.00 left")
    // Placeholder blocks without a dollar limit are ignored.
    #expect(ClaudeProvider.parseCloudCredits(["utilization": 0, "limit_dollars": NSNull()]) == nil)
}

@Test func claudeParsesPrepaidCredits() throws {
    let json = """
    {"amount":5597,"currency":"EUR","balance":{"money":{"amount_minor":5597,"currency":"EUR","exponent":2},"credits":null},
     "tranches":[],"promo_tranches":[{"remaining_amount_minor_units":5596,"granted_amount_minor_units":8500,"currency":"EUR","expires_at":"2026-09-19T00:00:00Z"}],
     "next_expires_at":"2026-09-19T00:00:00Z"}
    """
    let c = try #require(try ClaudeProvider.parsePrepaidCredits(Data(json.utf8)))
    #expect(c.label == "Usage credits" && c.currency == "EUR")
    #expect(c.remaining == 55.97 && c.total == 85)
    #expect(c.expiresAt == parseISODate("2026-09-19T00:00:00Z"))
    #expect(c.summary(locale: Locale(identifier: "en_US")) == "€55.97 of €85.00 left")

    let bought = #"{"amount":1000,"currency":"USD","tranches":[],"promo_tranches":[]}"#
    let b = try #require(try ClaudeProvider.parsePrepaidCredits(Data(bought.utf8)))
    #expect(b.total == nil && b.usedPercent == nil)
    #expect(b.summary(locale: Locale(identifier: "en_US")) == "$10.00 left")

    let none = #"{"amount":0,"currency":"USD","balance":null,"tranches":[],"promo_tranches":[]}"#
    #expect(try ClaudeProvider.parsePrepaidCredits(Data(none.utf8)) == nil)
}

@Test func chatgptParsesPrimaryAndSecondary() throws {
    let json = """
    {"plan_type":"plus","rate_limit":{
      "primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_at":1793622392},
      "secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_at":1793622392}}}
    """
    let u = try ChatGPTProvider.parse(Data(json.utf8))
    #expect(u.plan == "Plus")
    #expect(u.windows.map(\.label) == ["Session (5h)", "Weekly"])
    #expect(u.headlinePercent == 55)
}

@Test func chatgptHandlesNullSecondary() throws {
    let json = """
    {"plan_type":"free","rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":2592000,"reset_at":1793622392},"secondary_window":null}}
    """
    let u = try ChatGPTProvider.parse(Data(json.utf8))
    #expect(u.windows.map(\.label) == ["Monthly"])
}

@Test func copilotSkipsUnlimitedQuotas() throws {
    let json = """
    {"copilot_plan":"business","quota_reset_date":"2026-11-01","quota_snapshots":{
      "chat":{"unlimited":true,"percent_remaining":100},
      "premium_interactions":{"unlimited":false,"percent_remaining":73.0,"remaining":21928,"entitlement":30000}}}
    """
    let u = try CopilotProvider.parse(Data(json.utf8))
    #expect(u.plan == "Business")
    #expect(u.windows.count == 1)
    #expect(u.windows[0].label == "Premium requests")
    #expect(u.windows[0].usedPercent == 27)
    #expect(u.windows[0].detail == "8072 / 30000")
    #expect(u.windows[0].resetsAt != nil)
}

@Test func expectedPercentReflectsElapsedTime() {
    let now = Date()
    let w = UsageWindow(label: "Weekly", usedPercent: 10, resetsAt: now.addingTimeInterval(5 * 86400), duration: 7 * 86400)
    #expect(abs(w.expectedPercent(at: now)! - 200.0 / 7) < 0.001)
    #expect(UsageWindow(label: "x", usedPercent: 0, resetsAt: nil).expectedPercent(at: now) == nil)
    let past = UsageWindow(label: "x", usedPercent: 0, resetsAt: now.addingTimeInterval(-10), duration: 100)
    #expect(past.expectedPercent(at: now) == 100)
}

@Test func copilotWindowSpansPreviousMonth() throws {
    let json = """
    {"quota_reset_date":"2026-11-01","quota_snapshots":{"premium_interactions":{"unlimited":false,"percent_remaining":50}}}
    """
    let u = try CopilotProvider.parse(Data(json.utf8))
    #expect(u.windows[0].duration == TimeInterval(31 * 86400))
}

@Test func menuBarShowsSessionAndWeeklyWhenBothExist() {
    let both = ProviderUsage(plan: nil, windows: [
        UsageWindow(label: "Session (5h)", usedPercent: 80, resetsAt: nil, duration: 5 * 3600),
        UsageWindow(label: "Weekly", usedPercent: 30, resetsAt: nil, duration: 7 * 86400),
        UsageWindow(label: "Weekly Opus", usedPercent: 45, resetsAt: nil, duration: 7 * 86400),
        UsageWindow(label: "Extra usage", usedPercent: 99, resetsAt: nil),
    ])
    #expect(both.menuBarPercents == [80, 45])
    let monthly = ProviderUsage(plan: nil, windows: [
        UsageWindow(label: "Premium requests", usedPercent: 27, resetsAt: nil, duration: 31 * 86400),
    ])
    #expect(monthly.menuBarPercents == [27])
}

@Test func menuBarShowsCountdownWhenLimitExhausted() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = { (used: Double, resetIn: TimeInterval) in
        UsageWindow(label: "w", usedPercent: used, resetsAt: now.addingTimeInterval(resetIn), duration: 5 * 3600)
    }
    #expect(window(99, 3600).menuBarText(now: now) == "99%")
    #expect(window(100, 2 * 3600 + 5 * 60 + 10).menuBarText(now: now) == "2h6m")
    #expect(window(100, 30).menuBarText(now: now) == "1m")
    #expect(window(100, 3 * 86400 + 4 * 3600).menuBarText(now: now) == "3d4h")
    #expect(window(100, 3600).menuBarText(now: now) == "1h")
    #expect(window(100, -60).menuBarText(now: now) == "100%")

    // With several exhausted limits, the later reset is the one that matters.
    let usage = ProviderUsage(plan: nil, windows: [
        UsageWindow(label: "a", usedPercent: 100, resetsAt: now.addingTimeInterval(600), duration: 31 * 86400),
        UsageWindow(label: "b", usedPercent: 100, resetsAt: now.addingTimeInterval(7200), duration: 31 * 86400),
    ])
    #expect(usage.menuBarWindows.map { $0.menuBarText(now: now) } == ["2h"])
    #expect(usage.isExhausted(now: now))
    #expect(!usage.isExhausted(now: now.addingTimeInterval(7200)))
    // No known reset (e.g. Claude extra usage): nothing to wait for.
    #expect(!ProviderUsage(plan: nil, windows: [UsageWindow(label: "x", usedPercent: 100, resetsAt: nil)])
        .isExhausted(now: now))
}

@Test func layoutReconcilesSavedPreferences() {
    let l = ProviderLayout(knownIDs: ["a", "b", "c"], savedOrder: ["c", "x", "a", "c"], hidden: ["a", "x"])
    #expect(l.order == ["c", "a", "b"])
    #expect(l.visible == ["c", "b"])
    let allHidden = ProviderLayout(knownIDs: ["a", "b"], hidden: ["a", "b"])
    #expect(allHidden.visible == ["a"])
}

@Test func layoutKeepsOneVisibleAndMoves() {
    var l = ProviderLayout(knownIDs: ["a", "b", "c"])
    l.setVisible("a", false)
    l.setVisible("b", false)
    #expect(!l.canToggle("c"))
    l.setVisible("c", false)
    #expect(l.visible == ["c"])
    l.setVisible("a", true)
    l.move("a", to: "c")
    #expect(l.order == ["b", "c", "a"])
    l.move("a", to: "b")
    #expect(l.order == ["a", "b", "c"])
}

@Test func usageRoundTripsThroughCodable() throws {
    let u = ProviderUsage(plan: "Pro", windows: [
        UsageWindow(label: "Weekly", usedPercent: 35, resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                    duration: 7 * 86400, detail: "x"),
    ], credits: [CreditBalance(label: "Cloud credits", remaining: 75, total: 100, currency: "USD",
                               expiresAt: Date(timeIntervalSince1970: 1_800_000_000))])
    let decoded = try JSONDecoder().decode(ProviderUsage.self, from: JSONEncoder().encode(u))
    #expect(decoded == u)
    // Values cached before credits existed still load.
    let old = try JSONDecoder().decode(ProviderUsage.self, from: Data(#"{"plan":"Pro","windows":[]}"#.utf8))
    #expect(old.credits.isEmpty)
    #expect(UsageError.rateLimited(retryAfter: 60).isRateLimited)
    #expect(UsageError.rateLimited(retryAfter: 60).retryAfter == 60)
    #expect(!UsageError.parse("x").isRateLimited)
}

@Test func retryAfterParsesSecondsAndHTTPDates() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(parseRetryAfter("2930", now: now) == 2930)
    #expect(parseRetryAfter(" 0 ", now: now) == 0)
    #expect(parseRetryAfter(nil, now: now) == nil)
    #expect(parseRetryAfter("soon", now: now) == nil)
    // 1_800_000_000 is Fri, 15 Jan 2027 08:00:00 GMT
    #expect(parseRetryAfter("Fri, 15 Jan 2027 08:10:00 GMT", now: now) == 600)
    #expect(parseRetryAfter("Fri, 15 Jan 2027 07:00:00 GMT", now: now) == 0)
}

@Test func cachedUsageRelevance() {
    let now = Date()
    let u = ProviderUsage(plan: nil, windows: [
        UsageWindow(label: "Session (5h)", usedPercent: 10, resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600),
    ])
    #expect(u.isStillRelevant(fetchedAt: now.addingTimeInterval(-60), maxAge: 300, now: now))
    #expect(!u.isStillRelevant(fetchedAt: now.addingTimeInterval(-600), maxAge: 300, now: now))
    let reset = ProviderUsage(plan: nil, windows: [
        UsageWindow(label: "Session (5h)", usedPercent: 90, resetsAt: now.addingTimeInterval(-1), duration: 5 * 3600),
    ])
    #expect(!reset.isStillRelevant(fetchedAt: now.addingTimeInterval(-60), maxAge: 300, now: now))
}

@Test func claudeCredentialsExpiry() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1793622392000,"subscriptionType":"max"}}"#
    let c = try ClaudeCredentials.parse(Data(json.utf8))
    #expect(c.accessToken == "tok" && c.subscriptionType == "max")
    #expect(!c.isExpired(now: Date(timeIntervalSince1970: 1793622391)))
    #expect(c.isExpired(now: Date(timeIntervalSince1970: 1793622392)))
    #expect(throws: UsageError.self) { try ClaudeCredentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8)) }
}

@Test func claudeTrustPromptDetection() {
    let prompt = "\u{1B}[1mDo you trust the files in this folder?\u{1B}[22m\r\n\u{1B}[36m❯ 1. Yes, proceed\u{1B}[39m"
    #expect(ClaudeCLIWaker.isTrustPrompt(prompt))
    #expect(!ClaudeCLIWaker.isTrustPrompt("\u{1B}[2m? for shortcuts\u{1B}[22m"))
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

@Test func claudeRefresherBacksOffAfterFailure() async {
    let calls = Counter()
    let outcome = Counter()
    let refresher = ClaudeTokenRefresher(cooldown: 600) { _ in
        await calls.increment()
        return await outcome.value > 0
    }
    let now = Date()
    #expect(await !refresher.refresh(now: now) { false })
    #expect(await !refresher.refresh(now: now.addingTimeInterval(60)) { false })
    #expect(await calls.value == 1)
    await outcome.increment()
    #expect(await refresher.refresh(now: now.addingTimeInterval(601)) { true })
    #expect(await refresher.refresh(now: now.addingTimeInterval(602)) { true })
    #expect(await calls.value == 3)
}

@Test func claudeWakerAnswersTrustPromptSendsStatusAndStops() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appendingPathComponent("refreshed"), pidFile = dir.appendingPathComponent("pid")
    let script = dir.appendingPathComponent("fake-claude")
    try """
    #!/bin/bash
    echo $$ > '\(pidFile.path)'
    sleep 1.5
    printf 'Do you trust the files in this folder?\\n> 1. Yes, proceed\\n'
    read -r answer
    [ -z "$answer" ] || exit 1
    while read -r line; do [ "$line" = "/status" ] && break; done
    touch '\(marker.path)'
    sleep 60
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let ok = await ClaudeCLIWaker.run(script.path, arguments: [], timeout: 10, statusAfter: 0.5) {
        FileManager.default.fileExists(atPath: marker.path)
    }
    #expect(ok)
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) != 0)
}
