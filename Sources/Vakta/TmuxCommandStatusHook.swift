//
//  TmuxCommandStatusHook.swift
//  Vakta
//
//  The pinned Ghostty integration already runs shell precmd hooks and reports
//  OSC 133 command completion through TerminalViewState. This value type keeps
//  the equivalent tmux hook source explicit and testable, while the recorder
//  below consumes the host callback without changing the user's shell files.
//

import Foundation

/// Shared names and shell source for the per-window tmux command status.
enum TmuxCommandStatusHook {
    static let optionName = "@vakta_last_exit"

    /// A zsh precmd hook for disposable shells and integration tests. It
    /// captures `$?` before invoking tmux, and targets the current pane's
    /// window so each tmux tab keeps its own result.
    static let zshSource = """
    autoload -Uz add-zsh-hook
    if (( ! ${+_vakta_tmux_status_loaded} )); then
        typeset -g _vakta_tmux_status_loaded=1
        _vakta_tmux_status_precmd() {
            local code=$?
            if [[ -n \"${TMUX_PANE-}\" ]]; then
                command tmux set-window-option -t \"$TMUX_PANE\" \"\(optionName)\" \"$code\" >/dev/null 2>&1 || true
            fi
            return \"$code\"
        }
        add-zsh-hook precmd _vakta_tmux_status_precmd
    fi
    """

    /// Parses the value of `#{@vakta_last_exit}`. tmux emits an empty string
    /// before the first hook invocation and for an unset option.
    static func exitCode(from rawValue: Substring) -> Int? {
        Int(rawValue)
    }
}

/// Runs the host-side half of the command-status hook. Ghostty's shell
/// integration emits the command-finished callback for tmux's nested shell;
/// this persists the callback's exit code on the session's current window in
/// one tmux invocation for the next workspace refresh.
enum TmuxCommandStatusRecorder {
    @discardableResult
    static func record(
        exitCode: Int,
        sessionName: String,
        target: MultiplexerTarget,
        path: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Bool {
        guard target.backend == .tmux,
              let setArgv = target.setActiveWorkspaceCommandStatusArgv(
                  sessionName: sessionName,
                  exitCode: exitCode
              )
        else { return false }

        return ProcessRunner.run(
            setArgv,
            path: path,
            environment: target.environment,
            isCancelled: isCancelled
        ) != nil
    }
}
