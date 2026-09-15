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

    /// The session whose row is currently in rename mode, if any.
    @State private var editingID: Session.ID?

    /// The profile being created/edited in the modal, if any. `sheet(item:)`
    /// keys off this being non-nil.
    @State private var editorProfile: Profile?
    /// Whether `editorProfile` is a brand-new profile (vs. editing an existing).
    @State private var editorIsNew = false

    /// Below this width the sidebar renders as an icon rail.
    private let railThreshold: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let collapsed = geo.size.width < railThreshold
            VStack(spacing: 0) {
                header(collapsed: collapsed)
                Divider()
                if collapsed {
                    rail
                } else {
                    fullList
                }
                Divider()
                footer(collapsed: collapsed)
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
            Button {
                sessionStore.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Expand Sidebar" : "Collapse Sidebar")
            if !collapsed { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .padding(.horizontal, collapsed ? 0 : 6)
        .padding(.vertical, 6)
    }

    // MARK: Full panel

    private var fullList: some View {
        List(
            sessionStore.sessions,
            selection: Binding(
                get: { sessionStore.selectedID },
                set: { newValue in
                    guard let newValue else { return }
                    sessionStore.select(newValue)
                }
            )
        ) { session in
            SessionRow(
                session: session,
                isEditing: editingID == session.id,
                onCommitName: { name in
                    sessionStore.renameSession(session.id, to: name)
                    editingID = nil
                },
                onEndEditing: { editingID = nil }
            )
            .tag(session.id)
            .contextMenu {
                Button("Rename…") { editingID = session.id }
                Button("Close Session") { sessionStore.requestClose(session.id) }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Icon rail

    private var rail: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(sessionStore.sessions) { session in
                    RailSessionItem(
                        session: session,
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
                .menuStyle(.borderlessButton)
                .padding(8)
        }
    }

    private var newSessionMenu: some View {
        Menu {
            ForEach(sessionStore.profiles) { profile in
                Menu(profile.name) {
                    Button("New Session") { sessionStore.createSession(profile: profile) }
                    // Existing sessions to *attach* (your `default`, named ones)
                    // -- offered here, never auto-listed in the sidebar.
                    let existing = sessionStore.discovered[profile.id] ?? []
                    if !existing.isEmpty {
                        Section("Attach existing") {
                            ForEach(existing, id: \.self) { name in
                                Button(name) {
                                    sessionStore.attachExisting(profile: profile, name: name)
                                }
                            }
                        }
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
            Label("New Session", systemImage: "plus")
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
private struct SessionRow: View {
    @ObservedObject var session: Session
    @ObservedObject private var viewState: TerminalViewState

    let isEditing: Bool
    let onCommitName: (String) -> Void
    let onEndEditing: () -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    init(
        session: Session,
        isEditing: Bool,
        onCommitName: @escaping (String) -> Void,
        onEndEditing: @escaping () -> Void
    ) {
        self.session = session
        viewState = session.viewState
        self.isEditing = isEditing
        self.onCommitName = onCommitName
        self.onEndEditing = onEndEditing
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewState.isFocused ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)

            if isEditing {
                TextField("Session name", text: $draftName)
                    .textFieldStyle(.plain)
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

    let isSelected: Bool
    let onSelect: () -> Void

    init(session: Session, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.session = session
        viewState = session.viewState
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

                if viewState.isFocused {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(session.displayTitle)
    }
}
