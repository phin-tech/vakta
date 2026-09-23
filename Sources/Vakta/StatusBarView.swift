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
    /// The checks popover opened (true) or closed; Auto-hide holds the bar
    /// revealed while it's open.
    var checksPopoverChanged: (Bool) -> Void = { _ in }
}

struct StatusBarView: View {
    static let height: CGFloat = 22

    @ObservedObject var model: StatusBarViewModel

    /// The checks popover opens after the pointer rests on the PR block, and
    /// stays open while it's over the block or the popover itself.
    @State private var showsChecks = false
    /// The pointer is over the PR block (glyph, number, count).
    @State private var isOverChecksLabel = false
    @State private var isOverChecksList = false
    @State private var checksHoverWork: DispatchWorkItem?

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
                // The whole PR block -- glyph, number, check count -- is the
                // hover target for the checks list; clicking the number
                // still opens the PR.
                HStack(spacing: 4) {
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
                    // With checks, the list names the PR; a tooltip would
                    // stack on top of it.
                    .help(pullRequest.checksLabel == nil ? Self.help(for: pullRequest) : "")
                    .accessibilityLabel(Self.help(for: pullRequest))
                    if let label = pullRequest.checksLabel {
                        Text(label)
                            .foregroundStyle(.secondary)
                            .onTapGesture { showsChecks.toggle() }
                            .accessibilityLabel("\(label) checks passing")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard pullRequest.checksLabel != nil else { return }
                    isOverChecksLabel = hovering
                    checksHoverChanged()
                }
                .popover(isPresented: $showsChecks, arrowEdge: .top) {
                    StatusBarChecksList(pullRequest: pullRequest, openURL: model.openURL)
                        .onHover { isOverChecksList = $0; checksHoverChanged() }
                }
                .onChange(of: showsChecks) { model.checksPopoverChanged($0) }
                .onChange(of: pullRequest.checksLabel == nil) { noChecks in
                    // Checks can disappear with the list open.
                    if noChecks { isOverChecksLabel = false; showsChecks = false }
                }
                // The block can vanish with the list open (focus moved to a
                // pane without a PR); release the hold.
                .onDisappear {
                    isOverChecksLabel = false
                    if showsChecks { showsChecks = false }
                    model.checksPopoverChanged(false)
                }
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

    private func checksHoverChanged() {
        checksHoverWork?.cancel()
        let wanted = isOverChecksLabel || isOverChecksList
        guard wanted != showsChecks else { return }
        let work = DispatchWorkItem { showsChecks = isOverChecksLabel || isOverChecksList }
        checksHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wanted ? 0.3 : 0.35), execute: work)
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

/// Every check of the focused PR: failing, pending, passing, then by name.
/// A row with a details page opens it.
struct StatusBarChecksList: View {
    let pullRequest: StatusBarPullRequest
    let openURL: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("#\(pullRequest.number) checks · \(pullRequest.checksLabel ?? "0/0") passing")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(pullRequest.checks.enumerated()), id: \.offset) { _, check in
                        row(check)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(10)
        .frame(width: 300)
    }

    private func row(_ check: PullRequestCheck) -> some View {
        Button {
            if let url = check.url { openURL(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: check.state))
                    .foregroundStyle(Self.color(for: check.state))
                Text(check.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if check.url != nil {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(check.url == nil)
        .help(check.url == nil ? check.name : "Open \(check.name)")
    }

    private static func symbol(for state: PullRequestCheck.State) -> String {
        switch state {
        case .failing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .passing: return "checkmark.circle.fill"
        }
    }

    private static func color(for state: PullRequestCheck.State) -> Color {
        switch state {
        case .failing: return .red
        case .pending: return .yellow
        case .passing: return .green
        }
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
