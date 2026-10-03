//
//  ExtensionLaunch.swift
//  Vakta
//
//  Pure plans for an Extension's `open_pane` and `open_session` Effects.
//  The command is argv from the Extension (data), so it is never spliced
//  into shell text unquoted: tmux and herdr get it as separate arguments,
//  and a new Session's profile gets each word shell-quoted.

import Foundation

enum ExtensionLaunchPlanner {
    /// How to run `command` in a new pane next to the focused one.
    enum PanePlan: Equatable {
        /// One invocation (tmux runs the argv directly in the new pane).
        case single([String])
        /// herdr: split first, read the new pane id from the split's output,
        /// then run the command in it (`runArgv` + pane id + command).
        case splitThenRun(split: [String], runPrefix: [String], command: [String])
    }

    static func panePlan(target: MultiplexerTarget, sessionName: String, cwd: String?, command: [String]) -> PanePlan? {
        guard !command.isEmpty else { return nil }
        switch target.backend {
        case .tmux:
            // `--` ends tmux's options; the rest is run directly, without a shell.
            let directory = cwd.map { ["-c", $0] } ?? []
            return .single(target.tmuxArgv(["split-window", "-h", "-t", sessionName] + directory + ["--"] + command))
        case .herdr:
            let base = [target.executable, "--session", sessionName]
            let directory = cwd.map { ["--cwd", $0] } ?? []
            return .splitThenRun(
                split: base + ["pane", "split", "--current", "--direction", "right"] + directory + ["--focus"],
                runPrefix: base + ["pane", "run"],
                command: command
            )
        }
    }

    /// herdr's split prints a `pane_info` envelope; returns the new pane's id.
    static func herdrSplitPaneID(_ output: String) -> String? {
        struct Envelope: Decodable {
            struct Result: Decodable {
                struct Pane: Decodable { var pane_id: String }
                var type: String
                var pane: Pane?
            }
            var result: Result
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(output.utf8)),
              envelope.result.type == "pane_info"
        else { return nil }
        return envelope.result.pane?.pane_id
    }

    /// A transient profile that runs `command` as a new Session, or a reason
    /// it can't.
    static func sessionProfile(cwd: String?, command: [String], title: String?) -> Result<Profile, LaunchCommandPlanner.ValidationError> {
        guard let program = command.first, !program.isEmpty else {
            return .failure(.init(message: "The extension gave no command to run."))
        }
        // The profile template substitutes `{name}`; extension data must not
        // be able to trigger that.
        guard !command.contains(where: { $0.contains("{name}") }) else {
            return .failure(.init(message: "The command can't contain {name}."))
        }
        let quoted = command.map(LaunchCommandPlanner.shellQuote)
        return .success(Profile(
            name: title ?? (program as NSString).lastPathComponent,
            command: quoted[0],
            arguments: quoted.dropFirst().joined(separator: " "),
            workingDirectory: cwd
        ))
    }
}

/// Runs a `PanePlan`. Blocks on short multiplexer CLI calls: call it off the
/// main actor.
enum ExtensionPaneLauncher {
    /// `nil` on success, else a short reason.
    static func launch(_ plan: ExtensionLaunchPlanner.PanePlan, environment: [String: String]) -> String? {
        switch plan {
        case .single(let argv):
            return run(argv, environment: environment).failure
        case let .splitThenRun(split, runPrefix, command):
            let result = run(split, environment: environment)
            if let failure = result.failure { return failure }
            guard let paneID = ExtensionLaunchPlanner.herdrSplitPaneID(result.output) else {
                return "herdr didn't report the new pane."
            }
            return run(runPrefix + [paneID] + command, environment: environment).failure
        }
    }

    private static func run(_ argv: [String], environment: [String: String]) -> (output: String, failure: String?) {
        let raw = BoundedProcessRunner.runRaw(executable: "/usr/bin/env", arguments: argv, environment: environment, timeout: 10)
        let output = String(decoding: raw.stdout, as: UTF8.self)
        switch ProcessResultInterpreter.interpret(raw) {
        case .success, .invalidUTF8: return (output, nil)
        case .launchFailed: return (output, "Couldn't run \(argv.first ?? "the multiplexer").")
        case .nonZeroExit: return (output, "The multiplexer couldn't open the pane.")
        case .timedOut: return (output, "The multiplexer didn't respond.")
        case .cancelled: return (output, "Cancelled.")
        }
    }
}
