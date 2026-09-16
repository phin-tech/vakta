//
//  SidebarView.swift
//  Vakta
//
//  Pure SwiftUI chrome. This view never touches a `TerminalView` or a
//  `ghostty_surface_t` directly -- it only reads `SessionStore` (session
//  list, selection, each session's `TerminalViewState` for the row label)
//  and calls back into it. The actual terminal surfaces live in
//  `TerminalHostContainerView`, a sibling AppKit view SwiftUI never sees
//  (see `TerminalContainer.swift` and `App.swift`).
//
//  It adapts to its width: a full panel with labels, or -- when collapsed to
//  the icon rail (width driven by `AppDelegate` off `sidebarCollapsed`) -- a
//  narrow strip of session icons.

import GhosttyTerminal
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var terminalSettings: TerminalSettingsStore
    @EnvironmentObject private var keybindingMatcher: KeybindingMatcher

    /// The session whose row is currently in rename mode, if any.
    @State private var editingID: Session.ID?

    /// The profile being created/edited in the modal, if any. `sheet(item:)`
    /// keys off this being non-nil.
    @State private var editorProfile: Profile?
    /// Whether `editorProfile` is a brand-new profile (vs. editing an existing).
    @State private var editorIsNew = false

    /// Below this width the sidebar renders as an icon rail.
    private let railThreshold: CGFloat = 120

    /// Height of the traffic-light band the full-height sidebar now runs under
    /// (see `App.makeWindow`). Used to clear the window controls.
    private let titlebarInset: CGFloat = 28

    /// Whether the sidebar is in terminal style (font + prompt caret + squared
    /// full-width selection).
    private var terminalStyle: Bool { appearanceStore.sidebarFont == .matchTerminal }

    /// The font for session-name rows: the terminal font when terminal style is
    /// chosen (falling back to the system monospaced font when no family is
    /// set), otherwise `nil` to keep the default sidebar font.
    private var rowFont: Font? {
        guard terminalStyle else { return nil }
        let family = terminalSettings.fontFamily.trimmingCharacters(in: .whitespaces)
        if family.isEmpty {
            return .system(.body, design: .monospaced)
        }
        return .custom(family, size: 13, relativeTo: .body)
    }

    var body: some View {
        GeometryReader { geo in
            let collapsed = geo.size.width < railThreshold
            VStack(spacing: 0) {
                header(collapsed: collapsed)
                if collapsed {
                    rail
                } else {
                    fullList
                }
                footer(collapsed: collapsed)
                // A very faint dotted rule, then the keybinding-mode status bar.
                DottedRule()
                    .stroke(
                        Color.white.opacity(0.06),
                        style: StrokeStyle(lineWidth: 1, dash: [1.5, 3])
                    )
                    .frame(height: 1)
                statusBar(collapsed: collapsed)
            }
        }
        .frame(minWidth: 48)
        .onAppear { sessionStore.refreshDiscovery() }
        .sheet(item: $editorProfile) { profile in
            ProfileEditorView(
                profile: profile,
                isNew: editorIsNew,
                onSave: { saved in
                    sessionStore.upsertProfile(saved)
                    editorProfile = nil
                    if editorIsNew { sessionStore.createSession(profile: saved) }
                },
                onCancel: { editorProfile = nil },
                onDelete: editorIsNew ? nil : {
                    sessionStore.deleteProfile(profile.id)
                    editorProfile = nil
                }
            )
        }
    }

    // MARK: Header (collapse toggle, present in both modes)

    @ViewBuilder
    private func header(collapsed: Bool) -> some View {
        HStack(spacing: 0) {
            if !collapsed { Spacer(minLength: 0) }
            Button {
                sessionStore.toggleSidebar()
            } label: {
                Group {
                    if let rowFont {
                        // Match-terminal: a monospace chevron in the terminal
                        // font (echoing herdr's own «/» collapse glyphs) instead
                        // of the SF Symbol.
                        Text(collapsed ? "»" : "«")
                            .font(rowFont)
                    } else {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 13, weight: .regular))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Expand Sidebar" : "Collapse Sidebar")
        }
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .trailing)
        // Expanded: anchor the toggle to the sidebar's right edge (a deliberate
        // top-right collapse control) so it clears the traffic lights on the
        // left instead of sitting mid-column. Collapsed (rail): centered, just
        // below the traffic-light band.
        .padding(.top, collapsed ? titlebarInset : 4)
        .padding(.horizontal, collapsed ? 0 : 10)
        .padding(.bottom, 4)
    }

    // MARK: Full panel

    private var fullList: some View {
        List {
            ForEach(sessionStore.sessions) { session in
                SessionRow(
                    session: session,
                    status: sessionStore.agentStatus[session.id] ?? .none,
                    font: rowFont,
                    terminalStyle: terminalStyle,
                    isEditing: editingID == session.id,
                    onCommitName: { name in
                        sessionStore.renameSession(session.id, to: name)
                        editingID = nil
                    },
                    onEndEditing: { editingID = nil }
                )
                // Drive selection ourselves (a tap) and paint the highlight with
                // herdr's selection color. Using the List's own `selection:`
                // draws its inactive system-gray highlight on top -- doubling
                // the highlight -- because the terminal, not the list, has focus.
                // Terminal style: a full-width square block like a terminal
                // selection; otherwise a rounded, inset macOS-style pill.
                .listRowBackground(
                    session.id == sessionStore.selectedID
                        ? RoundedRectangle(cornerRadius: terminalStyle ? 0 : 6)
                            .fill(Color(nsColor: sessionStore.terminalSelectionColor))
                            .padding(.horizontal, terminalStyle ? 0 : 6)
                        : nil
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard editingID != session.id else { return }
                    sessionStore.select(session.id)
                }
                .contextMenu {
                    Button("Rename…") { editingID = session.id }
                    Button("Close Session") { sessionStore.requestClose(session.id) }
                }
            }
        }
        .listStyle(.sidebar)
        // Hide the List's own opaque background so the sidebar's color shows
        // through, and tint controls with the terminal theme's accent.
        .scrollContentBackground(.hidden)
        .tint(Color(nsColor: sessionStore.terminalAccentColor))
    }

    // MARK: Icon rail

    private var rail: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(sessionStore.sessions) { session in
                    RailSessionItem(
                        session: session,
                        status: sessionStore.agentStatus[session.id] ?? .none,
                        isSelected: sessionStore.selectedID == session.id,
                        onSelect: { sessionStore.select(session.id) }
                    )
                    .contextMenu {
                        Button("Close Session") { sessionStore.requestClose(session.id) }
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Footer (new session)

    @ViewBuilder
    private func footer(collapsed: Bool) -> some View {
        if collapsed {
            Button {
                sessionStore.createSession()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Session")
            .padding(.vertical, 8)
        } else {
            newSessionMenu
                .font(rowFont)
                .menuStyle(.borderlessButton)
                .padding(8)
        }
    }

    // MARK: Status bar (keybinding mode)

    @ViewBuilder
    private func statusBar(collapsed: Bool) -> some View {
        let passthrough = keybindingMatcher.passthrough
        let accent = Color(nsColor: sessionStore.terminalAccentColor)
        let help = passthrough
            ? "Passthrough on — keys go straight to the session. Click, or double-tap the modifier, to exit."
            : "Shortcuts active. Click, or double-tap the passthrough modifier, to send keys raw."

        HStack(spacing: 0) {
            Button {
                keybindingMatcher.togglePassthrough()
            } label: {
                // Keyboard glyph = shortcuts on. Passthrough strikes it through
                // and tints it the accent -- "shortcuts disabled".
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(passthrough ? accent : Color.secondary)
                    .overlay(alignment: .center) {
                        if passthrough {
                            Capsule()
                                .fill(accent)
                                .frame(height: 1.5)
                        }
                    }
                    .frame(width: 24, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)

            if !collapsed { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .padding(.horizontal, collapsed ? 0 : 10)
        .padding(.vertical, 6)
    }

    private var newSessionMenu: some View {
        Menu {
            ForEach(sessionStore.profiles) { profile in
                Menu(profile.name) {
                    Button("New Session") { sessionStore.createSession(profile: profile) }
                    // Existing sessions to *attach* (your `default`, named ones)
                    // -- offered here, never auto-listed in the sidebar. A
                    // multiplexer profile whose actual server can't be
                    // reliably queried (e.g. herdr `--remote`) shows as
                    // explicitly unsupported rather than looking identical
                    // to "queried, found nothing."
                    switch sessionStore.discovered[profile.id] {
                    case .sessions(let existing) where !existing.isEmpty:
                        Section("Attach existing") {
                            ForEach(existing, id: \.self) { name in
                                Button(name) {
                                    sessionStore.attachExisting(profile: profile, name: name)
                                }
                            }
                        }
                    case .unsupported:
                        Section {
                            Button("Can't list sessions for this profile (e.g. a remote target)") {}
                                .disabled(true)
                        }
                    case .sessions, .none:
                        EmptyView()
                    }
                    Divider()
                    Button("Edit Profile…") {
                        editorIsNew = false
                        editorProfile = profile
                    }
                }
            }
            Divider()
            Button("Refresh Sessions") { sessionStore.refreshDiscovery() }
            Button("New Profile…") {
                editorIsNew = true
                editorProfile = Profile(name: "", command: "")
            }
        } label: {
            // Explicit HStack (not `Label`) so the terminal font actually
            // applies -- a `Menu`'s `Label` ignores a `.font` on it.
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("New Session")
            }
            .font(rowFont)
            .frame(maxWidth: .infinity, alignment: .leading)
        } primaryAction: {
            sessionStore.createSession()
        }
    }
}

/// One full-panel row. Observes the session's `TerminalViewState` directly --
/// it is the wrapper's own `ObservableObject`, published straight from the
/// `TerminalSurfaceTitleDelegate` / `TerminalSurfaceFocusDelegate` callbacks
/// libghostty-spm already wires up internally, so the row updates live with
/// no polling and no extra plumbing on Vakta's side.
/// A single horizontal rule, drawn centered in its frame -- stroked with a dash
/// pattern for a faint dotted separator.
private struct DottedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Sidebar status-dot color: agent status when known, else a focus dot.
func sidebarStatusColor(_ status: AgentStatus, isFocused: Bool) -> Color {
    switch status {
    case .working: return .orange
    case .attention: return .yellow
    case .idle: return .green
    case .none, .unavailable: return isFocused ? .accentColor : .secondary.opacity(0.35)
    }
}

private struct SessionRow: View {
    @ObservedObject var session: Session
    @ObservedObject private var viewState: TerminalViewState

    let status: AgentStatus
    let font: Font?
    let terminalStyle: Bool
    let isEditing: Bool
    let onCommitName: (String) -> Void
    let onEndEditing: () -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    init(
        session: Session,
        status: AgentStatus,
        font: Font?,
        terminalStyle: Bool,
        isEditing: Bool,
        onCommitName: @escaping (String) -> Void,
        onEndEditing: @escaping () -> Void
    ) {
        self.session = session
        viewState = session.viewState
        self.status = status
        self.font = font
        self.terminalStyle = terminalStyle
        self.isEditing = isEditing
        self.onCommitName = onCommitName
        self.onEndEditing = onEndEditing
    }

    private var statusHelp: String {
        switch status {
        case .working: return "Working"
        case .attention: return "Needs attention"
        case .idle: return "Idle"
        case .none: return session.displayTitle
        case .unavailable: return "Status unavailable (remote target)"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if terminalStyle {
                // A prompt-style caret colored by status, so rows read like
                // terminal prompt lines.
                Text("❯")
                    .font(font)
                    .foregroundStyle(sidebarStatusColor(status, isFocused: viewState.isFocused))
                    .help(statusHelp)
            } else {
                Circle()
                    .fill(sidebarStatusColor(status, isFocused: viewState.isFocused))
                    .frame(width: 7, height: 7)
                    .help(statusHelp)
            }

            if isEditing {
                TextField("Session name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(font)
                    .focused($fieldFocused)
                    .onSubmit { onCommitName(draftName) }
                    .onExitCommand { onEndEditing() } // Esc cancels
                    .onAppear {
                        draftName = session.customName?.isEmpty == false
                            ? session.customName!
                            : session.displayTitle
                        fieldFocused = true
                    }
            } else {
                Text(session.displayTitle)
                    .font(font)
                    .lineLimit(1)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// One icon-rail item: a rounded tile with the session's initial, a focus dot,
/// and a selection ring. Full title on hover.
private struct RailSessionItem: View {
    @ObservedObject var session: Session
    @ObservedObject private var viewState: TerminalViewState

    let status: AgentStatus
    let isSelected: Bool
    let onSelect: () -> Void

    init(session: Session, status: AgentStatus, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.session = session
        viewState = session.viewState
        self.status = status
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    private var initial: String {
        session.displayTitle.first.map { String($0).uppercased() } ?? "•"
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(initial)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )

                // Status dot for herdr sessions; falls back to a focus dot.
                if status != .none || viewState.isFocused {
                    Circle()
                        .fill(sidebarStatusColor(status, isFocused: viewState.isFocused))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(session.displayTitle)
    }
}
