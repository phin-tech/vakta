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

    /// True while any list is open (hovered or pinned); Auto-hide holds the
    /// bar revealed meanwhile. Hover-opened lists are tracked per popover, so
    /// moving from one to the other can't release the hold with a late close.
    @Published private(set) var isAnyPopoverOpen = false
    /// The list opened by a click or "Show Pull Requests": stays open without
    /// hover and takes ↑/↓/Return/Escape.
    @Published private(set) var pinned: StatusBarPopover?
    /// The selected row of the pinned list (flattened across groups).
    @Published private(set) var selection: Int?
    /// Bumped to tell hover-opened lists to close (Escape).
    @Published private(set) var closeGeneration = 0
    private var hoverOpen: Set<StatusBarPopover> = []

    func setPopover(_ popover: StatusBarPopover, open: Bool) {
        if open { hoverOpen.insert(popover) } else { hoverOpen.remove(popover) }
        updateOpen()
    }

    func togglePin(_ popover: StatusBarPopover) {
        pinned == popover ? closeAll() : pin(popover)
    }

    func pin(_ popover: StatusBarPopover) {
        pinned = popover
        selection = nil
        updateOpen()
    }

    /// Closes every list, pinned or hovered.
    func closeAll() {
        pinned = nil
        selection = nil
        if !hoverOpen.isEmpty {
            hoverOpen.removeAll()
            closeGeneration += 1
        }
        updateOpen()
    }

    /// Returns whether the key was consumed. Escape closes any open list;
    /// the arrows and Return act only on a pinned list; anything else
    /// passes through to the terminal.
    func handle(_ action: StatusBarListAction) -> Bool {
        switch action {
        case .close:
            guard pinned != nil || !hoverOpen.isEmpty else { return false }
            closeAll()
            return true
        case .up, .down:
            guard let pinned else { return false }
            selection = StatusBarListKey.moved(selection, by: action == .up ? -1 : 1, count: rows(for: pinned).count)
            return true
        case .open:
            guard let pinned else { return false }
            let rows = rows(for: pinned)
            if let index = StatusBarListKey.moved(selection, by: 0, count: rows.count), selection != nil,
               let url = rows[index] {
                openURL(url)
            }
            closeAll()
            return true
        }
    }

    /// Each row's URL, in display order (a check without a page has none).
    func rows(for popover: StatusBarPopover) -> [String?] {
        switch popover {
        case .checks: return content.pullRequest?.checks.map(\.url) ?? []
        case .pullRequests: return content.pullRequestGroups.flatMap { $0.pullRequests.map { Optional($0.url) } }
        }
    }

    private func updateOpen() {
        let open = pinned != nil || !hoverOpen.isEmpty
        if open != isAnyPopoverOpen { isAnyPopoverOpen = open }
    }
}

enum StatusBarPopover: Hashable {
    case checks
    case pullRequests
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
                            .accessibilityLabel("\(label) checks passing")
                    }
                }
                .listPopover(.checks, model: model, isEnabled: pullRequest.checksLabel != nil) {
                    StatusBarChecksList(
                        pullRequest: pullRequest,
                        selection: model.pinned == .checks ? model.selection : nil,
                        openURL: model.openURL
                    )
                }
            }
            Spacer(minLength: 8)
            if content.showsPullRequestList || model.pinned == .pullRequests {
                let glyph = content.listGlyph ?? .noChecks
                HStack(spacing: 3) {
                    Image(systemName: Self.symbol(for: glyph))
                        .foregroundStyle(Self.color(for: glyph))
                    Text(content.listLabel)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(content.listLabel) across all sessions")
                .listPopover(.pullRequests, model: model, isEnabled: true) {
                    StatusBarPullRequestList(
                        groups: content.pullRequestGroups,
                        focusedURL: content.pullRequest?.url,
                        selection: model.pinned == .pullRequests ? model.selection : nil,
                        openURL: model.openURL
                    )
                }
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

    static func symbol(for glyph: StatusBarGlyph) -> String {
        switch glyph {
        case .failing: return "xmark.circle.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .pending: return "clock.fill"
        case .passing: return "checkmark.circle"
        case .readyToMerge: return "checkmark.circle.fill"
        case .noChecks: return "arrow.triangle.pull"
        }
    }

    /// Green is reserved for "ready to merge"; passing checks alone are an
    /// outlined, muted check.
    static func color(for glyph: StatusBarGlyph) -> Color {
        switch glyph {
        case .failing, .changesRequested: return .red
        case .pending: return .yellow
        case .readyToMerge: return .green
        case .passing, .noChecks: return .secondary
        }
    }

    private static func help(for pullRequest: StatusBarPullRequest) -> String {
        let state: String
        switch pullRequest.glyph {
        case .failing: state = "checks failing"
        case .changesRequested: state = "changes requested"
        case .pending: state = "checks pending"
        case .passing: state = "checks passing, not mergeable yet"
        case .readyToMerge: state = "ready to merge"
        case .noChecks: state = "no checks"
        }
        let draft = pullRequest.isDraft ? "Draft · " : ""
        return "\(draft)#\(pullRequest.number) \(pullRequest.title) — \(state). Click to open."
    }
}

/// A status bar list: opens when the pointer rests on the content and
/// stays open while it's over the content or the list (a separate window);
/// a click pins it open (again: closes). The model owns pinning, keyboard
/// selection, and Escape; `closeGeneration` closes a hover-opened list.
private struct ListPopover<List: View>: ViewModifier {
    let popover: StatusBarPopover
    @ObservedObject var model: StatusBarViewModel
    let isEnabled: Bool
    let list: () -> List

    @State private var isHoverShown = false
    @State private var isOverContent = false
    @State private var isOverList = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { isOverContent = $0 && isEnabled; hoverChanged() }
            .onTapGesture { if isEnabled { model.togglePin(popover) } }
            .popover(isPresented: presented, arrowEdge: .top) {
                list().onHover { isOverList = $0; hoverChanged() }
            }
            .onChange(of: isHoverShown) { model.setPopover(popover, open: $0) }
            .onChange(of: model.closeGeneration) { _ in resetHover() }
            .onChange(of: isEnabled) { enabled in
                guard !enabled else { return }
                resetHover()
                if model.pinned == popover { model.closeAll() }
            }
            // The content can vanish with the list open (focus moved to a
            // pane without a PR); release the hold.
            .onDisappear {
                resetHover()
                model.setPopover(popover, open: false)
                if model.pinned == popover { model.closeAll() }
            }
    }

    /// Shown while hovered or pinned; dismissing it (clicking elsewhere)
    /// closes it either way.
    private var presented: Binding<Bool> {
        Binding(
            get: { isHoverShown || model.pinned == popover },
            set: { shown in
                guard !shown else { return }
                resetHover()
                if model.pinned == popover { model.closeAll() }
            }
        )
    }

    private func resetHover() {
        pending?.cancel()
        isOverContent = false
        isOverList = false
        if isHoverShown { isHoverShown = false }
    }

    private func hoverChanged() {
        pending?.cancel()
        let wanted = isOverContent || isOverList
        guard wanted != isHoverShown else { return }
        let work = DispatchWorkItem { isHoverShown = isOverContent || isOverList }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wanted ? 0.3 : 0.35), execute: work)
    }
}

private extension View {
    func listPopover<List: View>(
        _ popover: StatusBarPopover,
        model: StatusBarViewModel,
        isEnabled: Bool,
        @ViewBuilder list: @escaping () -> List
    ) -> some View {
        modifier(ListPopover(popover: popover, model: model, isEnabled: isEnabled, list: list))
    }
}

/// Row chrome shared by the lists: the keyboard selection is an accent fill,
/// the focused pane's PR a faint one.
private struct StatusBarRowBackground: ViewModifier {
    let isSelected: Bool
    var isFocused = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(
                    isSelected ? Color.accentColor.opacity(0.35)
                        : isFocused ? Color.accentColor.opacity(0.12) : .clear
                )
            )
            .contentShape(Rectangle())
    }
}

/// Every PR across all sessions, grouped by session › workspace (current
/// first), worst first within a group; the focused PR highlighted. A row
/// opens its PR; a pinned list also takes ↑/↓/Return (see the model).
struct StatusBarPullRequestList: View {
    let groups: [StatusBarPullRequestGroup]
    let focusedURL: String?
    let selection: Int?
    let openURL: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(numberedGroups.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.group.title + (entry.group.isCurrent ? " · this workspace" : ""))
                                    .font(.system(size: 11, weight: entry.group.isCurrent ? .semibold : .regular))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                ForEach(Array(entry.group.pullRequests.enumerated()), id: \.offset) { offset, pullRequest in
                                    row(pullRequest, index: entry.firstRow + offset).id(entry.firstRow + offset)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
                .onChange(of: selection) { index in
                    if let index { proxy.scrollTo(index) }
                }
            }
            if groups.isEmpty {
                Text("No open pull requests in any pane").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .frame(width: 380)
    }

    /// Groups paired with the flattened index of their first row, matching
    /// `StatusBarViewModel.rows(for:)`.
    private var numberedGroups: [(group: StatusBarPullRequestGroup, firstRow: Int)] {
        var next = 0
        return groups.map { group in
            defer { next += group.pullRequests.count }
            return (group, next)
        }
    }

    private func row(_ pullRequest: StatusBarPullRequest, index: Int) -> some View {
        Button {
            openURL(pullRequest.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: StatusBarView.symbol(for: pullRequest.glyph))
                    .foregroundStyle(StatusBarView.color(for: pullRequest.glyph))
                Text("#\(pullRequest.number)")
                    .monospacedDigit()
                    .foregroundStyle(pullRequest.isDraft ? .secondary : .primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pullRequest.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(pullRequest.branch)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let label = pullRequest.checksLabel {
                    Text(label)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .modifier(StatusBarRowBackground(isSelected: index == selection, isFocused: pullRequest.url == focusedURL))
        }
        .buttonStyle(.plain)
        .help(pullRequest.glyph == .readyToMerge ? "Ready to merge — open #\(pullRequest.number)" : "Open #\(pullRequest.number)")
    }
}

/// Every check of the focused PR: failing, pending, passing, then by name.
/// A row with a details page opens it.
struct StatusBarChecksList: View {
    let pullRequest: StatusBarPullRequest
    let selection: Int?
    let openURL: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("#\(pullRequest.number) checks · \(pullRequest.checksLabel ?? "0/0") passing")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(pullRequest.checks.enumerated()), id: \.offset) { index, check in
                        row(check, isSelected: index == selection)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(10)
        .frame(width: 300)
    }

    private func row(_ check: PullRequestCheck, isSelected: Bool) -> some View {
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
            .modifier(StatusBarRowBackground(isSelected: isSelected))
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
