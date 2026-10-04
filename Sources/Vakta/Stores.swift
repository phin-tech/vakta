//
//  Stores.swift
//  Vakta
//
//  One owner for the app's observable stores, so `AppDelegate` and the
//  Preferences window pass a single value around instead of a growing list of
//  parameters and `.environmentObject(...)` calls. Views still read each store
//  by type via `@EnvironmentObject` (SwiftUI observes per-type); this only
//  bundles construction and injection.

import Combine
import SwiftUI

@MainActor
final class Stores {
    let keybindingMatcher: KeybindingMatcher
    let appearanceStore: AppearanceStore
    let sidebarSettings: SidebarSettingsStore
    let notificationSettings: NotificationSettingsStore
    let unreadTrackingSettings: UnreadTrackingSettingsStore
    let terminalSettings: TerminalSettingsStore
    let herdrPreferences: HerdrPreferencesStore
    let fileSidebarPreferences: FileSidebarPreferencesStore
    let statusBarPreferences: StatusBarPreferencesStore
    let editorPreferences: EditorPreferencesStore
    let sessionStore: SessionStore
    let workspaceRefreshMonitor: WorkspaceRefreshMonitor
    let extensionRegistry: ExtensionRegistryStore
    let extensionHost: ExtensionHost
    let loginEnvironment = LoginEnvironmentSnapshot()
    private var loginEnvironmentObserver: AnyCancellable?
    let extensionContextMonitor: ExtensionContextMonitor
    let panelViewStore: PanelViewStore
    let statusItemStore: StatusItemStore
    let sessionBadgeStore: SessionBadgeStore
    let extensionNotifier: ExtensionNotifier
    let persistenceFailures = PersistenceFailureCenter()
    let preferencesRouter = PreferencesRouter()

    /// Built on first use (opening the Herdr Config pane or a ⌘K action), so
    /// launch does no herdr-config work. PATH is the process PATH plus the
    /// usual user bin dirs -- `herdr` typically lives in ~/.local/bin.
    lazy var herdrConfig: HerdrConfigStore = {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let path = [environment["PATH"], ShellEnvironment.fallbackPATH()].compactMap { $0 }.joined(separator: ":")
        let store = HerdrConfigStore(
            file: HerdrConfigFile(
                url: HerdrConfigLocator.resolve(environment: environment, home: home),
                backupsToKeep: 5, now: Date.init),
            checker: HerdrConfigChecker(herdrCommand: ["herdr"], path: path),
            reloader: HerdrConfigReloader(herdrCommand: ["herdr"], path: path)
        )
        store.load()
        return store
    }()

    /// `root` is resolved once by the caller (`AppDelegate`, which can fail
    /// launch cleanly if it throws) and threaded through every store here,
    /// rather than each store resolving -- and creating -- Application
    /// Support independently. `resolvedPATH` is likewise created by the
    /// caller as early in launch as possible, so its background shell
    /// resolution has the maximum head start before `SessionStore` needs it.
    init(root: URL, resolvedPATH: ResolvedPATH) {
        keybindingMatcher = KeybindingMatcher(root: root)
        appearanceStore = AppearanceStore(root: root)
        sidebarSettings = SidebarSettingsStore(root: root)
        notificationSettings = NotificationSettingsStore(root: root)
        unreadTrackingSettings = UnreadTrackingSettingsStore(root: root)
        terminalSettings = TerminalSettingsStore(root: root)
        herdrPreferences = HerdrPreferencesStore(root: root)
        fileSidebarPreferences = FileSidebarPreferencesStore(root: root)
        statusBarPreferences = StatusBarPreferencesStore(root: root)
        editorPreferences = EditorPreferencesStore(root: root)
        // `sessionStore` needs `terminalSettings`/`unreadTrackingSettings`
        // (already initialized above).
        sessionStore = SessionStore(
            terminalSettings: terminalSettings,
            unreadTrackingSettings: unreadTrackingSettings,
            root: root,
            pathResolver: resolvedPATH
        )
        let sessionStore = sessionStore
        extensionRegistry = ExtensionRegistryStore(root: root, path: { sessionStore.resolvedPATH })
        extensionHost = ExtensionHost(
            registry: extensionRegistry,
            supportRoot: root,
            hostVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            environment: { ["PATH": sessionStore.resolvedPATH, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"] },
            loginEnvironment: { [loginEnvironment] in loginEnvironment.current }
        )
        extensionContextMonitor = ExtensionContextMonitor(sessionStore: sessionStore, host: extensionHost)
        let extensionHost = extensionHost
        loginEnvironmentObserver = loginEnvironment.$isResolved
            .filter { $0 }
            .sink { _ in extensionHost.loginEnvironmentChanged() }
        panelViewStore = PanelViewStore(host: extensionHost)
        statusItemStore = StatusItemStore(host: extensionHost, registry: extensionRegistry)
        sessionBadgeStore = SessionBadgeStore(host: extensionHost, registry: extensionRegistry)
        let effectSink = PanelEffectSink(
            openURL: { NSWorkspace.shared.open($0) },
            notify: { title, body in
                guard let sessionID = sessionStore.selectedID else { return }
                sessionStore.notifier.deliverExtensionNotice(sessionID: sessionID, title: title, body: body ?? "")
            },
            openPane: { cwd, command, _ in
                guard let id = sessionStore.selectedID, let session = sessionStore.sessions.first(where: { $0.id == id }) else {
                    return "No session is focused."
                }
                guard case .multiplexer(let target) = LaunchTargetResolver.resolve(session.profile),
                      let plan = ExtensionLaunchPlanner.panePlan(
                          target: target, sessionName: session.sessionName, cwd: cwd, command: command)
                else { return "The focused session isn't running herdr or tmux, so there's no pane to split." }
                let environment = target.environment.merging(
                    ["PATH": sessionStore.resolvedPATH, "HOME": NSHomeDirectory()], uniquingKeysWith: { profile, _ in profile }
                )
                return await Task.detached { ExtensionPaneLauncher.launch(plan, environment: environment) }.value
            },
            openSession: { cwd, command, title in
                switch ExtensionLaunchPlanner.sessionProfile(cwd: cwd, command: command, title: title) {
                case .failure(let error):
                    return error.message
                case .success(let profile):
                    _ = sessionStore.createSession(profile: profile, customName: title, workingDirectory: cwd, isTransient: true)
                    return nil
                }
            }
        )
        let notificationSettings = notificationSettings
        extensionNotifier = ExtensionNotifier(
            host: extensionHost,
            registry: extensionRegistry,
            notifier: sessionStore.notifier,
            notificationsAllowed: { notificationSettings.notifyOnAttention },
            selectedSessionID: { sessionStore.selectedID },
            appActive: { NSApp.isActive },
            sessionID: { key in
                sessionStore.sessions.first { session in
                    let backend: MultiplexerTarget.Backend?
                    if case .multiplexer(let target) = LaunchTargetResolver.resolve(session.profile) { backend = target.backend } else { backend = nil }
                    return ExtensionContextPlanner.sessionKey(backend: backend, sessionName: session.sessionName, sessionID: session.id) == key
                }?.id
            }
        )
        panelViewStore.effectSink = effectSink
        statusItemStore.effectSink = effectSink
        sessionBadgeStore.effectSink = effectSink
        workspaceRefreshMonitor = WorkspaceRefreshMonitor(
            sessionStore: sessionStore,
            herdrPreferences: herdrPreferences,
            fileSidebarPreferences: fileSidebarPreferences
        )
    }
}

extension View {
    /// Injects every app store into the environment in one call.
    func environmentStores(_ stores: Stores) -> some View {
        environmentObject(stores.keybindingMatcher)
            .environmentObject(stores.appearanceStore)
            .environmentObject(stores.sidebarSettings)
            .environmentObject(stores.notificationSettings)
            .environmentObject(stores.unreadTrackingSettings)
            .environmentObject(stores.terminalSettings)
            .environmentObject(stores.herdrPreferences)
            .environmentObject(stores.fileSidebarPreferences)
            .environmentObject(stores.statusBarPreferences)
            .environmentObject(stores.editorPreferences)
            .environmentObject(stores.sessionStore)
            .environmentObject(stores.sessionStore.notifier)
            .environmentObject(stores.persistenceFailures)
            .environmentObject(stores.preferencesRouter)
            .environmentObject(stores.extensionRegistry)
            .environmentObject(stores.extensionHost)
            .environmentObject(stores.panelViewStore)
            .environmentObject(stores.sessionBadgeStore)
    }
}
