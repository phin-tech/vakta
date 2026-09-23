//
//  LeaderKeyTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for Spacemacs/Doom-style leader keys: the default
//  `LeaderTree`, `LeaderSequencePlanner.step`, `LeaderHintAssembler` (the
//  which-key rows), and `LeaderSettings` decoding. Pure values only; the
//  matcher wiring lives in VaktaIntegrationTests.

import AppKit
import XCTest
@testable import Vakta

private enum Key {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let g: UInt16 = 5
    static let v: UInt16 = 9
    static let q: UInt16 = 12
    static let w: UInt16 = 13
    static let n: UInt16 = 45
    static let x: UInt16 = 7
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let backspace: UInt16 = 51
    static let escape: UInt16 = 53
    static let comma: UInt16 = 43
    static let one: UInt16 = 18
    static let two: UInt16 = 19
    static let o: UInt16 = 31
    static let f: UInt16 = 3
    static let three: UInt16 = 20
}

private let supported = CommandContext(supportsSelectedSessionActions: true, sessionTitles: ["alpha"])
private let unsupported = CommandContext(supportsSelectedSessionActions: false)

// MARK: - Default tree

final class LeaderTreeTests: XCTestCase {
    private func leaves(_ node: LeaderNode) -> [AppCommand] {
        switch node {
        case .command(let command): return [command]
        case .group(_, let children): return children.flatMap { leaves($0.node) }
        }
    }

    private func groups(_ node: LeaderNode) -> [(title: String, children: [LeaderEntry])] {
        guard case .group(let title, let children) = node else { return [] }
        return [(title, children)] + children.flatMap { groups($0.node) }
    }

    func test_defaultTree_everyLeafIsABindableCommand() {
        for command in leaves(LeaderTree.defaultRoot) {
            XCTAssertTrue(AppCommandCatalog.bindableCommands.contains(command), "\(command)")
        }
    }

    func test_defaultTree_siblingKeysAreUnique_andNoGroupIsEmpty() {
        for group in groups(LeaderTree.defaultRoot) {
            let keys = group.children.map(\.keyCode)
            XCTAssertEqual(Set(keys).count, keys.count, "duplicate key under \(group.title)")
            XCTAssertFalse(group.children.isEmpty, "\(group.title) is empty")
        }
    }

    func test_defaultTree_leavesOutTextEditingAndWindowCommands() {
        // Those keep their ⌘ chords; a leader sequence for Copy would be noise.
        let excluded: Set<AppCommand> = [.copy, .paste, .cut, .selectAll, .closeWindow]
        XCTAssertTrue(Set(leaves(LeaderTree.defaultRoot)).isDisjoint(with: excluded))
    }

    func test_defaultTree_doomStylePaths() {
        let root = LeaderTree.defaultRoot
        XCTAssertEqual(root.node(at: [Key.space]), .command(.openSessionSwitcher))
        XCTAssertEqual(root.node(at: [Key.comma]), .command(.openPreferences))
        XCTAssertEqual(root.node(at: [Key.w, Key.v]), .command(.splitPaneRight))
        XCTAssertEqual(root.node(at: [Key.w, Key.s]), .command(.splitPaneDown))
        XCTAssertEqual(root.node(at: [Key.s, Key.n]), .command(.newSession))
        XCTAssertEqual(root.node(at: [Key.s, Key.one]), .command(.selectSession(0)))
        XCTAssertEqual(root.node(at: [Key.tab, Key.n]), .command(.newWorkspace))
        XCTAssertEqual(root.node(at: [Key.tab, Key.one]), .command(.focusWorkspace(0)))
        XCTAssertEqual(root.node(at: [Key.q, Key.q]), .command(.quit))
    }

    func test_commandPaths_mapEachLeafToItsKeySequence() {
        let paths = LeaderTree.defaultRoot.commandPaths()
        XCTAssertEqual(paths[.toggleFileSidebar], [Key.o, Key.f])
        XCTAssertEqual(paths[.toggleFileSidebarChanges], [Key.o, Key.g])
        XCTAssertEqual(paths[.splitPaneRight], [Key.w, Key.v])
        XCTAssertEqual(paths[.selectSession(0)], [Key.s, Key.one])
        XCTAssertEqual(paths[.openSessionSwitcher], [Key.space])
        XCTAssertNil(paths[.copy], "not in the tree")
    }

    func test_sequenceDisplay_joinsGlyphsWithSpaces() {
        XCTAssertEqual(LeaderHintAssembler.sequence(for: [Key.o, Key.f]), "o f")
        XCTAssertEqual(LeaderHintAssembler.sequence(for: [Key.tab, Key.n]), "TAB n")
    }

    func test_nodeAtPath_emptyPathIsRoot_unknownPathIsNil() {
        let root = LeaderTree.defaultRoot
        XCTAssertEqual(root.node(at: []), root)
        XCTAssertNil(root.node(at: [Key.a, Key.a]))
        XCTAssertNil(root.node(at: [Key.space, Key.space]), "a leaf has no children")
    }
}

// MARK: - Sequence stepping

final class LeaderSequencePlannerTests: XCTestCase {
    private func step(
        _ path: [UInt16],
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        context: CommandContext = supported
    ) -> LeaderStepOutcome {
        LeaderSequencePlanner.step(
            root: LeaderTree.defaultRoot,
            path: path,
            keyCode: keyCode,
            modifiers: modifiers,
            context: context
        )
    }

    func test_groupKey_descends() {
        XCTAssertEqual(step([], Key.w), .descend(path: [Key.w]))
    }

    func test_leafKey_commits() {
        XCTAssertEqual(step([Key.w], Key.v), .commit(.splitPaneRight))
        XCTAssertEqual(step([], Key.space), .commit(.openSessionSwitcher))
    }

    func test_escape_cancels_atAnyDepth() {
        XCTAssertEqual(step([], Key.escape), .cancel)
        XCTAssertEqual(step([Key.w], Key.escape), .cancel)
    }

    func test_backspace_goesUpOneLevel_orCancelsAtRoot() {
        XCTAssertEqual(step([Key.w], Key.backspace), .back(path: []))
        XCTAssertEqual(step([], Key.backspace), .cancel)
    }

    func test_unknownKey_cancels() {
        XCTAssertEqual(step([], Key.a), .cancel)
        XCTAssertEqual(step([Key.w], Key.a), .cancel)
    }

    func test_modifiedKey_cancels_evenIfTheBareKeyWouldMatch() {
        XCTAssertEqual(step([], Key.w, modifiers: .command), .cancel)
        XCTAssertEqual(step([Key.w], Key.v, modifiers: .shift), .cancel)
    }

    func test_deviceOnlyModifierFlags_doNotCountAsModified() {
        XCTAssertEqual(step([], Key.w, modifiers: [.numericPad, .function, .capsLock]), .descend(path: [Key.w]))
    }

    func test_unavailableLeaf_cancels() {
        XCTAssertEqual(step([Key.s], Key.x, context: unsupported), .cancel, "stop session needs a multiplexer session")
        XCTAssertEqual(step([Key.s], Key.x, context: supported), .commit(.stopSession))
    }

    func test_groupWithNoAvailableLeaves_cancelsInsteadOfDescending() {
        XCTAssertEqual(step([], Key.w, context: unsupported), .cancel)
        XCTAssertEqual(step([], Key.tab, context: unsupported), .cancel)
    }

    func test_groupWithSomeAvailableLeaves_stillDescends() {
        XCTAssertEqual(step([], Key.s, context: unsupported), .descend(path: [Key.s]))
    }

    func test_sessionDigit_commitsWhenThatSessionExists_cancelsOtherwise() {
        let two = CommandContext(supportsSelectedSessionActions: false, sessionTitles: ["alpha", "beta"])
        XCTAssertEqual(step([Key.s], Key.one, context: two), .commit(.selectSession(0)))
        XCTAssertEqual(step([Key.s], Key.two, context: two), .commit(.selectSession(1)))
        XCTAssertEqual(step([Key.s], Key.three, context: two), .cancel)
    }

    func test_workspaceDigit_commitsWhenThatWorkspaceExists_cancelsOtherwise() {
        let context = CommandContext(supportsSelectedSessionActions: true, workspaceTitles: ["guildhall", "notes"])
        XCTAssertEqual(step([Key.tab], Key.one, context: context), .commit(.focusWorkspace(0)))
        XCTAssertEqual(step([Key.tab], Key.two, context: context), .commit(.focusWorkspace(1)))
        XCTAssertEqual(step([Key.tab], Key.three, context: context), .cancel)
    }

    func test_stalePath_cancels() {
        XCTAssertEqual(step([Key.a], Key.v), .cancel)
    }
}

// MARK: - Which-key rows

final class LeaderHintAssemblerTests: XCTestCase {
    private func hints(_ path: [UInt16], _ context: CommandContext) -> [LeaderHint] {
        LeaderHintAssembler.hints(root: LeaderTree.defaultRoot, path: path, context: context)
    }

    func test_rootHints_followTreeOrder_andMarkGroups() {
        let rows = hints([], supported)
        guard case .group(_, let children) = LeaderTree.defaultRoot else { return XCTFail("root is a group") }
        XCTAssertEqual(rows.map(\.keyCode), children.map(\.keyCode))
        let panes = rows.first { $0.keyCode == Key.w }
        XCTAssertEqual(panes?.isGroup, true)
        XCTAssertEqual(panes?.title, "Panes")
        let switcher = rows.first { $0.keyCode == Key.space }
        XCTAssertEqual(switcher?.isGroup, false)
        XCTAssertEqual(switcher?.title, AppCommand.openSessionSwitcher.title)
    }

    func test_unavailable_hidesLeavesAndGroupsWithNothingLeft() {
        let root = hints([], unsupported).map(\.keyCode)
        XCTAssertFalse(root.contains(Key.w), "Panes has only multiplexer commands")
        XCTAssertFalse(root.contains(Key.tab), "Workspaces has only multiplexer commands")
        XCTAssertTrue(root.contains(Key.s))

        let sessions = hints([Key.s], unsupported)
        XCTAssertFalse(sessions.contains { $0.keyCode == Key.x }, "Stop Session hidden")
        XCTAssertTrue(sessions.contains { $0.keyCode == Key.n })
    }

    func test_sessionRows_showSessionNames_andHideDigitsWithNoSession() {
        let context = CommandContext(supportsSelectedSessionActions: false, sessionTitles: ["alpha", "guildhall"])
        let rows = hints([Key.s], context)
        XCTAssertEqual(rows.first { $0.keyCode == Key.one }?.title, "alpha")
        XCTAssertEqual(rows.first { $0.keyCode == Key.two }?.title, "guildhall")
        XCTAssertFalse(rows.contains { $0.keyCode == Key.three }, "no third session")
        XCTAssertEqual(rows.first { $0.keyCode == Key.n }?.title, AppCommand.newSession.title)
    }

    func test_workspaceRows_showNames_markTheFocusedOne_andHideMissingDigits() {
        let context = CommandContext(
            supportsSelectedSessionActions: true,
            workspaceTitles: ["guildhall", "notes"],
            focusedWorkspaceIndex: 1
        )
        let rows = hints([Key.tab], context)
        let first = rows.first { $0.keyCode == Key.one }
        let second = rows.first { $0.keyCode == Key.two }
        XCTAssertEqual(first?.title, "guildhall")
        XCTAssertEqual(first?.isCurrent, false)
        XCTAssertEqual(second?.title, "notes")
        XCTAssertEqual(second?.isCurrent, true)
        XCTAssertFalse(rows.contains { $0.keyCode == Key.three })
        XCTAssertEqual(rows.first { $0.keyCode == Key.n }?.isCurrent, false)
    }

    func test_workspacesGroup_isShownForAWorkspaceOnlySession() {
        // A backend with workspaces to focus but no mutating actions still
        // gets the TAB group, just without n/d.
        let context = CommandContext(supportsSelectedSessionActions: false, workspaceTitles: ["guildhall"])
        XCTAssertTrue(hints([], context).contains { $0.keyCode == Key.tab })
        XCTAssertEqual(hints([Key.tab], context).map(\.keyCode), [Key.one])
    }

    func test_leafOrUnknownPath_hasNoHints() {
        XCTAssertEqual(hints([Key.space], supported), [])
        XCTAssertEqual(hints([Key.a], supported), [])
    }

    func test_keyGlyphs_lowercaseLetters_namedSpaceAndTab() {
        let rows = hints([], supported)
        XCTAssertEqual(rows.first { $0.keyCode == Key.w }?.key, "w")
        XCTAssertEqual(rows.first { $0.keyCode == Key.space }?.key, "SPC")
        XCTAssertEqual(rows.first { $0.keyCode == Key.tab }?.key, "TAB")
        XCTAssertEqual(rows.first { $0.keyCode == Key.comma }?.key, ",")
    }
}

// MARK: - Settings decoding

final class LeaderSettingsCodecTests: XCTestCase {
    private func decode(_ json: String) throws -> LeaderSettings {
        try JSONDecoder().decode(LeaderSettings.self, from: Data(json.utf8))
    }

    func test_default_isOff_withCommandSlash() {
        let settings = LeaderSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.modifierMask, .command)
        XCTAssertEqual(settings.keyCode, 44)
    }

    func test_emptyObject_decodesToDefaults() throws {
        XCTAssertEqual(try decode("{}"), LeaderSettings())
    }

    func test_missingChord_keepsDefaultChord() throws {
        let settings = try decode(#"{"isEnabled": true}"#)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.modifierMask, .command)
        XCTAssertEqual(settings.keyCode, 44)
    }

    func test_roundTrips_includingModifierMask() throws {
        let original = LeaderSettings(isEnabled: true, modifierMask: [.control, .option], keyCode: 40)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LeaderSettings.self, from: data), original)
    }

    func test_defaultChord_isNotAShippedKeybinding() {
        let settings = LeaderSettings()
        XCTAssertFalse(Keybinding.defaults.contains {
            $0.modifierMask == settings.modifierMask && $0.keyCode == settings.keyCode
        })
    }

    // MARK: Which-key delay

    func test_hintDelay_defaultsTo300ms() {
        XCTAssertEqual(LeaderSettings().hintDelayMilliseconds, 300)
        XCTAssertEqual(LeaderSettings().hintDelay, .milliseconds(300))
    }

    func test_fileWithoutHintDelay_decodesToTheDefault() throws {
        // leader.json as written before the delay was configurable.
        let settings = try decode(#"{"isEnabled":true,"modifierMask":1048576,"keyCode":44}"#)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.hintDelayMilliseconds, 300)
    }

    func test_hintDelay_roundTrips() throws {
        let original = LeaderSettings(isEnabled: true, hintDelayMilliseconds: 0)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LeaderSettings.self, from: data), original)
    }

    func test_outOfRangeHintDelay_isKeptOnDecode_butClampedAtUse() throws {
        let negative = try decode(#"{"hintDelayMilliseconds": -50}"#)
        XCTAssertEqual(negative.hintDelayMilliseconds, -50, "the raw value is preserved")
        XCTAssertEqual(negative.hintDelay, .zero)

        let huge = try decode(#"{"hintDelayMilliseconds": 999999}"#)
        XCTAssertEqual(huge.hintDelay, .milliseconds(LeaderSettings.maximumHintDelayMilliseconds))
    }

    func test_zeroHintDelay_showsImmediately() {
        XCTAssertEqual(LeaderSettings(hintDelayMilliseconds: 0).hintDelay, .zero)
    }

    func test_chordDisplayString_matchesKeybindingRendering() {
        XCTAssertEqual(LeaderSettings().chordDisplayString, "⌘/")
    }
}
