import AppKit
import CoreGraphics
import SwiftUI
import BuddyCore

/// Away/back from screen sleep, a switched-out user session, and system idle. No timer of its own:
/// the reaper (only while sessions exist) and the wake notifications call `check`.
@MainActor
final class AwayWatch {
    private var since: Date?
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.since == nil { self?.begin(Date(), model: AppModel.shared) } }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(model: AppModel.shared) }
            })
        }
    }

    /// Starts an away period when input stopped long enough; ends it on fresh input and shows the digest.
    func check(model: AppModel, now: Date = Date()) {
        guard model.awayMinutes > 0 else { since = nil; return }
        let threshold = Double(model.awayMinutes) * 60
        let idle = Self.idleSeconds()
        if let start = since {
            guard idle < 30 else { return }
            since = nil
            if now.timeIntervalSince(start) >= threshold { model.showDigest(since: start, now: now) }
        } else if idle >= threshold {
            begin(now.addingTimeInterval(-idle), model: model)
        }
    }

    private func begin(_ start: Date, model: AppModel) {
        since = start
        model.clearLastDigest()
    }

    static func idleSeconds() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }
}

/// A small panel above a buddy: the tip (click-through) or the away digest (clickable, Esc closes).
@MainActor
final class Callout {
    private let panel: MascotPanel

    init<V: View>(_ view: V, interactive: Bool) {
        panel = MascotPanel(size: NSSize(width: 240, height: 60), canKey: interactive)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.ignoresMouseEvents = !interactive
        panel.orderFrontRegardless()
    }

    var frame: NSRect { panel.frame }
    var isKey: Bool { panel.isKeyWindow }

    func makeKey() { panel.makeKey() }

    func place(above sprite: NSRect) {
        let size = panel.frame.size
        let screen = (NSScreen.screens.first { $0.frame.intersects(sprite) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(sprite.midX - size.width / 2, screen.minX + 4), screen.maxX - size.width - 4)
        let y = min(sprite.maxY + 2, screen.maxY - size.height)
        let o = NSPoint(x: x.rounded(), y: y.rounded())
        if panel.frame.origin != o { panel.setFrameOrigin(o) }
    }

    func close() { panel.orderOut(nil) }
}

struct TipView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .padding(2)
            .accessibilityLabel("Tip: \(text)")
    }
}

struct DigestView: View {
    let lines: [DigestLine]
    let model: AppModel
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("While you were away").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .help("Close (Esc)")
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Button {
                    close()
                    model.openFromDigest(line)
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color(line.kind)).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(line.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(line.kind == .waiting || line.kind == .finished ? "Opens the card" : "Opens the Activity list")
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14).fill(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .padding(2)
    }

    private func color(_ k: DigestLine.Kind) -> Color {
        switch k {
        case .waiting: .orange
        case .finished, .subagentsDone: .green
        case .subagentsFailed: .red
        case .shellsFinished: .blue
        }
    }
}
