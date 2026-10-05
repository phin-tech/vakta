//
//  ExtensionEnvironment.swift
//  Vakta
//
//  Which login-shell variables an Extension receives: only those its
//  manifest declares (exact names or `PREFIX_*`), never the ones Vakta sets
//  itself. Declaring them is part of the manifest, so it's covered by Trust.

import Foundation

enum ExtensionEnvironment {
    /// Names Vakta sets for every Extension; a manifest can't request them.
    static func isReserved(_ name: String) -> Bool {
        ["PATH", "HOME", "LANG"].contains(name) || name.hasPrefix("VAKTA_")
    }

    /// Problems with a manifest's `environment` list.
    static func problems(_ declared: [String]) -> [String] {
        declared.compactMap { entry in
            let name = entry.hasSuffix("*") ? String(entry.dropLast()) : entry
            guard isValidName(name) else { return "Environment entry “\(entry)” must name a variable or a PREFIX_*." }
            let reserved = entry.hasSuffix("*")
                ? "VAKTA_".hasPrefix(name) || name.hasPrefix("VAKTA_")
                : isReserved(name)
            return reserved ? "Environment entry “\(entry)” is set by Vakta." : nil
        }
    }

    /// The declared variables present in `source`.
    static func passthrough(_ declared: [String], from source: [String: String]) -> [String: String] {
        source.filter { name, _ in
            !isReserved(name) && declared.contains { entry in
                entry.hasSuffix("*") ? name.hasPrefix(String(entry.dropLast())) : name == entry
            }
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }
}
