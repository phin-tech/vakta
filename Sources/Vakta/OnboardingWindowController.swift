//
//  OnboardingWindowController.swift
//  Vakta
//
//  One reused window for the welcome tour and What's New, hosting SwiftUI
//  views via `NSHostingView` like `PreferencesWindowController`. It is a
//  separate window, so it never touches the terminal host, attached as a
//  child of the main window so it stays above it while the user tries the
//  shortcuts it teaches (several commands re-front the main window, and a
//  plain window would drop behind). Closing it by any path (a button, the
//  red button, Escape, ⌘W) runs the current `onClose` once -- the launch
//  uses that to record acknowledgement.

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    enum Content {
        case tutorial([TutorialStep], setup: MultiplexerSetupModel, keybindings: KeybindingMatcher)
        case whatsNew([ReleaseNote])
    }

    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private let parentWindowProvider: () -> NSWindow?

    init(parentWindowProvider: @escaping () -> NSWindow?) {
        self.parentWindowProvider = parentWindowProvider
    }

    func show(_ content: Content, onClose: (() -> Void)? = nil) {
        // Replacing what's shown counts as closing the previous screen.
        finishCurrent()
        self.onClose = onClose

        let window = self.window ?? makeWindow()
        self.window = window
        let close: () -> Void = { [weak window] in window?.performClose(nil) }
        switch content {
        case .tutorial(let steps, let setup, let keybindings):
            window.title = "Welcome to Vakta"
            window.contentView = NSHostingView(rootView: TutorialView(steps: steps, setup: setup, keybindings: keybindings, close: close))
        case .whatsNew(let notes):
            window.title = "What's New in Vakta"
            window.contentView = NSHostingView(rootView: WhatsNewView(notes: notes, close: close))
        }
        // The tour's Mac-style shortcuts step carries a chord table.
        switch content {
        case .tutorial: window.setContentSize(NSSize(width: 540, height: 600))
        case .whatsNew: window.setContentSize(NSSize(width: 520, height: 480))
        }
        if let parent = parentWindowProvider() {
            if window.parent !== parent {
                window.parent?.removeChildWindow(window)
                center(window, over: parent)
                parent.addChildWindow(window, ordered: .above)
            }
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window { window.parent?.removeChildWindow(window) }
        finishCurrent()
    }

    private func center(_ window: NSWindow, over parent: NSWindow) {
        let frame = parent.frame
        window.setFrameOrigin(NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.midY - window.frame.height / 2
        ))
    }

    private func finishCurrent() {
        let pending = onClose
        onClose = nil
        pending?()
    }

    private func makeWindow() -> NSWindow {
        let window = OnboardingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // Held by `self.window`; see `PreferencesWindowController`.
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

/// Escape closes the window, like Preferences.
private final class OnboardingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

private struct TutorialView: View {
    let steps: [TutorialStep]
    @ObservedObject var setup: MultiplexerSetupModel
    let keybindings: KeybindingMatcher
    let close: () -> Void
    @State private var index = 0

    var body: some View {
        VStack(spacing: 0) {
            if steps.indices.contains(index) {
                stepView(steps[index])
                    .id(steps[index].id)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(minWidth: 540, minHeight: 600)
    }

    private func stepView(_ step: TutorialStep) -> some View {
        VStack(spacing: 16) {
            Image(systemName: step.symbolName)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 64)
                .accessibilityHidden(true)
            Text(step.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(step.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let shortcut = step.shortcut {
                Text(shortcut)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                    .accessibilityLabel("Shortcut \(shortcut)")
            }
            if step.id == .multiplexerSetup {
                MultiplexerSetupPanel(model: setup)
            }
            if step.id == .macShortcuts {
                MacShortcutsPresetView(matcher: keybindings)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var footer: some View {
        HStack {
            Button("Skip Tour", action: close)
                .buttonStyle(.link)
            Spacer()
            Text("\(index + 1) of \(steps.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Back") {
                withAnimation(.easeOut(duration: 0.15)) { index = TutorialNavigation.previous(from: index) }
            }
            .disabled(index == 0)
            Button(index + 1 < steps.count ? "Next" : "Get Started") {
                switch TutorialNavigation.next(from: index, stepCount: steps.count) {
                case .step(let next): withAnimation(.easeOut(duration: 0.15)) { index = next }
                case .finished: close()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct WhatsNewView: View {
    let notes: [ReleaseNote]
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("What's New in Vakta")
                .font(.title2.weight(.semibold))
                .padding(.top, 8)
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(notes, id: \.version) { note in
                        if notes.count > 1 {
                            Text("Version \(note.version.description)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(note.highlights.enumerated()), id: \.offset) { _, highlight in
                            highlightRow(highlight)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Continue", action: close)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 16)
        }
        .padding(28)
        .frame(minWidth: 520, minHeight: 480)
    }

    private func highlightRow(_ highlight: WhatsNewHighlight) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: highlight.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(highlight.title).font(.body.weight(.semibold))
                Text(highlight.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Live install status for herdr and tmux, with an Install action that opens
/// a transient installer session. Rechecks when shown and whenever a window
/// becomes key (e.g. returning from the installer session).
private struct MultiplexerSetupPanel: View {
    @ObservedObject var model: MultiplexerSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.rows.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            ForEach(model.rows) { row in
                rowView(row)
            }
            HStack {
                if herdrMissingButTmuxInstalled {
                    Text("Or make tmux the default profile in Preferences ▸ Sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Again") { model.refresh() }
                    .controlSize(.small)
                    .disabled(model.isChecking)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }

    private var herdrMissingButTmuxInstalled: Bool {
        let herdr = model.rows.first { $0.tool == .herdr }?.status
        let tmux = model.rows.first { $0.tool == .tmux }?.status
        guard let herdr, case .installed = tmux else { return false }
        if case .installed = herdr { return false }
        return true
    }

    @ViewBuilder
    private func rowView(_ row: MultiplexerSetupModel.Row) -> some View {
        let name = row.tool.executableName
        switch row.status {
        case .installed(let path):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(name).font(.body.weight(.semibold))
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name) installed at \(path)")
        case .installable(let command):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(name).font(.body.weight(.semibold))
                    Text("not installed").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                    Button("Install") { model.install(row.tool) }
                        .controlSize(.small)
                }
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .needsHomebrew:
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(name).font(.body.weight(.semibold))
                Text("installs with Homebrew").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Link("Get Homebrew", destination: MultiplexerSetupPlanner.homebrewURL)
                    .controlSize(.small)
            }
        }
    }
}
