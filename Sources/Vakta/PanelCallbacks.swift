//
//  PanelCallbacks.swift
//  Vakta
//
//  Pure decisions for View Document buttons: one Callback in flight per
//  button, what to do with the Effects an Extension returns (and which to
//  drop when the focused Session changed meanwhile), and parsing a button's
//  shortcut. Buttons never run programs; Effects are things Vakta does.

import Foundation
import VaktaExtensionKit

/// Identifies a button for in-flight tracking: same view, Callback name and
/// payload means the same action.
struct CallbackKey: Hashable {
    var view: String
    var callback: String
    var payloadJSON: String

    init(view: String, button: ViewButton) {
        self.view = view
        callback = button.callback
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        payloadJSON = button.payload.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

struct CallbackTracker: Equatable {
    enum State: Equatable {
        case idle
        case pending
        case failed(String)
    }

    private var states: [CallbackKey: State] = [:]

    func state(_ key: CallbackKey) -> State { states[key] ?? .idle }

    /// `false` when that button's Callback is already in flight.
    mutating func begin(_ key: CallbackKey) -> Bool {
        guard states[key] != .pending else { return false }
        states[key] = .pending
        return true
    }

    mutating func succeed(_ key: CallbackKey) {
        states[key] = nil
    }

    mutating func fail(_ key: CallbackKey, _ message: String) {
        states[key] = .failed(message)
    }

    /// A fresh render clears earlier failure messages.
    mutating func clearFailures() {
        states = states.filter { $0.value == .pending }
    }
}

/// What the panel does for one Effect.
enum PanelAction: Equatable {
    case refresh
    case replace(ViewDocument)
    case push(ViewDocument)
    case pop
    case toast(String)
    case notify(title: String, body: String?)
    case openURL(URL)
    case openPane(cwd: String?, command: [String], title: String?)
    case openSession(cwd: String?, command: [String], title: String?)
}

enum EffectPlanner {
    /// Effects in order. When the result is stale (the focused Session
    /// changed while the Callback ran), view Effects are dropped but
    /// messages and launches still happen: the user did press the button.
    /// Unknown Effects and URLs that aren't http(s) are skipped.
    static func plan(_ effects: [Effect], isStale: Bool) -> [PanelAction] {
        effects.compactMap { effect -> PanelAction? in
            switch effect {
            case .refresh: return isStale ? nil : .refresh
            case .replace(let document): return isStale ? nil : .replace(document)
            case .push(let document): return isStale ? nil : .push(document)
            case .pop: return isStale ? nil : .pop
            case .toast(let text): return .toast(text)
            case let .notify(title, body): return .notify(title: title, body: body)
            case .openURL(let text):
                guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", url.host != nil
                else { return nil }
                return .openURL(url)
            case let .openPane(cwd, command, title): return .openPane(cwd: cwd, command: command, title: title)
            case let .openSession(cwd, command, title): return .openSession(cwd: cwd, command: command, title: title)
            case .unsupported: return nil
            }
        }
    }
}

/// A button's `shortcut`, like `return`, `cmd+return` or `cmd+shift+k`.
struct ButtonShortcut: Equatable {
    enum Key: Equatable {
        case character(Character)
        case `return`, escape, delete, tab, space, up, down, left, right
    }

    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    var key: Key
    var modifiers: Modifiers

    static func parse(_ text: String) -> ButtonShortcut? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty, !parts.dropLast().contains("") else { return nil }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: return nil
            }
        }
        let key: Key
        switch last {
        case "return", "enter": key = .return
        case "escape", "esc": key = .escape
        case "backspace", "delete": key = .delete
        case "tab": key = .tab
        case "space": key = .space
        case "up": key = .up
        case "down": key = .down
        case "left": key = .left
        case "right": key = .right
        default:
            guard last.count == 1, let character = last.first else { return nil }
            key = .character(character)
        }
        return ButtonShortcut(key: key, modifiers: modifiers)
    }

    /// Short display form, like `⌘↩`.
    var symbol: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .return: text += "↩"
        case .escape: text += "⎋"
        case .delete: text += "⌫"
        case .tab: text += "⇥"
        case .space: text += "Space"
        case .up: text += "↑"
        case .down: text += "↓"
        case .left: text += "←"
        case .right: text += "→"
        }
        return text
    }
}
