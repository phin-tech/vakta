//
//  ExtensionsPreferencesView.swift
//  Vakta
//
//  The "Extensions" preferences pane: link an Extension directory, review
//  and approve it (Trust), toggle enabled/developer mode, unlink. Approval
//  shows exactly what will run and what Trust pins before anything executes.

import AppKit
import SwiftUI
import VaktaExtensionKit

struct ExtensionsPreferencesView: View {
    @EnvironmentObject private var registry: ExtensionRegistryStore
    @State private var reviewing: ExtensionEntry?
    @State private var linkError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(registry.entries.isEmpty ? "No extensions linked." : "\(registry.entries.count) linked")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Link Extension…", action: chooseDirectory)
                }
            } footer: {
                Text("An extension is a program on your Mac that adds views to Vakta. It runs only after you approve it, and asks again if its manifest or program changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(registry.entries) { entry in
                ExtensionSection(entry: entry, review: { reviewing = entry })
            }
        }
        .formStyle(.grouped)
        .onAppear { registry.reload() }
        .sheet(item: $reviewing) { entry in
            TrustReviewSheet(entry: entry, dismiss: { reviewing = nil })
        }
        .alert("Couldn't link extension", isPresented: Binding(
            get: { linkError != nil }, set: { if !$0 { linkError = nil } }
        )) {
            Button("OK") { linkError = nil }
        } message: {
            Text(linkError ?? "")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Choose a folder containing \(ExtensionManifest.fileName)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = registry.link(directory: url) {
            linkError = ExtensionText.describe(error)
        }
    }
}

/// One linked Extension as a settings section: identity and state, then a
/// row per toggle, then its actions.
private struct ExtensionSection: View {
    @EnvironmentObject private var registry: ExtensionRegistryStore
    @EnvironmentObject private var host: ExtensionHost
    let entry: ExtensionEntry
    let review: () -> Void

    private var runtimePhase: ExtensionSupervisor.Phase? {
        guard entry.status == .ready, let id = entry.manifest?.id else { return nil }
        return host.phases[id]
    }

    private var statusText: String {
        runtimePhase.map(ExtensionText.phase) ?? ExtensionText.status(entry.status)
    }

    private var statusColor: Color {
        switch runtimePhase {
        case .running?: return .green
        case .failed?: return .red
        default: return entry.status == .ready ? .secondary : .orange
        }
    }

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText)
                }
            }
            if case .needsApproval(let reason) = entry.status {
                LabeledContent {
                    Button("Review…", action: review)
                } label: {
                    Text(ExtensionText.reason(reason)).foregroundStyle(.secondary)
                }
            }
            if case .failed(let reason)? = runtimePhase {
                Text(ExtensionText.failure(reason)).foregroundStyle(.red)
            }
            if case .invalid(let problems) = entry.status {
                ForEach(problems, id: \.self) { problem in
                    Text(problem).foregroundStyle(.red)
                }
            }
            Toggle("Enabled", isOn: Binding(
                get: { entry.record.enabled },
                set: { registry.setEnabled($0, for: entry.record.directory) }
            ))
            Toggle(isOn: Binding(
                get: { entry.record.developerMode },
                set: { registry.setDeveloperMode($0, for: entry.record.directory) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer mode")
                    Text("Approval covers the manifest only, so rebuilding doesn't ask again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if let id = entry.manifest?.id, entry.status == .ready {
                    Button("Restart") { host.restart(id) }
                    Button("View Log") {
                        let url = host.logURL(for: id)
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.open(url)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                        }
                    }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.directoryURL])
                }
                Spacer()
                Button("Unlink", role: .destructive) {
                    registry.unlink(entry.record.directory)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.headline)
                Text(entry.record.directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.record.directory)
            }
        }
    }
}

private struct TrustReviewSheet: View {
    @EnvironmentObject private var registry: ExtensionRegistryStore
    let entry: ExtensionEntry
    let dismiss: () -> Void
    @State private var isBuilding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve \(entry.displayName)?").font(.title2.bold())
            if case .needsApproval(let reason) = entry.status {
                Text(ExtensionText.reason(reason)).foregroundStyle(.secondary)
            }
            if let manifest = entry.manifest {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("ID", manifest.id)
                    row("Folder", entry.record.directory)
                    row("Runs", manifest.command.joined(separator: " "))
                    if !manifest.build.isEmpty {
                        row("Builds with", manifest.build.map { $0.joined(separator: " ") }.joined(separator: "\n"))
                    }
                    if !manifest.panelViews.isEmpty {
                        row("Adds views", manifest.panelViews.map(\.title).joined(separator: ", "))
                    }
                    if !manifest.environment.isEmpty {
                        row("Receives", manifest.environment.joined(separator: ", ") + " from your login shell")
                    }
                    row("Approval covers", entry.record.developerMode
                        ? "The manifest only (developer mode)."
                        : "The manifest and \(manifest.command[0]).")
                }
                .font(.callout)
            }
            Text("It will run as you, with access to your files.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if isBuilding {
                    ProgressView().controlSize(.small)
                    Text("Building…").font(.caption)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(entry.manifest?.build.isEmpty == false ? "Approve and Build" : "Approve", action: approve)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBuilding || entry.manifest == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func approve() {
        isBuilding = true
        error = nil
        Task {
            let failure = await registry.trust(entry.record.directory)
            isBuilding = false
            if let failure {
                error = ExtensionText.describe(failure)
            } else {
                dismiss()
            }
        }
    }
}

/// User-facing wording for extension states and errors.
enum ExtensionText {
    static func status(_ status: ExtensionStatus) -> String {
        switch status {
        case .ready: return "Ready"
        case .disabled: return "Disabled"
        case .needsApproval: return "Needs approval"
        case .invalid: return "Invalid"
        }
    }

    static func phase(_ phase: ExtensionSupervisor.Phase) -> String {
        switch phase {
        case .running: return "Running"
        case .starting, .initializing: return "Starting…"
        case .backingOff: return "Restarting…"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    static func failure(_ reason: ExtensionSupervisor.FailureReason) -> String {
        switch reason {
        case .launchFailed: return "Its program couldn't be started."
        case .crashLoop(let code):
            return "It kept exiting\(code.map { " (status \($0))" } ?? ""). Check the log, then restart it."
        case .apiVersionMismatch(let version):
            return "It speaks extension API \(version); this Vakta speaks \(vaktaExtensionAPIVersion)."
        case .initializeRejected(let message): return "It refused to start: \(message)"
        case .invalidInitializeResult: return "It answered the handshake with something Vakta doesn't understand."
        }
    }

    static func reason(_ reason: TrustReason) -> String {
        switch reason {
        case .neverApproved: return "This extension hasn't been approved yet."
        case .manifestChanged: return "Its manifest changed since you approved it."
        case .executableChanged: return "Its program changed since you approved it."
        }
    }

    static func describe(_ error: ExtensionLinkError) -> String {
        switch error {
        case .alreadyLinked: return "That folder is already linked."
        case .noManifest: return "The folder has no \(ExtensionManifest.fileName)."
        case .invalidManifest(let problems): return problems.joined(separator: "\n")
        case .duplicateID(let id): return "Another linked extension already uses the ID “\(id)”."
        }
    }

    static func describe(_ error: ExtensionTrustError) -> String {
        switch error {
        case .notLinked: return "The extension is no longer linked."
        case .invalidManifest(let problems): return problems.joined(separator: "\n")
        case let .buildFailed(command, reason): return "Build step “\(command)” \(reason)."
        case .missingExecutable(let path): return "\(path) doesn't exist after building."
        case .saveFailed: return "Couldn't save the approval."
        }
    }
}
