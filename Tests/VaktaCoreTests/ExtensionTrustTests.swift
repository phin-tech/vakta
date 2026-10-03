//
//  ExtensionTrustTests.swift
//  VaktaCoreTests
//
//  When Vakta asks again before running a Linked Extension: a changed
//  manifest always, a changed executable unless developer mode is on.

import XCTest
@testable import Vakta

final class ExtensionTrustTests: XCTestCase {
    private let manifest = Data(#"{"id":"x"}"#.utf8)
    private let binary = Data([0x7f, 0x45, 0x4c, 0x46])

    func test_fingerprint_isLowercaseHexSHA256OfEachFile() {
        let fingerprint = TrustFingerprint.make(manifest: Data("abc".utf8), executable: Data())
        XCTAssertEqual(fingerprint.manifestSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(fingerprint.executableSHA256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertNil(TrustFingerprint.make(manifest: manifest, executable: nil).executableSHA256)
    }

    func test_neverApproved_needsApproval() {
        let current = TrustFingerprint.make(manifest: manifest, executable: binary)
        for developerMode in [false, true] {
            XCTAssertEqual(
                TrustEvaluator.evaluate(approved: nil, current: current, developerMode: developerMode),
                .needsApproval(.neverApproved)
            )
        }
    }

    func test_unchanged_isTrusted() {
        let current = TrustFingerprint.make(manifest: manifest, executable: binary)
        let approved = TrustEvaluator.approval(of: current, developerMode: false)
        XCTAssertEqual(TrustEvaluator.evaluate(approved: approved, current: current, developerMode: false), .trusted)
    }

    func test_changedManifest_needsApproval_evenInDeveloperMode() {
        let original = TrustFingerprint.make(manifest: manifest, executable: binary)
        let edited = TrustFingerprint.make(manifest: Data(#"{"id":"y"}"#.utf8), executable: binary)
        for developerMode in [false, true] {
            let approved = TrustEvaluator.approval(of: original, developerMode: developerMode)
            XCTAssertEqual(
                TrustEvaluator.evaluate(approved: approved, current: edited, developerMode: developerMode),
                .needsApproval(.manifestChanged)
            )
        }
    }

    func test_changedExecutable_needsApproval_unlessDeveloperMode() {
        let original = TrustFingerprint.make(manifest: manifest, executable: binary)
        let rebuilt = TrustFingerprint.make(manifest: manifest, executable: Data([0x00]))

        let approved = TrustEvaluator.approval(of: original, developerMode: false)
        XCTAssertEqual(
            TrustEvaluator.evaluate(approved: approved, current: rebuilt, developerMode: false),
            .needsApproval(.executableChanged)
        )

        let approvedInDeveloperMode = TrustEvaluator.approval(of: original, developerMode: true)
        XCTAssertEqual(
            TrustEvaluator.evaluate(approved: approvedInDeveloperMode, current: rebuilt, developerMode: true),
            .trusted
        )
    }

    func test_developerModeApproval_pinsOnlyTheManifest() {
        let current = TrustFingerprint.make(manifest: manifest, executable: binary)
        XCTAssertNil(TrustEvaluator.approval(of: current, developerMode: true).executableSHA256)
        XCTAssertEqual(TrustEvaluator.approval(of: current, developerMode: false), current)
    }

    /// Turning developer mode off must not inherit an approval that never
    /// covered the executable.
    func test_developerModeApproval_needsApprovalOnceDeveloperModeIsOff() {
        let current = TrustFingerprint.make(manifest: manifest, executable: binary)
        let approved = TrustEvaluator.approval(of: current, developerMode: true)
        XCTAssertEqual(
            TrustEvaluator.evaluate(approved: approved, current: current, developerMode: false),
            .needsApproval(.executableChanged)
        )
    }
}
