//
//  SessionTerminalDelegate.swift
//  Vakta
//
//  `AppTerminalView.delegate` is one weak slot and the view dispatches by
//  `as? any <Protocol>`, so adding search next to `TerminalViewState`'s
//  callbacks needs a single object conforming to all of them. Everything
//  forwards to `viewState` except search, which goes to `searchModel`.

import GhosttyTerminal

@MainActor
final class SessionTerminalDelegate:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceScrollbarDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceClipboardConfirmationDelegate,
    TerminalSurfaceColorChangeDelegate,
    TerminalSurfaceFontSizeDelegate,
    TerminalSurfaceSearchDelegate
{
    private let viewState: TerminalViewState
    private let searchModel: TerminalSearchModel

    init(viewState: TerminalViewState, searchModel: TerminalSearchModel) {
        self.viewState = viewState
        self.searchModel = searchModel
    }

    func terminalDidChangeTitle(_ title: String) { viewState.terminalDidChangeTitle(title) }
    func terminalDidResize(_ size: TerminalGridMetrics) { viewState.terminalDidResize(size) }
    func terminalDidChangeFocus(_ focused: Bool) { viewState.terminalDidChangeFocus(focused) }
    func terminalDidClose(processAlive: Bool) { viewState.terminalDidClose(processAlive: processAlive) }
    func terminalDidRingBell() { viewState.terminalDidRingBell() }
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        viewState.terminalDidRequestDesktopNotification(title: title, body: body)
    }
    func terminalDidChangeWorkingDirectory(_ path: String) { viewState.terminalDidChangeWorkingDirectory(path) }
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { viewState.terminalDidUpdateScrollbar(scrollbar) }
    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        viewState.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }
    func terminalDidAttachSurface(_ surface: TerminalSurface) { viewState.terminalDidAttachSurface(surface) }
    func terminalDidDetachSurface() { viewState.terminalDidDetachSurface() }
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        viewState.terminalDidRequestClipboardConfirmation(request)
    }
    func terminalDidChangeColor(_ change: TerminalColorChange) { viewState.terminalDidChangeColor(change) }
    func terminalDidChangeFontSize(_ fontSize: Float) { viewState.terminalDidChangeFontSize(fontSize) }

    func terminalDidStartSearch(needle: String?) { searchModel.terminalDidStartSearch(needle: needle) }
    func terminalDidEndSearch() { searchModel.terminalDidEndSearch() }
    func terminalDidUpdateSearchTotal(_ total: Int?) { searchModel.terminalDidUpdateSearchTotal(total) }
    func terminalDidUpdateSearchSelected(_ selected: Int?) { searchModel.terminalDidUpdateSearchSelected(selected) }
}
