import SwiftUI
import UsageCore

@main
struct FuelGaugeApp: App {
    @State private var store = UsageStore()
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var updates = Updates()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store, launchAtLogin: launchAtLogin, updates: updates)
        } label: {
            MenuBarLabel(items: store.menuBarItems)
        }
        .menuBarExtraStyle(.window)
    }
}

struct UsagePanel: View {
    let store: UsageStore
    let launchAtLogin: LaunchAtLogin
    let updates: Updates
    @State private var dragging: String?
    @State private var hovered: String?

    static let width: CGFloat = 320
    static let padding: CGFloat = 14
    static let cardInset: CGFloat = 6

    private func card(for p: any UsageProvider) -> some View {
        ProviderSection(provider: p, state: store.states[p.id] ?? .loading, retryAt: store.retryAt[p.id])
            .padding(Self.padding - Self.cardInset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.visibleProviders, id: \.id) { p in
                    card(for: p)
                        .background(hovered == p.id ? Color.primary.opacity(0.07) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onHover { hovered = $0 ? p.id : (hovered == p.id ? nil : hovered) }
                        .opacity(dragging == p.id ? 0.4 : 1)
                        .onDrag {
                            dragging = p.id
                            hovered = nil
                            return NSItemProvider(object: p.id as NSString)
                        } preview: {
                            // The default preview is transparent; draw the card on an opaque background.
                            card(for: p)
                                .frame(width: Self.width - 2 * Self.cardInset)
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        }
                        .onDrop(of: [.text], delegate: ReorderDropDelegate(target: p.id, dragging: $dragging, store: store))
                }
            }
            // Cards bleed into the panel margin so their content lines up with the footer.
            .padding([.horizontal, .top], -(Self.padding - Self.cardInset))
            if let err = launchAtLogin.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
                } else if let t = store.lastRefresh {
                    Text("Updated \(t, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Refresh") { Task { await store.refresh() } }
                        .keyboardShortcut("r")
                        .disabled(store.isRefreshing)
                    Toggle("Open at Login", isOn: Binding(get: { launchAtLogin.isEnabled },
                                                          set: { launchAtLogin.set($0) }))
                    Section("Show") {
                        ForEach(store.orderedProviders, id: \.id) { p in
                            Toggle(p.name, isOn: Binding(get: { store.layout.isVisible(p.id) },
                                                         set: { store.setVisible(p.id, $0) }))
                                .disabled(!store.layout.canToggle(p.id))
                        }
                    }
                    Divider()
                    CheckForUpdatesButton(updates: updates)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .resizesHostingWindowToFit()
    }
}

/// Live-reorders providers as a dragged section passes over another one.
struct ReorderDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let store: UsageStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct ProviderSection: View {
    let provider: any UsageProvider
    let state: ProviderState
    var retryAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderIcon(providerID: provider.id).frame(width: 16, height: 16)
                Text(provider.name).font(.headline)
                if let plan = state.usage?.plan {
                    Text(plan).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if case .loading = state { ProgressView().controlSize(.mini) }
            }
            if let usage = state.usage {
                ForEach(usage.windows) { WindowRow(window: $0) }
                ForEach(usage.credits) { CreditRow(credit: $0) }
            }
            if case .failed(let msg, _, let last, let at) = state {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(msg)
                        if let retryAt, retryAt > Date() {
                            Text("Next attempt in \(retryAt, style: .relative).")
                        }
                        if last != nil, let at {
                            Text("Showing last known values from \(at, style: .relative) ago.")
                        }
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func usageTint(_ percent: Double) -> Color {
    switch percent {
    case ..<60: .green
    case ..<85: .yellow
    default: .red
    }
}

struct WindowRow: View {
    let window: UsageWindow

    private var tint: Color { usageTint(window.usedPercent) }

    @State private var isHovering = false

    var body: some View {
        let expected = window.expectedPercent()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).font(.subheadline)
                Spacer()
                if let d = window.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                Text("\(Int(window.usedPercent.rounded()))%").font(.subheadline).monospacedDigit()
            }
            UsageBar(used: window.usedPercent, expected: expected, tint: tint)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
            if isHovering, let expected {
                Text(paceDescription(expected: expected)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let r = window.resetsAt {
                Text("Resets \(r, style: .relative)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func paceDescription(expected: Double) -> String {
        let diff = Int((window.usedPercent - expected).rounded())
        let pace = diff == 0 ? "right on pace" : diff > 0 ? "\(diff)% ahead of pace" : "\(-diff)% under pace"
        return "Even pace: \(Int(expected.rounded()))% by now · \(pace)"
    }
}

/// A credit balance shown like a usage limit: the share spent, with the amount left on hover.
struct CreditRow: View {
    let credit: CreditBalance

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(credit.label).font(.subheadline)
                Spacer()
                if let used = credit.usedPercent {
                    Text("\(Int(used.rounded()))%").font(.subheadline).monospacedDigit()
                } else {
                    Text(credit.summary()).font(.subheadline).monospacedDigit()
                }
            }
            if let used = credit.usedPercent {
                UsageBar(used: used, expected: nil, tint: usageTint(used))
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
            }
            if isHovering, credit.usedPercent != nil {
                Text(credit.summary()).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let e = credit.expiresAt {
                Text(e > Date() ? "Expires \(e.formatted(date: .abbreviated, time: .omitted))" : "Expired")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Usage bar with an optional even-pace marker.
struct UsageBar: View {
    let used: Double
    let expected: Double?
    let tint: Color

    static let height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: w * min(used, 100) / 100)
            }
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                if let expected {
                    PaceMarker().offset(x: min(max(w * expected / 100, 2), w - 2) - PaceMarker.width / 2)
                }
            }
        }
        .frame(height: Self.height)
    }
}

/// A tick that stands out on any bar color: a primary-colored line outlined in the window background.
struct PaceMarker: View {
    static let width: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.primary)
            .frame(width: 2)
            .padding(.horizontal, 1)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 2))
            .frame(width: Self.width, height: UsageBar.height + 4)
    }
}
