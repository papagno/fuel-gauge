# Fuel Gauge — expert review, 2026-11-03

## Summary after verification

| Severity | Count | IDs |
|----------|------:|-----|
| Critical | 0 | — |
| High     | 0 | — |
| Medium   | 5 | C1, P1, A1, A2, T1 |
| Low      | 14 | C2, C3, UI1, UI2, UI3, UI4, UI5, UI6, UI7, P2, P4, A3, A4, T2 |
| Dropped  | 1 | P3 (see appendix) |

Of the 20 raw findings, 13 were confirmed as written, 6 were downgraded in severity, confidence or scope, and 1 was dropped. The verifier added no new findings.

---

## 1. Scope and method

- **Commit:** `c0d7e0c05370203c6f07e5a61adc31ce4a9acca7` (Merge pull request #6 from papagno/fix-dark-screenshot).
- **Targets reviewed:** `UsageCore` (library: providers, models, `Shell`/`HTTP` support, `ClaudeTokenRefresher`, `ClaudeCLIWaker`, `ClaudePrepaidCredits`), `FuelGauge` (executable: `App.swift`, `UsageStore`, `MenuBarLabel`, `Updates`, `LaunchAtLogin`, `WindowFitting`, `BrandIcons`) and `UsageCoreTests` (`ParsingTests.swift`). `bundle.sh` and `release.sh` were read only for runtime-relevant Info.plist keys (`LSUIElement`, `LSMinimumSystemVersion` 14.0, `SUFeedURL`, `SUPublicEDKey`; no sandbox or entitlements).
- **Configuration:** macOS 14 deployment target (`platforms: [.macOS(.v14)]`), `swift-tools-version: 6.0`, so Swift 6 language mode with complete strict concurrency. There are no `swiftSettings`, no default-MainActor isolation and no upcoming features. `UsageStore`, `LaunchAtLogin` and `Updates` are explicitly `@MainActor`. Sparkle resolves to 2.10.1.
- **Areas:** (1) Concurrency, (2) SwiftUI, (3) Persistence and sync (UserDefaults cache, `retryAt`, credentials and remote endpoints), (4) Accessibility, (5) Test quality.
- **Docs checked for deliberate decisions:** README.md. There is no CLAUDE.md, AGENTS.md, CONTEXT.md or ADR, and there are no earlier reviews in `docs/reviews/`. README-documented behaviour was treated as deliberate: the 10-minute retry for the Claude waker, waiting "as long as the `Retry-After` header asks", Open at Login on first run, and hover to see pace or credit amounts.
- **Method:** a static, read-only review on Linux by a first reviewer, then an independent adversarial verification pass. For every finding, the verifier opened the cited lines, re-read callers, callees and isolation, checked them against the README, and confirmed, downgraded or dropped it. Any confidence that depended on runtime behaviour was lowered.
- **Lint:** skipped, because `swift` (and so swift-format/SwiftLint) isn't available on this host.
- **Not checked (needs a Mac):** compiling and deprecation warnings; `swift test`; Thread Sanitizer; Instruments (SwiftUI, Time Profiler); actual VoiceOver and Voice Control output; Accessibility Inspector; runtime actor/isolation checks; Sparkle scheduled-update presentation; SMAppService status transitions; multi-display rendering. Section 5 lists the exact checks.

## 2. Headline findings

1. **C1** (medium): `Shell.run` waits on child processes with no bound, so one stuck `security`/`gh`/`claude` call holds `isRefreshing` and stops every later refresh for all providers. `Sources/UsageCore/Support.swift:9-31`, gate at `Sources/FuelGauge/UsageStore.swift:111`
2. **P1** (medium): One exhausted window stops all periodic fetches for that provider, freezing extra usage, credits and plan until the next reset (up to a month for Copilot). `Sources/FuelGauge/UsageStore.swift:127-128`
3. **A1** (medium): The menu bar item, the app's main output, is a single rasterised image with no accessibility label or value. `Sources/FuelGauge/MenuBarLabel.swift:14-16`
4. **A2** (medium): Pace and remaining-credit amounts are hover-only, and the bars aren't exposed to assistive tech. `Sources/FuelGauge/App.swift:188-195`, `:223-230`
5. **T1** (medium): The refresh scheduling policy, retry backoff and HTTP status mapping have no tests, and `UsageStore` has no seams. `Sources/FuelGauge/UsageStore.swift:110-149`, `Package.swift:18`
6. **UI2** (low): "Resets …" and "Next attempt in …" count *up* with no direction once the instant has passed. `Sources/FuelGauge/App.swift:194`, `:148-149`
7. **C3** (low): A refresh triggered by a limit reset is dropped if another refresh is in flight, and it is never re-detected. `Sources/FuelGauge/UsageStore.swift:107`, `:111`
8. **UI7** (low): The app opts in to Sparkle gentle reminders but implements no reminder, so background-found updates can go unnoticed. `Sources/FuelGauge/Updates.swift:27`
9. **P2** (low): `$CODEX_HOME` and `$GITHUB_TOKEN`, which the README advertises, are read from the GUI app's environment, which normally lacks them. `Sources/UsageCore/ChatGPTProvider.swift:13`, `Sources/UsageCore/CopilotProvider.swift:14`

---

## 3. Findings by area

### 3.1 Concurrency

#### C1: `Shell.run` has no timeout, so one stuck CLI stops every refresh
- **Severity:** medium (was high)
- **Confidence:** medium. The unbounded wait is certain. How often a child actually stalls depends on the runtime.
- **File:** `Sources/UsageCore/Support.swift:9-31`. Callers: `Sources/UsageCore/ClaudeProvider.swift:17`, `:35`, `Sources/UsageCore/CopilotProvider.swift:17`, and indirectly `ClaudeCLIWaker`'s `isRefreshed` poll (`ClaudeProvider.swift:28` → `ClaudeTokenRefresher.swift:90`). Gate: `Sources/FuelGauge/UsageStore.swift:110-121`.
- **Code:**
  ```swift
  try await withCheckedThrowingContinuation { cont in
      ...
      p.terminationHandler = { proc in
          let data = out.fileHandleForReading.readDataToEndOfFile()
          ...
      }
      do { try p.run() } catch { cont.resume(throwing: error) }
  }
  ```
  ```swift
  guard !isRefreshing else { return }
  ...
  isRefreshing = true
  defer { isRefreshing = false; lastRefresh = Date() }
  await withTaskGroup(of: Void.self) { group in ... }
  ```
- **Why it matters:** The continuation resumes only from `terminationHandler`. Nothing bounds the wait: there is no deadline and no cancellation handler, and pipes are read only after exit. `refresh()` awaits every provider in its task group, so a single stalled child keeps `isRefreshing == true`. The 5-minute timer, the reset tick and the manual Refresh (disabled at `App.swift:76`) then all return at the guard. Inside `ClaudeCLIWaker.run`, `await isRefreshed()` calls `security` too, so a stall there also defeats the waker's own 30 s timeout check, which runs only between iterations.
- **Failure scenario:** A `security find-generic-password` (Claude) or `gh auth token` (keyring-backed) call blocks, for example on a keychain-unlock prompt, a wedged `securityd`, or a CLI waiting on something. All three providers stop updating and the footer shows "Refreshing…" until the child exits. If it never exits, that lasts until the app is relaunched. A child that writes more than the pipe buffer (~64 KB) to stdout or stderr before exiting also deadlocks, because nothing drains the pipes while it runs.
- **Suggested fix:** Give `Shell.run` a deadline (e.g. 10 s). Race the process against `Task.sleep` and on timeout send `terminate()`, then `SIGKILL`. Resume exactly once, guarded by a `Mutex`/flag. Drain stdout and stderr while the child runs (`readabilityHandler`). Wrap the call in `withTaskCancellationHandler` so it terminates the child on cancel. Optionally put a per-provider deadline in `UsageStore.refresh`, so that one provider can't hold the gate for the others.
- **Verification:** **downgraded**, high to medium. The code path is exactly as described. However, the cited keychain-unlock case is a user-visible dialog that ends the wait when answered or cancelled (non-zero exit leads to a resume), and the login keychain doesn't lock on sleep by default. "Frozen until relaunch" needs a child that truly never exits, which reading the code can't establish. All current commands produce small output, so the pipe-buffer path is theoretical today.

#### C2: `setVisible` starts an untracked fetch, so the same provider can be fetched twice at once
- **Severity:** low
- **Confidence:** high
- **File:** `Sources/FuelGauge/UsageStore.swift:169-175`, `:133-149`
- **Code:**
  ```swift
  if visible, let p = providers.first(where: { $0.id == id }) {
      Task { await fetch(p) }
  }
  ```
  ```swift
  private func fetch(_ p: any UsageProvider) async {
      if let until = retryAt[p.id], until > Date() { return }
      do {
          states[p.id] = .loaded(try await p.fetch(), at: Date())
  ```
- **Why it matters:** This path bypasses the `isRefreshing` gate, and nothing records in-flight fetches per provider. `fetch` reads `retryAt` before its `await` and writes `states` after it (MainActor reentrancy), so overlapping fetches both hit the network, and whichever finishes last wins.
- **Failure scenario:** The user re-shows a provider while a timer refresh for it is in flight, or toggles it off and on twice. Two Claude fetches each spawn `security` and `claude --version` and call `/usage`, `/profile` and `/prepaid/credits`. On an endpoint that rate-limits, this can earn a 429. A slower, older request that fails can overwrite the newer success with `.failed`.
- **Suggested fix:** Keep `inFlight: [String: Task<Void, Never>]` on the store. Join or skip an existing fetch for that id, and route `setVisible` through the same entry point as `refresh`.
- **Verification:** **confirmed**. The reentrancy window is real on the MainActor-isolated store. Severity stays low because it needs deliberate toggling during a refresh.

#### C3: A refresh triggered by a limit reset is dropped while another refresh runs
- **Severity:** low
- **Confidence:** high (mechanism). How often the two collide depends on the runtime.
- **File:** `Sources/FuelGauge/UsageStore.swift:98-108`, `:110-111`
- **Code:**
  ```swift
  let resetPassed = visibleProviders.contains { p in
      states[p.id]?.usage?.windows.contains { w in
          w.resetsAt.map { $0 > previous && $0 <= clock } ?? false
      } ?? false
  }
  if resetPassed { Task { await refresh(onlyStale: true) } }
  ```
  ```swift
  func refresh(onlyStale: Bool = false) async {
      guard !isRefreshing else { return }
  ```
- **Why it matters:** A reset is edge-detected in exactly one tick. If `isRefreshing` is true at that moment, the request is discarded and never retried. The next 5-minute timer does pick the provider up, because `needsFetch` sees `resetsAt <= now`, so the data is late, not lost.
- **Failure scenario:** A session resets at 14:00. A timer refresh is still waiting on Claude (for example, the waker is running, which takes up to ~30 s) when the 14:00 tick fires. The panel and menu bar keep pre-reset values for up to 5 minutes, at the moment the user is waiting for the reset.
- **Suggested fix:** If `refresh` is called while one is running, set `pendingRefresh = true` and run one more `refresh(onlyStale: true)` after the group finishes. Alternatively, make the tick level-triggered: "any visible window with `resetsAt` between its `updatedAt` and now".
- **Verification:** **confirmed**. One correction: the finding says the collision is "likely". A normal refresh takes seconds, so it's uncommon except while the waker runs. The bound is one timer interval.

### 3.2 SwiftUI

#### UI2: Relative-time texts show no direction and count up once the instant passes
- **Severity:** low
- **Confidence:** high. The exact rendered string comes from the framework, but the code's own `"Updated \(t, style: .relative) ago"` (`App.swift:70`) shows that `.relative` has no built-in direction.
- **File:** `Sources/FuelGauge/App.swift:148-149`, `:193-194`, `:231`
- **Code:**
  ```swift
  if let retryAt, retryAt > Date() {
      Text("Next attempt in \(retryAt, style: .relative).")
  ```
  ```swift
  } else if let r = window.resetsAt {
      Text("Resets \(r, style: .relative)")
  ```
  ```swift
  Text(e > Date() ? "Expires \(e.formatted(date: .abbreviated, time: .omitted))" : "Expired")
  ```
- **Why it matters:** `.relative` renders a live magnitude that keeps updating in both directions. The "Resets" row has no past/future check at all. The `retryAt > Date()` and `e > Date()` checks run only when `body` runs, and nothing in `UsagePanel` reads `store.clock`. Once the instant passes, the text counts up and reads like time remaining.
- **Failure scenario:** Claude is rate-limited or offline, so `last` values with an old `resetsAt` stay on screen. Three minutes after the reset, the row reads "Resets 3 min" and keeps growing. "Next attempt in 1 min" also grows after the Retry-After deadline, until the next 5-minute refresh.
- **Suggested fix:** Wrap these rows in `TimelineView(.everyMinute)`, or pass `store.clock` down. Branch on `r > now` and show "Resetting…" or "Reset" when it's in the past. Use a directional format (`Date.RelativeFormatStyle(presentation: .named)` → "in 2 hours") inside the timeline.
- **Verification:** **confirmed**. In the healthy path the tick refresh replaces `resetsAt` within about a minute. The visible bug lasts in the failed, rate-limited and offline states, which is when users look most closely.

#### UI1: A cancelled drag leaves the card at 40% opacity
- **Severity:** low
- **Confidence:** high (mechanism). Whether the `@State` survives closing and reopening the panel depends on how `MenuBarExtra` keeps its window alive.
- **File:** `Sources/FuelGauge/App.swift:45-57`, `:105-121`
- **Code:**
  ```swift
  .opacity(dragging == p.id ? 0.4 : 1)
  .onDrag {
      dragging = p.id
      ...
  ```
  ```swift
  func performDrop(info: DropInfo) -> Bool {
      dragging = nil
      return true
  }
  ```
- **Why it matters:** `dragging` is cleared only in a card's `performDrop`. `onDrag` has no end or cancel callback. A drop on the footer, in the 12 pt gap, outside the panel, or cancelled with Esc never resets it.
- **Failure scenario:** The user drags the bottom card toward the footer and releases there. The order has already changed live, but the card stays dimmed until a later drag ends on a card.
- **Suggested fix:** Add a container-level `.onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }` on the panel's outer `VStack`, and reset `dragging` in `.onDisappear` of the panel content. **Don't** clear it in `dropExited`, as the original finding suggests. `dropExited` fires each time the pointer leaves one card for the next, so clearing it there would break live reordering, because `dropEntered` guards on `dragging`. On macOS 14, `.draggable`/`.dropDestination(for:action:isTargeted:)` with a `Transferable` id is the more modern route.
- **Verification:** **confirmed**, with the suggested fix corrected as above.

#### UI3: The footer says "Updated just now" even when nothing was updated
- **Severity:** low
- **Confidence:** high
- **File:** `Sources/FuelGauge/UsageStore.swift:114-115`, `:134`; `Sources/FuelGauge/App.swift:69-70`
- **Code:**
  ```swift
  isRefreshing = true
  defer { isRefreshing = false; lastRefresh = Date() }
  ```
  ```swift
  if let until = retryAt[p.id], until > Date() { return }
  ```
- **Why it matters:** `lastRefresh` is stamped after every refresh whatever the outcome, including when every fetch failed or returned early because of `retryAt`.
- **Failure scenario:** After wake with no network, all three fetches fail. The footer says "Updated 0 sec ago" while each section says "Showing last known values from 25 min ago". During a rate limit, manual Refresh makes no network call yet reports "Updated just now".
- **Suggested fix:** Have `fetch` return `Bool` (succeeded), and stamp `lastRefresh` only if at least one fetch succeeded. Alternatively, drop the global timestamp in favour of the per-provider `updatedAt`.
- **Verification:** **confirmed**.

#### UI4: The Open at Login toggle shows a stale, cached status
- **Severity:** low
- **Confidence:** high for the stale status; medium for the `.requiresApproval` path, which depends on how SMAppService behaves at runtime.
- **File:** `Sources/FuelGauge/LaunchAtLogin.swift:7`, `:19-27`; `Sources/FuelGauge/App.swift:77-78`
- **Code:**
  ```swift
  private(set) var isEnabled = SMAppService.mainApp.status == .enabled
  ...
  isEnabled = SMAppService.mainApp.status == .enabled
  ```
- **Why it matters:** The status is read once at init and after `set`. Changes made in System Settings › General › Login Items are never picked up, and `.requiresApproval` is shown as "off" with no explanation.
- **Failure scenario:** The user disables Fuel Gauge in Login Items, but the gear menu still shows "Open at Login" ticked until relaunch.
- **Suggested fix:** Add `func reload()` and call it from `.onAppear` on the panel content. Surface `.requiresApproval` with a hint and `SMAppService.openSystemSettingsLoginItems()`.
- **Verification:** **confirmed**.

#### UI7: Opts in to gentle update reminders but provides no reminder UI
- **Severity:** low
- **Confidence:** medium. This depends on how Sparkle 2.10's standard user driver presents scheduled alerts for an `LSUIElement` app.
- **File:** `Sources/FuelGauge/Updates.swift:25-27`
- **Code:**
  ```swift
  // Menu bar apps have no Dock icon, so scheduled update alerts are shown gently instead of
  // stealing focus; Sparkle warns if a background app doesn't opt in.
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
  ```
- **Why it matters:** Returning `true` tells Sparkle that the app will draw the user's attention to scheduled updates itself. None of `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`, `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)` or `standardUserDriverDidReceiveUserAttention(forUpdate:)` is implemented, and nothing is badged in the UI.
- **Failure scenario:** A background check finds a new version while another app is frontmost. Sparkle shows its alert without focus, behind that app's windows. With no Dock icon, the user may never notice it, so auto-updates are effectively never offered. That has security relevance for a self-updating app.
- **Suggested fix:** Implement `standardUserDriverWillHandleShowingUpdate`. When `!state.userInitiated`, set an observable `updateAvailable` flag that adds a dot to `MenuBarLabel` and an "Update available…" row in the panel. Clear it in `standardUserDriverDidReceiveUserAttention` / `standardUserDriverWillFinishUpdateSession`.
- **Verification:** **confirmed**. The code comment explains why the app opts in, but no deliberate decision covers the missing reminder.

#### UI5: The menu bar image uses `NSScreen.main`'s scale, not the status item's screen
- **Severity:** low
- **Confidence:** low (was medium)
- **File:** `Sources/FuelGauge/MenuBarLabel.swift:44-48`
- **Code:**
  ```swift
  let renderer = ImageRenderer(content: content)
  renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
  ```
- **Why it matters:** The bitmap is rasterised at a single scale taken from `NSScreen.main`, and the `NSImage` has one representation. It is re-rendered only when the store changes, which includes the per-minute `clock` tick.
- **Failure scenario:** On a Retina laptop with a 1x external display, if `NSScreen.main` resolves to the 1x screen, the laptop's menu bar shows a blurry label until the next re-render.
- **Suggested fix:** Always render at 2x, since AppKit downsamples cleanly on 1x screens. Alternatively, add both 1x and 2x `NSBitmapImageRep`s to one `NSImage`.
- **Verification:** **downgraded** in confidence. Reading the code can't establish which screen `NSScreen.main` returns for an accessory app with no key window, or how `MenuBarExtra` shares the image across several menu bars. The "always 2x" fix is cheap either way.

#### UI6: `NSApp.activate(ignoringOtherApps:)` is deprecated on the macOS 14 target
- **Severity:** low
- **Confidence:** low for the behavioural failure; medium for the deprecation warning.
- **File:** `Sources/FuelGauge/Updates.swift:21`
- **Code:**
  ```swift
  NSApp.activate(ignoringOtherApps: true)
  ```
- **Why it matters:** The API is deprecated as of macOS 14 in favour of `NSApp.activate()` under cooperative activation.
- **Failure scenario:** The finding claims that Sparkle's window can open behind other apps. However, the call runs in direct response to a click inside the app's own `MenuBarExtra` panel, which is exactly when the system grants activation, so this is unlikely. The practical cost is a compiler deprecation warning and future breakage.
- **Suggested fix:** Replace it with `NSApp.activate()`.
- **Verification:** **downgraded**. It is a hygiene fix, not a user-visible bug, as far as reading the code can tell.

### 3.3 Persistence and sync

#### P1: An exhausted limit stops automatic fetches for the whole provider
- **Severity:** medium
- **Confidence:** high
- **File:** `Sources/FuelGauge/UsageStore.swift:123-131`; `Sources/UsageCore/Models.swift:90-93`; `Sources/UsageCore/CopilotProvider.swift:46`
- **Code:**
  ```swift
  // Exhausted limits can't move until their reset, which the clock tick catches.
  if usage.isExhausted() { return false }
  ```
  ```swift
  public func isExhausted(now: Date = Date()) -> Bool {
      windows.contains { w in w.usedPercent >= 100 && (w.resetsAt.map { $0 > now } ?? false) }
  }
  ```
- **Why it matters:** One exhausted window disables the periodic refresh for the provider's *other* windows (Claude "Extra usage" has no `resetsAt`), its credit balances and its plan. The premise in the comment is false: extra usage and credits keep being spent, and plan upgrades or purchased quota change the numbers. Fetches resume only when *some* window's `resetsAt` passes. For Claude that's the next session reset (≤ 5 h if a session window exists), and for Copilot's single monthly window it can be weeks.
- **Failure scenario:** (1) A Copilot user exhausts premium requests on the 3rd, then upgrades. The menu bar keeps showing a "28d" countdown until the 1st unless they press Refresh. (2) A Claude Max user hits the weekly limit and works on extra usage. The "Extra usage" bar and prepaid credits freeze for hours while money is being spent.
- **Suggested fix:** Back off rather than stop, e.g. fetch exhausted providers every 30–60 min. At minimum, skip only when *every* window is exhausted with a known reset and the provider has no credits. Cover this with the `needsFetch` tests in T1.
- **Verification:** **confirmed**. The code comment states the design intent, but no doc covers it. The test at `ParsingTests.swift:144-146` shows the author considered extra usage *alone*, but not extra usage alongside an exhausted weekly window. The severity is kept at medium because the stale value is money being spent.

#### P2: `CODEX_HOME` and `GITHUB_TOKEN` are read from the GUI app's environment
- **Severity:** low (was medium)
- **Confidence:** high
- **File:** `Sources/UsageCore/ChatGPTProvider.swift:13-14`; `Sources/UsageCore/CopilotProvider.swift:14`
- **Code:**
  ```swift
  let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
  ```
  ```swift
  if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty {
  ```
- **Why it matters:** The README advertises both variables. An `LSUIElement` app started by the Login Item, Finder or `open` (including `bundle.sh --install`) gets launchd's environment, not the shell rc. `Shell.path` already works around exactly this for PATH. The variables are seen only if the user ran `launchctl setenv`.
- **Failure scenario:** With `CODEX_HOME=~/.config/codex` in `.zshrc`, the app reads `~/.codex/auth.json` and shows "Not logged in. Run `codex`…" indefinitely, and following that hint doesn't help.
- **Suggested fix:** Resolve both from a login shell once (`/bin/zsh -lc 'printf %s "$CODEX_HOME"'`, behind the C1 timeout), or drop the claims from the README. Include the path that was tried in the error message.
- **Verification:** **downgraded**, medium to low. The mismatch is real, but it affects only users with a non-default `CODEX_HOME`, or who rely only on `GITHUB_TOKEN` without `gh` login. The title's "never" is too strong because of `launchctl setenv`.

#### P4: The prepaid-credit fallback can show the previous account's balance after an account switch
- **Severity:** low
- **Confidence:** medium
- **File:** `Sources/UsageCore/ClaudeProvider.swift:118-137`
- **Code:**
  ```swift
  guard let data = try? await HTTP.getJSON(url, headers: headers, expiredHint: ClaudeProvider.hint),
        let balance = try? ClaudeProvider.parsePrepaidCredits(data) else {
      return last?.uuid == uuid ? last?.balance : nil
  }
  ...
  if let organization, organization.token == token { return organization.uuid }
  ...
  else { return last?.uuid }
  ```
- **Why it matters:** When `/profile` fails for a *new* token, `organizationUUID` falls back to the previous token's org. The prepaid call for that org with the new token then fails, and `fetch` returns `last.balance` because `last.uuid == uuid`. Nothing ties the cached org to the account.
- **Failure scenario:** The user runs `claude /login` with a different account, and on the next refresh `/profile` fails while `/usage` succeeds. The panel shows the old account's "Usage credits €55.97 left" under the new account's usage.
- **Suggested fix:** When `organization?.token != token` and `/profile` fails, return `nil` rather than `last?.uuid`. Alternatively, key `last` by account id. Note that tokens rotate every few hours for the *same* account, so keep a fallback for that case if it's wanted, for example by comparing the `account.uuid` from `/profile`.
- **Verification:** **confirmed**. It needs `/profile` to fail independently while `/usage` succeeds: a 429 on `/usage` throws before the prepaid fetch runs.

### 3.4 Accessibility

#### A1: The menu bar item gives VoiceOver no usage values
- **Severity:** medium
- **Confidence:** medium (was high)
- **File:** `Sources/FuelGauge/MenuBarLabel.swift:14-16`, `:44-50`; `Sources/FuelGauge/App.swift:13-15`
- **Code:**
  ```swift
  var body: some View {
      Image(nsImage: render())
  }
  ...
  let image = NSImage(cgImage: cg, size: ...)
  image.isTemplate = true
  return image
  ```
- **Why it matters:** Provider names, percentages, countdowns and the ⚠︎ marker are all rasterised into one bitmap. Neither the `Image` nor the `NSImage` has a label or description, and `MenuBarExtra` is built with a `label:` closure rather than a title. VoiceOver can at best announce the app name or "image".
- **Failure scenario:** A VoiceOver user moves to the status item to check whether Claude is exhausted and hears no values, so they must open the panel and walk every row.
- **Suggested fix:** Build a summary string from `items` (e.g. "Claude: session 45%, weekly 80%. ChatGPT 12%, rate limited") and apply `.accessibilityLabel(summary)` to the `Image`. Also set `image.accessibilityDescription = summary`, so whichever path `MenuBarExtra` uses for the `NSStatusBarButton` exposes it.
- **Verification:** **downgraded** in confidence. That the label is missing is certain. What VoiceOver actually announces, and which of the two fixes `MenuBarExtra` honours, can only be confirmed on a Mac.

#### A2: Pace info and remaining credit amounts are hover-only, and the bars aren't accessibility elements
- **Severity:** medium
- **Confidence:** high
- **File:** `Sources/FuelGauge/App.swift:188-195`, `:223-230`, `:239-262`
- **Code:**
  ```swift
  UsageBar(used: window.usedPercent, expected: expected, tint: tint)
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
  if isHovering, let expected {
      Text(paceDescription(expected: expected)) ...
  ```
  ```swift
  if isHovering, credit.usedPercent != nil {
      Text(credit.summary()) ...
  ```
- **Why it matters:** The even-pace comparison and, for credits with a known total, the money left exist only while a pointer hovers. VoiceOver, keyboard and Switch Control users can't hover. `UsageBar` is a `GeometryReader` of shapes with no accessibility representation, and rows aren't grouped.
- **Failure scenario:** A VoiceOver user hears "Cloud credits, 25%" and can never learn "$75.00 of $100.00 left", or whether they're ahead of pace on any window.
- **Suggested fix:** Apply `.accessibilityElement(children: .combine)` per row. On the bar, use `.accessibilityLabel(window.label)` and `.accessibilityValue("\(pct)% used, \(paceDescription)")`, or switch to `Gauge`/`ProgressView(value:)`. Always include `credit.summary()` in the credit row's accessibility value.
- **Verification:** **confirmed**. Hover-to-reveal is a documented visual design (README), but that decision doesn't cover assistive tech, and the fix leaves the visual unchanged.

#### A3: Providers can only be reordered by mouse drag
- **Severity:** low
- **Confidence:** high
- **File:** `Sources/FuelGauge/App.swift:46-57`, `:79-85`
- **Code:**
  ```swift
  .onDrag { ... }
  .onDrop(of: [.text], delegate: ReorderDropDelegate(target: p.id, dragging: $dragging, store: store))
  ```
- **Why it matters:** Order drives both the panel and the menu bar, but the only way to change it is a drag. There is no accessibility action, keyboard path or menu command.
- **Failure scenario:** A VoiceOver or keyboard-only user can't move Copilot first.
- **Suggested fix:** Add `.accessibilityAction(named: "Move up")` / `"Move down"` per card that call `store.move`, or add Move Up / Move Down items in the gear menu's Show section.
- **Verification:** **confirmed**.

#### A4: The gear menu, the only way to reach Refresh, Show, Updates and Quit, is icon-only
- **Severity:** low
- **Confidence:** medium
- **File:** `Sources/FuelGauge/App.swift:73-95`
- **Code:**
  ```swift
  Menu { ... } label: {
      Image(systemName: "gearshape")
  }
  .menuStyle(.borderlessButton)
  ```
- **Why it matters:** There is no text label. VoiceOver relies on the symbol's built-in description, and Voice Control has no meaningful name to target.
- **Failure scenario:** "Click Settings" in Voice Control matches nothing, and a VoiceOver user has to explore the menu to find Quit.
- **Suggested fix:** `Menu { … } label: { Label("Settings", systemImage: "gearshape") }.labelStyle(.iconOnly)`.
- **Verification:** **confirmed**. This matches the SwiftUI accessibility guidance, which flags icon-only controls without text. The exact phrase VoiceOver reads for `gearshape` needs a Mac to check.

### 3.5 Test quality

#### T1: The riskiest logic (refresh scheduling, retry handling, HTTP status mapping) has no tests
- **Severity:** medium
- **Confidence:** high
- **File:** `Package.swift:18`. Untested: `Sources/FuelGauge/UsageStore.swift:67-149` (`init` restore, `tick`, `needsFetch`, `fetch`), `Sources/UsageCore/Support.swift:35-49` (`HTTP.getJSON`), and `Sources/UsageCore/ClaudeTokenRefresher.swift:47-57` (sharing of concurrent calls).
- **Code:**
  ```swift
  .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
  ```
  ```swift
  case 401, 403: throw UsageError.tokenExpired(expiredHint)
  case 429:
      let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
      throw UsageError.rateLimited(retryAfter: parseRetryAfter(header))
  ```
- **Why it matters:** The parsers are well tested. The code that decides *when* to call rate-limited, undocumented APIs (stale vs exhausted vs reset-passed, restoring and filtering `retryAt`, keeping `last` on failure) is where P1, C3 and UI3 live, and it has no tests at all. `UsageStore` hard-codes `UserDefaults.standard`, `Date()` and concrete providers. `HTTP` uses `URLSession.shared` with no seam. `claudeRefresherBacksOffAfterFailure` calls `refresh` only sequentially, so it never exercises the `inFlight` sharing that the actor exists for.
- **Failure scenario:** A refactor maps 429 to `.http`, or makes `needsFetch` return `false` for `.failed`. Backoff silently disappears and the whole suite still passes.
- **Suggested fix:** Move the policy into `UsageCore` as a pure `needsFetch(state:updatedAt:now:refreshInterval:)` plus a `RetryPolicy`, or give `UsageStore` injected `UserDefaults(suiteName:)`, clock and providers, and add a `FuelGaugeTests` target. Inject a transport closure or `URLProtocol` into `HTTP`. Add a gated concurrent refresher test.
- **Verification:** **confirmed**.

#### T2: Indexing after a non-fatal `#expect` can crash the test runner
- **Severity:** low
- **Confidence:** high, narrowed to one line
- **File:** `Tests/UsageCoreTests/ParsingTests.swift:16` (and the force unwrap at `:96`)
- **Code:**
  ```swift
  #expect(u.windows.map(\.label) == ["Session (5h)", "Weekly", "Extra usage"])
  #expect(u.windows[0].resetsAt != nil)
  #expect(u.windows[2].detail == "$12.34 / $50.00")
  ```
- **Why it matters:** `#expect` records a failure and carries on. If the Claude parser returns two windows, `u.windows[2]` traps and kills the whole `swift test` process, so the per-test results are lost.
- **Failure scenario:** A regression drops "Extra usage", and CI shows `Fatal error: Index out of range` instead of the label diff.
- **Suggested fix:** Add `try #require(u.windows.count == 3)` before indexing, and replace `w.expectedPercent(at: now)!` with `try #require(...)`.
- **Verification:** **downgraded** in scope. The cited Copilot lines (`:86-90`, `:107`) can't trap, because `CopilotProvider.parse` always returns at least one window (it appends "Unlimited" when none are found), and `ClaudeProvider.parse` throws on empty, so `windows[0]` at `:15` is safe. Only `windows[2]` at `:16` and the `!` at `:96` are real crash points.

---

## 4. Plan of action

| PR | Size | Covers | Change | Tests to add with it |
|----|------|--------|--------|----------------------|
| 1. Bounded subprocesses | M | C1 | Add a deadline, live pipe draining and a cancellation handler to `Shell.run`, with exactly-once resume. | `shellRunTimesOut` (run `sleep 30` with a 0.5 s deadline, expect a throw within 2 s and that the child is gone), `shellRunDrainsLargeOutput` (`head -c 200000 /dev/zero` returns 200 000 bytes), `shellRunCancelsChild` (cancel the task, expect the child to be killed). |
| 2. Testable refresh policy | L | T1, P1, C2, C3, UI3 | Extract `needsFetch`/`RetryPolicy` into `UsageCore`. Inject defaults, clock and providers into `UsageStore`. Add per-provider `inFlight`, `pendingRefresh`, back-off instead of stop for exhausted providers, and stamp `lastRefresh` only on success. Add an `HTTP` transport seam. | Parameterised `needsFetch` over fresh / stale / exhausted / reset-passed / extra-usage-with-exhausted-weekly / credits. `retryAtRestoreFiltersPast`. `httpMapsStatus` over 200/401/403/429-seconds/429-date/500. `refresherSharesConcurrentAttempt` (two concurrent calls on a gated stub, `calls == 1`). `setVisibleDoesNotDoubleFetch`. `resetDuringRefreshSchedulesFollowUp`. `lastRefreshUnchangedWhenAllFail`. |
| 3. Time-aware panel text | S | UI2, UI1, UI4 | Add `TimelineView(.everyMinute)` and directional relative text with a past branch. Add a container-level drop handler and an `onDisappear` reset for `dragging`. Add `LaunchAtLogin.reload()` on appear. | A unit test for the extracted "reset label" formatter (future, past and nil), with a fixed `now`. A manual check of the drag and Login Items cases (section 5). |
| 4. Accessibility pass | M | A1, A2, A3, A4 | Add a spoken summary on the status item, combined rows with accessibility values, Move Up/Down actions, and a labelled gear menu. | A unit test for the `MenuBarItem` → summary string builder (exhausted countdown, rate-limited, two-window case). Accessibility Inspector audit (section 5). |
| 5. AppKit/Sparkle hygiene | S | UI7, UI6, UI5 | Add gentle-reminder delegate methods with an `updateAvailable` badge, use `NSApp.activate()`, and render the menu bar image at a fixed 2x. | Unit-test the `Updates` reminder state transitions with a fake state (will-show leads to badge on, attention leads to badge off). Manual Sparkle check (section 5). |
| 6. Credential sources | S | P2, P4 | Resolve `CODEX_HOME`/`GITHUB_TOKEN` via a login shell (using PR 1's timeout) or fix the README. Include the path tried in the error. Don't reuse `last` org/balance across a token change when `/profile` fails. | `ClaudePrepaidCredits` test with a stub transport (from PR 2): token A succeeds, then token B gets a `/profile` failure, and the result must be `nil`. `chatgptReportsTriedPath`. |
| 7. Test hygiene | S | T2 | Replace index-after-`#expect` and the `!` with `#require`. | None new. The existing tests get safer. |

Recommended order: 1 → 2 → 4 → 3 → 5 → 6, with 7 any time. PR 2 depends on PR 1 only for the shared transport and process seams.

## 5. Needs a Mac to confirm

| Finding | Check that would settle it |
|---------|----------------------------|
| All | `swift build -c release 2>&1 \| tee build.log` with Xcode 16+ (Swift 6 mode is already complete strict concurrency). Then `swift test` and `swift test --sanitize=thread` to make sure the existing suite is clean under TSan before the PR 2 concurrency changes. |
| C1 | After PR 1: `swift test --filter UsageCoreTests.shellRunTimesOut` and `--filter shellRunDrainsLargeOutput`. Before the fix, reproduce by running `security lock-keychain ~/Library/Keychains/login.keychain-db`, then Refresh, then leave the unlock dialog unanswered: the footer should stay on "Refreshing…" and ChatGPT/Copilot should stop updating. Sample the stuck `security` process with Activity Monitor › Sample, or with `sample <pid>`. |
| C2, C3 | After PR 2: `swift test --filter setVisibleDoesNotDoubleFetch` and `--filter resetDuringRefreshSchedulesFollowUp`. Before the fix, watch a Network or os_signpost trace in Instruments (Network template) while toggling Claude off and on during a refresh, and count `/api/oauth/usage` requests. |
| P1 | `swift test --filter needsFetch` (PR 2), including the "exhausted weekly + extra usage" case. |
| T1 | `swift test --filter refresherSharesConcurrentAttempt` and `swift test --filter httpMapsStatus`. |
| UI1 | Manual: drag a card and release it over the footer, then press Esc mid-drag. The card must return to full opacity, including after closing and reopening the panel. |
| UI2 | Manual with a stub provider whose `resetsAt` is `now + 70 s` and whose fetch fails. With the panel open past the reset, the row must not count up. Use the Instruments SwiftUI template to confirm `TimelineView` re-renders only that row once a minute. |
| UI4 | Manual: toggle Fuel Gauge off in System Settings › General › Login Items, reopen the panel, and check the toggle. Log `SMAppService.mainApp.status` after `register()` while the item is disabled in System Settings to see whether `.requiresApproval` comes back. |
| UI5 | Manual: attach a 1x external display with "Displays have separate Spaces" on, focus a window on each screen in turn, and zoom into the menu bar label (Accessibility › Zoom) to check for blur. |
| UI6 | Check the build log for `'activate(ignoringOtherApps:)' was deprecated in macOS 14.0`. Manual: Check for Updates… from the panel while another app is frontmost, and confirm the Sparkle window comes to the front. |
| UI7 | Point a debug build at a local appcast with a higher version, set `defaults write com.effectivebits.FuelGauge SUScheduledCheckInterval -int 60`, make another app frontmost, and wait. Observe whether Sparkle's alert is visible or hidden behind, and check Console for Sparkle's gentle-reminder log lines. |
| A1 | VoiceOver (⌘F5): VO-M twice to reach menu extras, arrow to Fuel Gauge, and record what is spoken. In Accessibility Inspector, target the status item and check the `AXDescription`/`AXTitle` of the `NSStatusBarButton` before and after the fix. |
| A2, A3 | Accessibility Inspector › Audit on the open panel. VoiceOver walk-through of one window row and one credit row: the value must include the pace text and "… left". Check the actions rotor for "Move up" / "Move down". |
| A4 | Voice Control: say "Show names" and check the gear's name, then say "Click Settings". Check the gear's `AXDescription` in Accessibility Inspector. |
| T2 | Temporarily delete the `extra_usage` key from the fixture and run `swift test --filter claudeParsesWindowsAndExtraUsage`. Before the fix the process traps; after, the test reports a `#require` failure. |

---

## Appendix: Dropped findings

| ID | Title | Reason dropped |
|----|-------|----------------|
| P3 | `Retry-After` has no upper bound, is persisted, and even manual Refresh can't override it | The README documents the deliberate choice to wait "as long as the `Retry-After` header asks before calling that provider again", and the code follows it. The clamp and manual override contradict that. The remaining risk (a misbehaving server sending a month-long value) is hypothetical. |
