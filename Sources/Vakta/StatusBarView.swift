//
//  StatusBarView.swift
//  Vakta
//
//  The thin bar under the terminal: a projection of `StatusBarContent`
//  (computed by `StatusBarPresentation`), hosted by `AppDelegate` in the
//  terminal wrapper, never around the terminal host itself.
//

import SwiftUI

@MainActor
final class StatusBarViewModel: ObservableObject {
    @Published var content = StatusBarContent(branch: nil, pullRequest: nil, attentionElsewhere: 0)
    var openURL: (String) -> Void = { _ in }
}

struct StatusBarView: View {
    static let height: CGFloat = 22

    @ObservedObject var model: StatusBarViewModel

    var body: some View {
        let content = model.content
        HStack(spacing: 6) {
            if let branch = content.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            if let pullRequest = content.pullRequest {
                if content.branch != nil {
                    Text("·").foregroundStyle(.tertiary)
                }
                Button {
                    model.openURL(pullRequest.url)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: Self.symbol(for: pullRequest.glyph))
                            .foregroundStyle(Self.color(for: pullRequest.glyph))
                        Text("#\(pullRequest.number)")
                            .foregroundStyle(pullRequest.isDraft ? .secondary : .primary)
                    }
                }
                .buttonStyle(.plain)
                .help(Self.help(for: pullRequest))
                .accessibilityLabel(Self.help(for: pullRequest))
            }
            Spacer(minLength: 8)
            if content.attentionElsewhere > 0 {
                Label("\(content.attentionElsewhere)", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help("\(content.attentionElsewhere) other pull request\(content.attentionElsewhere == 1 ? "" : "s") in this session need attention")
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
        }
    }

    private static func symbol(for glyph: StatusBarGlyph) -> String {
        switch glyph {
        case .failing: return "xmark.circle.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .pending: return "clock.fill"
        case .passing: return "checkmark.circle.fill"
        case .noChecks: return "arrow.triangle.pull"
        }
    }

    private static func color(for glyph: StatusBarGlyph) -> Color {
        switch glyph {
        case .failing, .changesRequested: return .red
        case .pending: return .yellow
        case .passing: return .green
        case .noChecks: return .secondary
        }
    }

    private static func help(for pullRequest: StatusBarPullRequest) -> String {
        let state: String
        switch pullRequest.glyph {
        case .failing: state = "checks failing"
        case .changesRequested: state = "changes requested"
        case .pending: state = "checks pending"
        case .passing: state = "checks passing"
        case .noChecks: state = "no checks"
        }
        let draft = pullRequest.isDraft ? "Draft · " : ""
        return "\(draft)#\(pullRequest.number) \(pullRequest.title) — \(state). Click to open."
    }
}

/// A transparent strip over the terminal column's bottom band that reports
/// where the pointer is for Auto-hide: the hot zone (the bottom few points)
/// or the bar's area. `hitTest` returns nil, so clicks, scrolls, and mouse
/// reporting still reach the terminal or the revealed bar underneath; the
/// tracking areas observe without consuming anything.
///
/// The hot zone has its own tracking area: its enter/exit events arrive
/// however the pointer gets there. Deriving it from `mouseMoved` alone missed
/// a pointer that entered the band from above and came to rest at the edge
/// (reported live: Auto-hide was hard to trigger).
final class StatusBarHoverStrip: NSView {
    static let hotZoneHeight: CGFloat = 8

    var onPointer: ((StatusBarPointer) -> Void)?

    private enum Zone: String { case hot, band }
    private var isInHotZone = false
    private var isInBand = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: bounds.width, height: min(Self.hotZoneHeight, bounds.height)),
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: ["zone": Zone.hot.rawValue]
        ))
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: ["zone": Zone.band.rawValue]
        ))
    }

    override func mouseEntered(with event: NSEvent) { update(event, inside: true) }
    override func mouseExited(with event: NSEvent) { update(event, inside: false) }

    private func update(_ event: NSEvent, inside: Bool) {
        switch (event.trackingArea?.userInfo?["zone"] as? String).flatMap(Zone.init(rawValue:)) {
        case .hot?: isInHotZone = inside
        case .band?: isInBand = inside
        case nil: return
        }
        onPointer?(isInHotZone ? .hotZone : isInBand ? .bar : .outside)
    }
}
