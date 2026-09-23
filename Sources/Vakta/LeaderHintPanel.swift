//
//  LeaderHintPanel.swift
//  Vakta
//
//  The which-key overlay for leader sequences: a borderless, non-activating
//  child panel along the bottom of the main window that lists what each next
//  key does (`LeaderHintAssembler`). It never becomes key, so the terminal
//  keeps first responder and `KeybindingMatcher` keeps receiving the
//  sequence; it ignores the mouse and never hosts or reparents a terminal
//  view.
//
//  Shown after `LeaderSettings.hintDelay` (a preference) so a fast, memorized
//  sequence doesn't flash it; once visible it follows each step immediately.

import AppKit
import Combine
import SwiftUI

/// A panel that can never take key or main status.
private final class LeaderHintWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct LeaderHintTheme {
    var background: Color
    var accent: Color
    var isDark: Bool
}

struct LeaderHintView: View {
    let breadcrumb: String
    let hints: [LeaderHint]
    let theme: LeaderHintTheme

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(breadcrumb)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(hints, id: \.keyCode) { hint in
                    HStack(spacing: 6) {
                        Text(hint.key)
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundStyle(theme.accent)
                            .frame(minWidth: 28, alignment: .trailing)
                        Text("→")
                            .foregroundStyle(.tertiary)
                        Text(hint.isGroup ? "+\(hint.title)" : hint.title)
                            .font(.system(.body, design: .monospaced).weight(hint.isCurrent ? .bold : .regular))
                            .foregroundStyle(hint.isGroup ? theme.accent : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if hint.isCurrent {
                            Text("●")
                                .font(.caption2)
                                .foregroundStyle(theme.accent)
                                .accessibilityLabel("current")
                        }
                    }
                    // Stay inside the grid column; a long title truncates
                    // rather than running into the next column.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.background)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Owns the panel and follows `KeybindingMatcher.leaderPath`. Started by the
/// app delegate; `stop()` ends the subscription and any pending show.
@MainActor
final class LeaderHintOverlay {
    private let matcher: KeybindingMatcher
    private let contextProvider: () -> CommandContext
    private let themeProvider: () -> LeaderHintTheme
    private let parentWindowProvider: () -> NSWindow?
    private let contentChanged: AnyPublisher<Void, Never>

    private var panel: LeaderHintWindow?
    private var host: NSHostingController<LeaderHintView>?
    private var subscription: AnyCancellable?
    private var contentSubscription: AnyCancellable?
    private var pendingShow: Task<Void, Never>?

    init(
        matcher: KeybindingMatcher,
        contextProvider: @escaping () -> CommandContext,
        themeProvider: @escaping () -> LeaderHintTheme,
        parentWindowProvider: @escaping () -> NSWindow?,
        contentChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.matcher = matcher
        self.contextProvider = contextProvider
        self.themeProvider = themeProvider
        self.parentWindowProvider = parentWindowProvider
        self.contentChanged = contentChanged
    }

    func start() {
        guard subscription == nil else { return }
        // Use the emitted value: `@Published` emits in willSet, so rereading
        // `matcher.leaderPath` here would see the previous path.
        subscription = matcher.$leaderPath
            .removeDuplicates()
            .sink { [weak self] path in self?.follow(path) }
        // Row labels come from live data (workspace names); redraw a visible
        // overlay when it changes.
        contentSubscription = contentChanged.sink { [weak self] in
            guard let self, self.panel?.isVisible == true, let path = self.matcher.leaderPath else { return }
            self.show(path)
        }
    }

    func stop() {
        subscription = nil
        contentSubscription = nil
        hide()
    }

    private func follow(_ path: [UInt16]?) {
        guard let path else { return hide() }
        if panel?.isVisible == true {
            show(path)
            return
        }
        pendingShow?.cancel()
        let delay = matcher.leaderSettings.hintDelay
        guard delay > .zero else { return show(path) }
        pendingShow = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Still pending after the delay? Show wherever the sequence is now.
            if let current = self.matcher.leaderPath { self.show(current) }
        }
    }

    private func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func show(_ path: [UInt16]) {
        let hints = LeaderHintAssembler.hints(root: matcher.leaderRoot, path: path, context: contextProvider())
        guard !hints.isEmpty, let parent = parentWindowProvider() else { return hide() }

        let theme = themeProvider()
        let view = LeaderHintView(
            breadcrumb: LeaderHintAssembler.breadcrumb(leaderChord: matcher.leaderSettings.chordDisplayString, path: path),
            hints: hints,
            theme: theme
        )
        let panel = self.panel ?? makePanel()
        let host: NSHostingController<LeaderHintView>
        if let existing = self.host {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingController(rootView: view)
            // The panel's frame is set explicitly below; don't let the
            // hosting controller resize the window to its ideal size.
            host.sizingOptions = []
            panel.contentViewController = host
            self.host = host
        }
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)

        // Full width of the window's content, pinned to its bottom edge, as
        // tall as the rows need *at that width* (the adaptive grid's row
        // count depends on it; `fittingSize` would measure unconstrained).
        let content = parent.contentRect(forFrameRect: parent.frame)
        let measured = host.sizeThatFits(in: CGSize(width: content.width, height: content.height))
        let height = min(ceil(measured.height), content.height)
        panel.setFrame(NSRect(x: content.minX, y: content.minY, width: content.width, height: height), display: true)

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func makePanel() -> LeaderHintWindow {
        let panel = LeaderHintWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}
