//
//  HerdrSidebarRowsTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for the sidebar token-row editor (`ui.sidebar.agents`
//  and `ui.sidebar.spaces` `rows`). Only plain string tokens are editable;
//  styled tokens (inline tables) stay read-only. Pure. Plan phase 6.

import XCTest
@testable import Vakta

final class HerdrSidebarRowsTests: XCTestCase {
    func test_parse_readsSingleLineRows() {
        XCTAssertEqual(
            HerdrSidebarRows.parse(source: #"[["state_icon", "workspace"], ["branch", "git_status"]]"#),
            [["state_icon", "workspace"], ["branch", "git_status"]]
        )
    }

    func test_parse_readsMultilineRowsWithCommentsAndTrailingCommas() {
        let source = """
        [
          ["state_icon", "machine"], # top
          ["agent"],
        ]
        """
        XCTAssertEqual(HerdrSidebarRows.parse(source: source), [["state_icon", "machine"], ["agent"]])
    }

    func test_parse_styledTokenOrMalformed_isNilSoItStaysReadOnly() {
        XCTAssertNil(HerdrSidebarRows.parse(source: #"[[{ token = "workspace", bold = true }]]"#))
        XCTAssertNil(HerdrSidebarRows.parse(source: #"[["a""#))
        XCTAssertNil(HerdrSidebarRows.parse(source: "\"just a string\""))
        XCTAssertNil(HerdrSidebarRows.parse(source: "[[1, 2]]"))
    }

    func test_parse_emptyArray_isNoRows() {
        XCTAssertEqual(HerdrSidebarRows.parse(source: "[]"), [])
    }

    func test_format_isSingleLineAndRoundTrips() {
        let rows = [["state_icon", "$summary"], ["agent"]]
        let text = HerdrSidebarRows.format(rows)
        XCTAssertEqual(text, #"[["state_icon", "$summary"], ["agent"]]"#)
        XCTAssertEqual(HerdrSidebarRows.parse(source: text), rows)
    }

    func test_defaults_matchTheDocumentedRows() {
        XCTAssertEqual(HerdrSidebarRows.defaultRows(for: .agents), [["state_icon", "machine", "workspace", "tab"], ["agent"]])
        XCTAssertEqual(HerdrSidebarRows.defaultRows(for: .spaces), [["state_icon", "workspace"], ["branch", "git_status"]])
    }

    func test_problems_flagUnknownTokensAndLimits() {
        XCTAssertEqual(HerdrSidebarRows.problems(in: [["state_icon", "$summary", "workspace"]], for: .agents), [])
        XCTAssertFalse(HerdrSidebarRows.problems(in: [["nonsense"]], for: .agents).isEmpty)
        // `machine` is an agent token, not a space token.
        XCTAssertFalse(HerdrSidebarRows.problems(in: [["machine"]], for: .spaces).isEmpty)
        XCTAssertFalse(HerdrSidebarRows.problems(in: [["$"]], for: .agents).isEmpty)
        XCTAssertFalse(HerdrSidebarRows.problems(in: Array(repeating: ["agent"], count: 17), for: .agents).isEmpty)
        XCTAssertFalse(HerdrSidebarRows.problems(in: [Array(repeating: "agent", count: 17)], for: .agents).isEmpty)
    }

    func test_parseTokenList_splitsCommaSeparatedRowText() {
        XCTAssertEqual(HerdrSidebarRows.tokens(fromRowText: " state_icon, workspace ,, tab "), ["state_icon", "workspace", "tab"])
        XCTAssertEqual(HerdrSidebarRows.tokens(fromRowText: ""), [])
    }

    func test_catalog_rowGapEntriesExist() {
        XCTAssertEqual(HerdrConfigCatalog.entry(for: "ui.sidebar.agents.row_gap")?.defaultValue, .integer(0))
        XCTAssertEqual(HerdrConfigCatalog.entry(for: "ui.sidebar.spaces.row_gap")?.defaultValue, .integer(0))
    }
}
