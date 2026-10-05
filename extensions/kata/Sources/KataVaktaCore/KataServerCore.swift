//
//  KataServerCore.swift
//  KataVaktaCore
//
//  Pure decisions for the Kata Extension's protocol loop: what to answer,
//  what to log. The executable owns stdin/stdout and the `kata` CLI.

import Foundation
import VaktaExtensionKit

public enum KataServerCore {
    public static let name = "Kata"

    public static func initializeResult(for params: InitializeParams) -> InitializeResult {
        InitializeResult(apiVersion: vaktaExtensionAPIVersion, name: name)
    }

    /// One log line describing a contexts snapshot.
    public static func describe(_ contexts: [ExtensionContext]) -> String {
        let focused = contexts.first(where: \.focused)
        let summary = focused.map { "focused \($0.sessionKey.backend):\($0.sessionKey.sessionName) at \($0.gitRoot ?? $0.cwd ?? "?")" }
        return "contexts: \(contexts.count) session(s)" + (summary.map { ", \($0)" } ?? "")
    }
}
