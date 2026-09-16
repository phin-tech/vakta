//
//  PassthroughSettings.swift
//  Vakta
//
//  The double-tap modifier chord that toggles "passthrough" mode, in which
//  `KeybindingMatcher` stops intercepting anything and every key goes raw to
//  the focused session. Double-tapping the same modifier again leaves the mode.
//  Persisted like the other settings; the mode itself is transient (always off
//  at launch).

import AppKit

/// Which modifier's double-tap toggles passthrough, or `off` to disable it.
enum PassthroughToggle: String, Codable, CaseIterable, Identifiable, Equatable {
    case off
    case shift
    case command
    case control
    case option

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .shift: return "Double-tap ⇧ Shift"
        case .command: return "Double-tap ⌘ Command"
        case .control: return "Double-tap ⌃ Control"
        case .option: return "Double-tap ⌥ Option"
        }
    }

    /// The modifier flag to watch, or nil when disabled.
    var modifier: NSEvent.ModifierFlags? {
        switch self {
        case .off: return nil
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
}

enum PassthroughSettingsPersistence {
    static func store(root: URL) -> PersistedFileStore<JSONCodec<PassthroughToggle>> {
        PersistedFileStore(root: root, fileName: "passthrough.json", codec: JSONCodec())
    }

    static func load(root: URL) -> FileLoadOutcome<PassthroughToggle> {
        store(root: root).load()
    }

    @discardableResult
    static func save(_ toggle: PassthroughToggle, root: URL) -> FileSaveOutcome {
        store(root: root).save(toggle)
    }
}
