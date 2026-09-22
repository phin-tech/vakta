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
//  the icon rail (width driven by `AppDelegate` off `SidebarSettingsStore`) -- a
//  narrow strip of session icons.

import GhosttyTerminal
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var terminalSettings: TerminalSettingsStore
    @EnvironmentObject private var keybindingMatcher: KeybindingMatcher
    @EnvironmentObject private var herdrPreferences: HerdrPreferencesStore
    @EnvironmentObject private var sidebarSettings: SidebarSettingsStore

    /// The session whose row is currently in rename mode, if any.
    @State private var editingID: Session.ID?

    /// The workspace whose row is currently in rename mode, if any.
    @State private var editingWorkspaceID: String?
    @State private var workspaceDraftName: String = ""
    @FocusState private var workspaceFieldFocused: Bool

    /// Herdr session rows currently expanded to show their workspaces (see
    /// the Appearance pane's "Show workspaces" toggle). Transient UI
    /// state, not persisted -- collapses again on relaunch.
    @State private var expandedHerdrSessionIDs: Set<Session.ID> = []

    /// The profile being created/edited in the modal, if any. `sheet(item:)`
    /// keys off this being non-nil.
    @State private var editorProfile: Profile?
    /// Whether `editorProfile` is a brand-new profile (vs. editing an existing).
    @State private var editorIsNew = false

    /// Whether the notifications bell's unread-sessions popover is open.
    @State private var isNotificationsPopoverPresented = false

    /// Below this width the sidebar renders as an icon rail.
    private let railThreshold: CGFloat = 120

    /// Height of the traffic-light band the full-height sidebar now runs under
    /// (see `App.makeWindow`). Used to clear the window controls.
    private let titlebarInset: CGFloat = 28

    /// Width of the herdr disclosure's icon column -- shared with
    /// `WorkspaceRow` so a workspace's focused-dot lines up under the
    /// session row's own disclosure/status icon, not at an arbitrary indent.
    fileprivate static let herdrGutterWidth: CGFloat = 10

    /// Terminal-style row insets: no vertical padding, so consecutive rows
    /// stack at the font's own line height like lines of terminal output
    /// instead of at the sidebar list style's airier pitch.
    fileprivate static let terminalRowInsets = EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    /// System-style row insets. Roughly the `.sidebar` list style's own
    /// vertical rhythm, kept explicit now that the row -- not `listRowInsets`
    /// -- owns its padding (see `rowContentInsets`).
    fileprivate static let systemRowInsets = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)

    /// Padding a row draws *inside* itself, with its `listRowInsets` zeroed.
    /// This is what makes the whole highlighted cell -- not just the label --
    /// the tap target: `contentShape` over this padded, full-width content
    /// then matches the `listRowBackground`'s full-cell rectangle, instead of
    /// hugging the text and leaving the surrounding highlight dead to clicks.
    private var rowContentInsets: EdgeInsets {
        terminalStyle ? Self.terminalRowInsets : Self.systemRowInsets
    }

    /// Whether the sidebar is in terminal style: terminal font, rows at the
    /// font's line height, text glyphs (see `SidebarTerminalGlyphs`) instead
    /// of symbols/shapes, and squared full-width highlights.
    private var terminalStyle: Bool { appearanceStore.sidebarFont == .matchTerminal }

    /// The font for session-name rows: the terminal font family and size when
    /// terminal style is chosen and a custom family is set; the system
    /// monospaced text style (Dynamic Type, no fixed size) when terminal
    /// style is chosen but the family is ghostty's own default; otherwise
    /// `nil` to keep the default sidebar font. The size is the Appearance
    /// preference's explicit sidebar size when set, else the terminal's (see
    /// `SidebarRowFontResolver`). The family-less branch deliberately does
    /// not apply `terminalSettings.fontSize`: `Font.system(size:design:)`
    /// has no `relativeTo:` counterpart, so that would drop Dynamic Type
    /// scaling -- a trade made only for an explicit sidebar size.
    private var rowFont: Font? {
        guard terminalStyle else { return nil }
        let family = terminalSettings.fontFamily.trimmingCharacters(in: .whitespaces)
        let override = appearanceStore.sidebarFontSize
        if family.isEmpty {
            // An explicit sidebar size is the one case worth trading Dynamic
            // Type for: the user asked for that exact size.
            guard SidebarRowFontResolver.hasExplicitSize(override) else {
                return .system(.body, design: .monospaced)
            }
            let size = SidebarRowFontResolver.fontSize(sidebarOverride: override, matchingTerminal: 0)
            return .system(size: size, design: .monospaced)
        }
        let size = SidebarRowFontResolver.fontSize(
            sidebarOverride: override, matchingTerminal: terminalSettings.fontSize
        )
        return .custom(family, size: size, relativeTo: .body)
    }

    var body: some View {
        GeometryReader { geo in
            let collapsed = geo.size.width < railThreshold
            VStack(spacing: 0) {
                header(collapsed: collapsed)
                if collapsed {
                    rail
                } else {
                    if terminalStyle { sectionLabel }
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

    // MARK: Header (collapse toggle + notifications bell, present in both modes)

    /// Expanded: bell and collapse toggle side by side, anchored to the
    /// sidebar's right edge (a deliberate top-right control cluster) so they
    /// clear the traffic lights on the left instead of sitting mid-column.
    /// Collapsed (rail): the bell has no room beside the toggle in a ~48pt
    /// strip, so it stacks above it instead, both centered just below the
    /// traffic-light band.
    @ViewBuilder
    private func header(collapsed: Bool) -> some View {
        if collapsed {
            VStack(spacing: 4) {
                notificationsBellButton
                collapseToggleButton(collapsed: true)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, titlebarInset)
            .padding(.bottom, 4)
        } else {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                notificationsBellButton
                collapseToggleButton(collapsed: false)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 4)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    /// Terminal style only: a muted lowercase heading over the list, echoing
    /// herdr's own `machines` section label. Its own row rather than part of
    /// `header`, whose left side must stay clear for the traffic lights.
    private var sectionLabel: some View {
        Text("sessions")
            .font(rowFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.terminalRowInsets.leading)
            .padding(.bottom, 4)
    }

    private func collapseToggleButton(collapsed: Bool) -> some View {
        Button {
            sidebarSettings.toggleCollapsed()
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

    // MARK: Notifications bell (unread panes -- see `SessionStore.unreadPanes`)

    /// Only shown expanded (not in the icon rail) -- the rail is already a
    /// narrow strip of session icons with no room for a second control
    /// beyond the collapse toggle.
    /// The single badge dot's color: the worst (busiest-ranked, see
    /// `AgentStatus.busiest`) status among all unread panes -- e.g. one
    /// `.done` and one `.attention` shows red, not green, since attention
    /// outranks done. A dedicated urgency palette, distinct from
    /// `sidebarStatusColor`'s softer session-row yellow: this badge is
    /// meant to read as "something needs you" at a glance.
    private func bellBadgeColor(_ status: AgentStatus) -> Color {
        switch status {
        case .attention: return .red
        case .working: return .orange
        case .done, .idle: return .green
        case .none, .unavailable: return .secondary
        }
    }

    private var notificationsBellButton: some View {
        let worstUnread = AgentStatus.busiest(sessionStore.unreadPanes.map(\.status))
        return Button {
            isNotificationsPopoverPresented = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: sessionStore.unreadPanes.isEmpty ? "bell" : "bell.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                if !sessionStore.unreadPanes.isEmpty {
                    Circle()
                        .fill(bellBadgeColor(worstUnread))
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Notifications")
        .popover(isPresented: $isNotificationsPopoverPresented, arrowEdge: .bottom) {
            notificationsPopoverContent
        }
    }

    private var notificationsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessionStore.unreadPanes.isEmpty {
                Text("No unread sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(sessionStore.unreadPanes) { pane in
                    Button {
                        // Already clears this pane's unread flag -- no
                        // second clear path in this view.
                        sessionStore.focusUnreadPane(pane)
                        isNotificationsPopoverPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            if sidebarStatusIsCheckmark(pane.status) {
                                Image(systemName: "checkmark.circle.fill")
                                    .resizable()
                                    .frame(width: 8, height: 8)
                                    .foregroundStyle(.green)
                            } else {
                                Circle()
                                    .fill(sidebarStatusColor(pane.status, isFocused: false))
                                    .frame(width: 6, height: 6)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pane.label)
                                // The reason this is unread, then the Vakta
                                // session this workspace lives under -- one
                                // herdr session/socket can host several
                                // workspaces sharing one sidebar row, so
                                // this disambiguates which row clicking
                                // here will jump to.
                                Text(sidebarStatusDescription(pane.status))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let sessionTitle = sessionStore.sessions.first(where: { $0.id == pane.sessionID })?.displayTitle {
                                    Text(sessionTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 220)
        .padding(.vertical, 6)
    }

    // MARK: Full panel

    /// The selectable name portion of a session row. A `Button` rather than a
    /// bare `.onTapGesture`: inside a `List` (an `NSTableView`), only a
    /// control's own frame is reliably hit-tested across a cell's blank
    /// areas -- a tap gesture fires on the drawn label but the surrounding
    /// highlight falls through to the table view, which has no `selection:` to
    /// act on and drops the click. A button (as `RailSessionItem` already uses)
    /// claims its whole frame. While renaming, stay a plain view so the inner
    /// `TextField` keeps its own clicks. The disclosure stays a sibling in the
    /// caller's `HStack`, never a button nested inside this one.
    @ViewBuilder
    private func sessionNameCell(_ session: Session) -> some View {
        let content = SessionRow(
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        if editingID == session.id {
            content
        } else {
            Button { sessionStore.select(session.id) } label: { content }
                .buttonStyle(.plain)
        }
    }

    private var fullList: some View {
        List {
            ForEach(sessionStore.sessions) { session in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // Reserved for every row once the preference is on --
                    // even a non-herdr row's, so a session's prompt caret/
                    // status dot lines up in the same column whether or not
                    // that particular row has a disclosure to show.
                    if herdrPreferences.showWorkspaces {
                        Group {
                            if supportsWorkspaces(session) {
                                Button {
                                    toggleHerdrDisclosure(session)
                                } label: {
                                    herdrDisclosureGlyph(expanded: expandedHerdrSessionIDs.contains(session.id))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                // Fixed height: an unbounded `Color.clear`
                                // is vertically greedy and would drag the
                                // row's first-text baseline to its bottom.
                                Color.clear.frame(height: 1)
                            }
                        }
                        .frame(width: Self.herdrGutterWidth, alignment: .center)
                    }

                    sessionNameCell(session)
                }
                // The row owns its padding (see `rowContentInsets`), with
                // `listRowInsets` zeroed below, so the selectable button fills
                // the cell the `listRowBackground` paints.
                .padding(rowContentInsets)
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
                // Zeroed: the row now owns its padding (see `rowContentInsets`)
                // so `contentShape` covers the full cell the background fills.
                .listRowInsets(EdgeInsets())
                .listRowSeparator(terminalStyle ? .hidden : .automatic)
                .contextMenu {
                    Button("Rename…") { editingID = session.id }
                    Button("Detach Session") { sessionStore.requestClose(session.id) }
                    if supportsActions(session) {
                        Button("Stop Session") { confirmStopSession(session) }
                    }
                }

                if herdrPreferences.showWorkspaces, supportsWorkspaces(session), expandedHerdrSessionIDs.contains(session.id) {
                    ForEach(sessionStore.workspaces[session.id] ?? [], id: \.id) { workspace in
                        // A `Button` for the same reason as the session row
                        // (see `sessionNameCell`): the whole highlighted cell
                        // is hit-tested, not just the label. Padding lives
                        // inside the label -- a workspace row has no disclosure
                        // sibling, so nothing has to stay outside the button.
                        // While renaming, drop the button so the inner
                        // `TextField` keeps its own clicks (see `sessionNameCell`).
                        Group {
                            if editingWorkspaceID == workspace.id {
                                workspaceNameEditor(workspace: workspace, session: session)
                            } else {
                                Button {
                                    sessionStore.focusWorkspace(workspace.id, in: session.id)
                                } label: {
                                    WorkspaceRow(
                                        workspace: workspace,
                                        status: sessionStore.paneStatusByWorkspaceID[workspace.id] ?? .none,
                                        isTmux: isTmux(session),
                                        font: rowFont,
                                        terminalStyle: terminalStyle,
                                        highlight: SidebarRowPresentation.workspaceHighlight(
                                            workspaceFocused: workspace.focused,
                                            sessionSelected: session.id == sessionStore.selectedID
                                        ),
                                        accent: Color(nsColor: sessionStore.terminalAccentColor)
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(rowContentInsets)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    workspaceActions(workspace: workspace, session: session)
                                }
                            }
                        }
                            // Focus is a row background in both styles, shaped
                            // like the session selection above (square and
                            // full-width in terminal style, an inset rounded
                            // pill otherwise) so text stays centered in it.
                            // Only the selected session's focused workspace
                            // is prominent -- see `SidebarRowPresentation`.
                            .listRowBackground(
                                workspaceHighlightBackground(
                                    SidebarRowPresentation.workspaceHighlight(
                                        workspaceFocused: workspace.focused,
                                        sessionSelected: session.id == sessionStore.selectedID
                                    )
                                )
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(terminalStyle ? .hidden : .automatic)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(TerminalRowDensity(enabled: terminalStyle))
        // Hide the List's own opaque background so the sidebar's color shows
        // through, and tint controls with the terminal theme's accent.
        .scrollContentBackground(.hidden)
        .tint(Color(nsColor: sessionStore.terminalAccentColor))
    }

    /// The right-click menu on a workspace row: mutating multiplexer commands
    /// (see `MultiplexerAction`). Pane commands target the workspace's active
    /// pane, resolved cross-backend by the store. "Workspace" is the neutral
    /// noun the sidebar already uses for a herdr workspace or a tmux window.
    @ViewBuilder
    private func workspaceActions(workspace: Workspace, session: Session) -> some View {
        Button("Split Right") {
            sessionStore.performPaneAction({ .splitPane(paneID: $0, direction: .right) }, workspaceID: workspace.id, in: session.id)
        }
        Button("Split Down") {
            sessionStore.performPaneAction({ .splitPane(paneID: $0, direction: .down) }, workspaceID: workspace.id, in: session.id)
        }
        Button("Zoom Pane") {
            sessionStore.performPaneAction({ .zoomPane(paneID: $0) }, workspaceID: workspace.id, in: session.id)
        }
        Menu("Resize Pane") {
            Button("Left") { sessionStore.performPaneAction({ .resizePane(paneID: $0, direction: .left) }, workspaceID: workspace.id, in: session.id) }
            Button("Right") { sessionStore.performPaneAction({ .resizePane(paneID: $0, direction: .right) }, workspaceID: workspace.id, in: session.id) }
            Button("Up") { sessionStore.performPaneAction({ .resizePane(paneID: $0, direction: .up) }, workspaceID: workspace.id, in: session.id) }
            Button("Down") { sessionStore.performPaneAction({ .resizePane(paneID: $0, direction: .down) }, workspaceID: workspace.id, in: session.id) }
        }
        Divider()
        Button("Rename…") {
            workspaceDraftName = workspace.label
            editingWorkspaceID = workspace.id
        }
        Button("Close Pane") {
            sessionStore.performPaneAction({ .closePane(paneID: $0) }, workspaceID: workspace.id, in: session.id)
        }
        Button("Close Workspace") {
            sessionStore.performAction(.closeWorkspace(workspaceID: workspace.id), in: session.id)
        }
        Button("New Workspace") {
            sessionStore.performAction(.createWorkspace(label: nil), in: session.id)
        }
    }

    /// The inline rename field a workspace row becomes while `editingWorkspaceID`
    /// matches it -- Enter commits, Esc cancels, mirroring the session row's
    /// `SessionRow` editor. An empty/whitespace name is dropped (no rename).
    @ViewBuilder
    private func workspaceNameEditor(workspace: Workspace, session: Session) -> some View {
        TextField("Workspace name", text: $workspaceDraftName)
            .textFieldStyle(.plain)
            .font(rowFont)
            .focused($workspaceFieldFocused)
            .onSubmit {
                let name = workspaceDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    sessionStore.renameWorkspace(workspace.id, to: name, in: session.id)
                }
                editingWorkspaceID = nil
            }
            .onExitCommand { editingWorkspaceID = nil }
            .onAppear { workspaceFieldFocused = true }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(rowContentInsets)
    }

    @ViewBuilder
    private func workspaceHighlightBackground(_ highlight: SidebarRowPresentation.WorkspaceHighlight) -> some View {
        let style = SidebarRowPresentation.workspaceRowStyle(highlight)
        let base = style.usesAccentFill ? Color(nsColor: sessionStore.terminalAccentColor) : Color.secondary
        RoundedRectangle(cornerRadius: terminalStyle ? 0 : 6)
            .fill(base.opacity(style.fillOpacity))
            .padding(.horizontal, terminalStyle ? 0 : 6)
            .animation(.easeOut(duration: 0.08), value: highlight)
    }

    private func supportsWorkspaces(_ session: Session) -> Bool {
        LaunchTargetResolver.supportsWorkspaces(session.profile, sessionName: session.sessionName)
    }

    private func supportsActions(_ session: Session) -> Bool {
        LaunchTargetResolver.supportsActions(session.profile, sessionName: session.sessionName)
    }

    /// Confirms before ending a session on the server (`.stopSession`), which
    /// -- unlike Detach -- is not re-attachable.
    private func confirmStopSession(_ session: Session) {
        let alert = NSAlert()
        alert.messageText = "Stop “\(session.displayTitle)”?"
        alert.informativeText = "This ends the session on the server. Detach instead if you want to keep it running in the background."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            sessionStore.performAction(.stopSession, in: session.id)
        }
    }

    private func isTmux(_ session: Session) -> Bool {
        guard case .multiplexer(let target) = LaunchTargetResolver.resolve(session.profile) else { return false }
        return target.backend == .tmux
    }

    /// A native SF Symbol chevron reads oddly next to terminal-style rows'
    /// plain-text look, so terminal style gets herdr's own ▾/▸ tree
    /// triangles in the terminal font instead (see `SidebarTerminalGlyphs`)
    /// rather than mixing icon fonts with terminal text.
    @ViewBuilder
    private func herdrDisclosureGlyph(expanded: Bool) -> some View {
        if terminalStyle {
            Text(SidebarTerminalGlyphs.disclosure(expanded: expanded))
                .font(rowFont)
        } else {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
        }
    }

    private func toggleHerdrDisclosure(_ session: Session) {
        if expandedHerdrSessionIDs.contains(session.id) {
            expandedHerdrSessionIDs.remove(session.id)
        } else {
            expandedHerdrSessionIDs.insert(session.id)
            if sessionStore.workspaces[session.id] == nil {
                sessionStore.fetchWorkspaces(for: session.id)
            }
        }
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
                        Button("Detach Session") { sessionStore.requestClose(session.id) }
                        if supportsActions(session) {
                            Button("Stop Session") { confirmStopSession(session) }
                        }
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

/// Terminal style only: lets list rows shrink to the font's own line height.
/// A conditional modifier (rather than always writing the environment value)
/// so system style keeps the list style's untouched default minimum.
private struct TerminalRowDensity: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.environment(\.defaultMinListRowHeight, 1)
        } else {
            content
        }
    }
}

/// Sidebar status-dot color: agent status when known, else a focus dot.
func sidebarStatusColor(_ status: AgentStatus, isFocused: Bool) -> Color {
    switch status {
    case .working: return .orange
    case .attention: return .yellow
    case .done, .idle: return .green
    case .none, .unavailable: return isFocused ? .accentColor : .secondary.opacity(0.35)
    }
}

/// Whether `status` renders as a checkmark instead of a plain dot -- a real
/// completion (herdr's own "done"/"complete") reads differently from merely
/// being idle, even though both currently share the same green.
func sidebarStatusIsCheckmark(_ status: AgentStatus) -> Bool {
    status == .done
}

/// tmux command status colors are intentionally binary: zero is success,
/// every nonzero code is failure, and nil stays muted until the first command
/// completes.
func sidebarTmuxCommandStatusColor(_ exitCode: Int?) -> Color {
    guard let exitCode else { return .secondary.opacity(0.35) }
    return exitCode == 0 ? .green : .red
}

/// A short human label for `status` -- shared by session rows' tooltips and
/// the bell popover, so an unread entry says *why* it's there.
func sidebarStatusDescription(_ status: AgentStatus) -> String {
    switch status {
    case .working: return "Working"
    case .attention: return "Needs attention"
    case .done: return "Done"
    case .idle: return "Idle"
    case .none: return "Unknown"
    case .unavailable: return "Status unavailable (remote target)"
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
        status == .none ? session.displayTitle : sidebarStatusDescription(status)
    }

    var body: some View {
        HStack(spacing: 6) {
            if terminalStyle {
                // No leading mark: the row reads as a bold group heading
                // like herdr's machine names, with status trailing instead.
            } else if sidebarStatusIsCheckmark(status) {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.green)
                    .help(statusHelp)
            } else if SidebarRowPresentation.showsStatusMark(status) {
                Circle()
                    .fill(sidebarStatusColor(status, isFocused: viewState.isFocused))
                    .frame(width: 7, height: 7)
                    .help(statusHelp)
            } else {
                // No agent to report on: no dot, but its column stays
                // reserved so session names line up.
                Color.clear.frame(width: 7, height: 7)
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
                    .font(terminalStyle ? font?.bold() : font)
                    // System style: semibold, so a session reads as the
                    // heading of the workspaces beneath it.
                    .fontWeight(terminalStyle ? nil : .semibold)
                    .lineLimit(1)
                    .help(session.displayTitle)
            }

            Spacer()

            // Terminal style: a right-aligned status mark colored by agent
            // status (herdr's ● beside a machine name); nothing at all for a
            // session with no agent to report on.
            if terminalStyle, let glyph = SidebarTerminalGlyphs.sessionStatus(status) {
                Text(glyph)
                    .font(font)
                    .foregroundStyle(sidebarStatusColor(status, isFocused: false))
                    .help(statusHelp)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One workspace under an expanded session row (see `SidebarView.fullList`).
/// Tapping it (handled by the caller) focuses that workspace on the
/// session's server and brings the session itself forward.
private struct WorkspaceRow: View {
    let workspace: Workspace
    /// This workspace's own status, from `SessionStore.paneStatusByWorkspaceID`
    /// -- distinct from the session row's aggregated `.busiest` value above,
    /// which can't tell this workspace apart from another one sharing the
    /// same session (see `UnreadPane`'s doc comment).
    let status: AgentStatus
    let isTmux: Bool
    let font: Font?
    let terminalStyle: Bool
    let highlight: SidebarRowPresentation.WorkspaceHighlight
    let accent: Color

    private var rowStyle: SidebarRowPresentation.WorkspaceRowStyle {
        SidebarRowPresentation.workspaceRowStyle(highlight)
    }

    var body: some View {
        if terminalStyle {
            terminalBody
        } else {
            systemBody
        }
    }

    /// Text glyphs in the terminal font, so the status mark shares the
    /// label's baseline and cell grid. The mark sits directly under the
    /// session name's first character (herdr's tree indent); focus is drawn
    /// by the caller's full-width `listRowBackground`, plus a bold label.
    private var terminalBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Focus marker in the tree-indent column (see `WorkspaceRowStyle`).
            Text(SidebarTerminalGlyphs.workspaceFocusMarker(highlight))
                .font(font)
                .foregroundStyle(highlight == .prominent ? accent : Color.secondary)
                .frame(width: SidebarView.herdrGutterWidth + 4, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isTmux {
                Text(SidebarTerminalGlyphs.tmuxCommandStatus(workspace.lastCommandExitCode))
                    .font(font)
                    .foregroundStyle(sidebarTmuxCommandStatusColor(workspace.lastCommandExitCode))
                    .help(tmuxStatusHelp)
            } else {
                Text(SidebarTerminalGlyphs.workspaceStatus(status))
                    .font(font)
                    .foregroundStyle(sidebarStatusColor(status, isFocused: false))
            }
            Text(workspace.label)
                .font(rowStyle.labelEmphasis == .strong ? font?.bold() : font)
                .foregroundStyle(rowStyle.labelEmphasis == .dim ? Color.secondary : Color.primary)
                .lineLimit(1)
                .help(workspace.label)
            Spacer()
            }
        }
    }

    private var tmuxStatusHelp: String {
        guard let exitCode = workspace.lastCommandExitCode else { return "No command status yet" }
        return "Last command exited with \(exitCode)"
    }

    private var systemBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Reserves the same column the session row's disclosure/status
            // icon occupies, so the status dot below still lines up under
            // it -- focus itself is now shown by the row's background
            // rather than a dot here.
            // A fixed height matters: an unbounded `Color.clear` is
            // vertically greedy, and under `.firstTextBaseline` its bottom
            // edge becomes the baseline the label aligns to -- which pushed
            // the text to the bottom of the row.
            ZStack(alignment: .leading) {
                Color.clear.frame(width: SidebarView.herdrGutterWidth, height: 1)
                if highlight == .prominent {
                    Capsule().fill(accent).frame(width: 3, height: 14)
                }
            }
            .frame(width: SidebarView.herdrGutterWidth, alignment: .leading)
            // The mark's column is reserved even when there is no mark, so
            // every workspace label starts at the same x whether or not its
            // backend reports agent status.
            // A `ZStack`, not a `Group`: a fixed frame on an empty `Group`
            // collapses to nothing, which would un-reserve the column.
            ZStack {
                if isTmux {
                    if workspace.lastCommandExitCode == nil {
                        Text(SidebarTerminalGlyphs.tmuxCommandStatus(nil))
                            .font(.caption)
                            .foregroundStyle(sidebarTmuxCommandStatusColor(nil))
                    } else {
                        Circle()
                            .fill(sidebarTmuxCommandStatusColor(workspace.lastCommandExitCode))
                            .frame(width: 6, height: 6)
                    }
                } else if sidebarStatusIsCheckmark(status) {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: 8, height: 8)
                        .foregroundStyle(.green)
                } else if SidebarRowPresentation.showsStatusMark(status) {
                    Circle()
                        .fill(sidebarStatusColor(status, isFocused: false))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 8, height: 8)
            // One step smaller than the session name, so sessions read as
            // headings and workspaces as their children.
            Text(workspace.label)
                .font(.callout.weight(rowStyle.labelEmphasis == .strong ? .semibold : .regular))
                .foregroundStyle(rowStyle.labelEmphasis == .dim ? Color.secondary : Color.primary)
                .lineLimit(1)
                // Workspace names are often long repo names that differ at
                // the end; middle truncation keeps both ends visible.
                .truncationMode(.middle)
                .help(workspace.label)
            Spacer()
        }
        // Disclosure column width + the outer row's spacing -- lands this
        // row's icon column directly under the session row's.
        .padding(.leading, SidebarView.herdrGutterWidth + 4)
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
                // `.done` renders as a checkmark instead of a plain dot --
                // see `sidebarStatusIsCheckmark`.
                if status != .none || viewState.isFocused {
                    Group {
                        if sidebarStatusIsCheckmark(status) {
                            Image(systemName: "checkmark.circle.fill")
                                .resizable()
                                .foregroundStyle(.green)
                        } else {
                            Circle()
                                .fill(sidebarStatusColor(status, isFocused: viewState.isFocused))
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        }
                    }
                    .frame(width: 9, height: 9)
                    .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(session.displayTitle)
    }
}
