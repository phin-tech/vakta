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

    var body: some View {
        VStack(spacing: 0) {
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
                    Button("Close Session") {
                        sessionStore.requestClose(session.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Menu {
                ForEach(sessionStore.profiles) { profile in
                    Menu(profile.name) {
                        Button("New Session") {
                            sessionStore.createSession(profile: profile)
                        }
                        Button("Edit Profile…") {
                            editorIsNew = false
                            editorProfile = profile
                        }
                    }
                }
                Divider()
                Button("New Profile…") {
                    editorIsNew = true
                    editorProfile = Profile(name: "", command: "")
                }
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } primaryAction: {
                // Primary click uses the default profile; the dropdown picks one.
                sessionStore.createSession()
            }
            .menuStyle(.borderlessButton)
            .padding(8)
        }
        .frame(minWidth: 180, idealWidth: 220)
        .sheet(item: $editorProfile) { profile in
            ProfileEditorView(
                profile: profile,
                isNew: editorIsNew,
                onSave: { saved in
                    sessionStore.upsertProfile(saved)
                    editorProfile = nil
                    // A brand-new profile is most useful opened right away.
                    if editorIsNew {
                        sessionStore.createSession(profile: saved)
                    }
                },
                onCancel: { editorProfile = nil },
                onDelete: editorIsNew ? nil : {
                    sessionStore.deleteProfile(profile.id)
                    editorProfile = nil
                }
            )
        }
    }
}

/// One sidebar row. Observes the session's `TerminalViewState` directly --
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
                        // Seed with the current display title so the user edits
                        // from what they see, not an empty field.
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
