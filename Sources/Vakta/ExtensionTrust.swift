//
//  ExtensionTrust.swift
//  Vakta
//
//  Pure Trust decisions for Linked Extensions. Trust pins the manifest's
//  hash and, unless developer mode is on, the executable's hash, so a changed
//  manifest or a swapped binary asks the user again. Hashing bytes is pure;
//  the shell reads the files.

import CryptoKit
import Foundation

struct TrustFingerprint: Codable, Equatable {
    var manifestSHA256: String
    /// `nil` when approved in developer mode (the executable isn't pinned)
    /// or when the executable doesn't exist.
    var executableSHA256: String?

    static func make(manifest: Data, executable: Data?) -> TrustFingerprint {
        TrustFingerprint(manifestSHA256: sha256(manifest), executableSHA256: executable.map(sha256))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum TrustReason: Equatable {
    case neverApproved
    case manifestChanged
    case executableChanged
}

enum TrustStatus: Equatable {
    case trusted
    case needsApproval(TrustReason)
}

enum TrustEvaluator {
    /// Compares what was approved with what is on disk now.
    static func evaluate(approved: TrustFingerprint?, current: TrustFingerprint, developerMode: Bool) -> TrustStatus {
        guard let approved else { return .needsApproval(.neverApproved) }
        guard approved.manifestSHA256 == current.manifestSHA256 else { return .needsApproval(.manifestChanged) }
        if developerMode { return .trusted }
        // An approval made in developer mode never covered the executable.
        guard let pinned = approved.executableSHA256, pinned == current.executableSHA256 else {
            return .needsApproval(.executableChanged)
        }
        return .trusted
    }

    /// What to store when the user approves: developer mode pins only the
    /// manifest.
    static func approval(of current: TrustFingerprint, developerMode: Bool) -> TrustFingerprint {
        developerMode ? TrustFingerprint(manifestSHA256: current.manifestSHA256, executableSHA256: nil) : current
    }
}
