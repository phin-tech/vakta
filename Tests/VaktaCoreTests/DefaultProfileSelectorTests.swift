//
//  DefaultProfileSelectorTests.swift
//  VaktaCoreTests
//
//  Functional-core cases for `DefaultProfileSelector`, the pure extraction of
//  `SessionStore.defaultProfile`'s fallback chain: chosen default -> first
//  profile -> built-in herdr profile. Previously untested (0% coverage,
//  embedded as a computed property on the AppKit-coupled `SessionStore`).

import XCTest
@testable import Vakta

final class DefaultProfileSelectorTests: XCTestCase {
    func test_chosenDefaultExists_isReturned() {
        let chosen = Profile(name: "Chosen", command: "chosen", arguments: "", environment: [:])
        let other = Profile(name: "Other", command: "other", arguments: "", environment: [:])

        let result = DefaultProfileSelector.select(from: [other, chosen], defaultProfileID: chosen.id)

        XCTAssertEqual(result.id, chosen.id)
    }

    func test_noChosenDefault_fallsBackToFirstProfile() {
        let first = Profile(name: "First", command: "first", arguments: "", environment: [:])
        let second = Profile(name: "Second", command: "second", arguments: "", environment: [:])

        let result = DefaultProfileSelector.select(from: [first, second], defaultProfileID: nil)

        XCTAssertEqual(result.id, first.id)
    }

    func test_chosenDefaultNoLongerExists_fallsBackToFirstProfile() {
        let first = Profile(name: "First", command: "first", arguments: "", environment: [:])
        let deletedID = UUID()

        let result = DefaultProfileSelector.select(from: [first], defaultProfileID: deletedID)

        XCTAssertEqual(result.id, first.id)
    }

    func test_emptyProfileList_fallsBackToBuiltInHerdrProfile() {
        let result = DefaultProfileSelector.select(from: [], defaultProfileID: nil)

        XCTAssertEqual(result.id, Profile.herdr.id)
    }
}
